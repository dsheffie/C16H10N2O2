/*
 * vdma_test.c -- bare-metal test of the MC's memory -> GIO "virtual DMA" on henry.
 *
 * The pixel source is written with ordinary cached stores and NOT written back, so
 * the transfer must read it coherently (dma_engine's VDMA channel through the snoop
 * shim).  VA region 0x40000000 maps through the DMA TLB and a page of PTEs to the
 * source's 4 KB frames in reverse order, so page crossings land on unrelated frames.
 * Each transfer stores its doublewords to REX3 HOSTRW0 (no GO: nothing draws).
 *
 * The program computes every doubleword itself (sgi_mc.cc dma_perform, translating
 * through its own PTEs) and prints them as "exp <n> <hi> <lo>" (lanes 7..4, 3..0);
 * henry_tb GIOLOG=1 logs what reached the Newport model ("[giow]"); check.py diffs
 * the two, and that the CPU REX3 store made right after each start lands after all of
 * that transfer's doublewords.  The program itself checks DMA_RUN, DMA_CAUSE + INT3 local0 bit 4 (MC
 * DMA) and its clear, and DMA_MEMADR after each transfer.
 */
#include <stdint.h>
#include "printf.h"

#define MC(o)       (*(volatile uint32_t *)(0xbfa00000u + (o)))
#define LOCAL0_STAT (*(volatile uint8_t *)0xbfbd9883u)
#define HOSTRW0     0x1f0f0230u
#define NFRAME      8
#define VBASE       0x40000000u

/* DMA buffers must be in RAM proper (PA 0x08000000+): the IP22 low-memory alias at
 * PA 0, where this program's own image lives, is a CPU-side view only */
static uint8_t  *const pix  = (uint8_t *)0x88800000u;     /* NFRAME pages */
/* the PTE page above PA 0x10000000, like IRIX's: DMA_TLB_LO bits [25:22] matter */
static uint32_t *const ptes = (uint32_t *)0x90810000u;    /* one page of PTEs */
static int g_fail = 0;
static int g_n = 0;

static uint32_t pa_of(const void *p) {
  return (uint32_t)p & 0x1fffffffu;
}

/* the reference translation: our PTEs for VBASE's 4 MB, else physical */
static uint8_t ref_byte(uint32_t va) {
  uint32_t pa = va;
  if((va & 0xffc00000u) == VBASE) {
    const uint32_t pte = ptes[(va >> 12) & 0x3ffu];
    pa = ((pte & 0x03ffffc0u) << 6) + (va & 0xfffu);
  }
  return *(volatile uint8_t *)(0x80000000u | pa);
}

static uint32_t ref_perform(uint32_t memadr, uint32_t size, uint32_t stride_r, uint32_t count) {
  uint32_t m = memadr;
  uint32_t lines = size >> 16;
  uint32_t zoom = (count >> 16) & 0x3ff;
  uint32_t bytes = count & 0xffff;
  const uint32_t width = size & 0xffff, line_zoom = (stride_r >> 16) & 0x3ff;
  const int16_t stride = (int16_t)stride_r;
  while(lines > 0) {
    lines--;
    while(zoom > 0) {
      zoom--;
      while(bytes > 0) {
        const uint32_t len = bytes < 8 ? bytes : 8;
        uint32_t hi = 0, lo = 0;
        for(uint32_t i = 0; i < len; i++) {
          const uint32_t b = ref_byte(m);
          if(i < 4) {
            lo |= b << (8 * i);
          }
          else {
            hi |= b << (8 * (i - 4));
          }
          m++;
        }
        printf_("exp %d %08x %08x\n", g_n, hi, lo);
        g_n++;
        bytes -= len;
      }
      bytes = width;
      if(zoom > 0) {
        m -= width;
      }
    }
    zoom = line_zoom;
    m += stride;
  }
  return m;
}

static void check(int t, const char *what, uint32_t got, uint32_t exp) {
  if(got != exp) {
    printf_("FAIL t%d %s: %08x, expected %08x\n", t, what, got, exp);
    g_fail++;
  }
}

static void run(int t, uint32_t memadr, uint32_t size, uint32_t stride_r, uint32_t count,
                uint32_t mode, int moves) {
  MC(0x2004) = memadr;
  MC(0x2014) = size;          /* also DMA_COUNT[15:0] */
  MC(0x201c) = stride_r;      /* also DMA_COUNT[25:16] */
  MC(0x203c) = count;
  MC(0x2034) = mode;
  MC(0x016c) = 0x10;          /* DMA_CTL: interrupt on completion */
  check(t, "count", MC(0x203c), count);
  MC(0x202c) = HOSTRW0;       /* GIO address + start */
  /* a CPU REX3 access while the transfer may still run: it must reach the Newport
   * after every doubleword of the transfer (check.py), as on a GIO bus the DMA owns */
  *(volatile uint32_t *)0xbf0f0000u = 0;
  /* REX3 reports busy while the transfer's host data is still arriving */
  const uint32_t st_during = *(volatile uint32_t *)0xbf0f1338u;
  if(t <= 3) {
    check(t, "REX3 GFXBUSY during", st_during & 0x8, 0x8);
  }
  uint32_t run_st = 0;
  for(int spin = 0; spin < 1000000; spin++) {
    run_st = MC(0x204c);
    if(run_st & 0x8) {
      break;
    }
  }
  check(t, "DMA_RUN", run_st & 0x48, 0x08);
  check(t, "REX3 GFXBUSY after", *(volatile uint32_t *)0xbf0f1338u & 0x8, 0x0);
  check(t, "DMA_CAUSE", MC(0x0164) & 0x8, 0x8);
  check(t, "LOCAL0 MC DMA", LOCAL0_STAT & 0x10, 0x10);
  MC(0x0164) = 0;
  check(t, "LOCAL0 after clear", LOCAL0_STAT & 0x10, 0x00);
  if(moves) {
    const uint32_t end = ref_perform(memadr, size, stride_r, count);
    check(t, "DMA_MEMADR after", MC(0x2004), end);
  }
  else {
    check(t, "DMA_MEMADR kept", MC(0x2004), memadr);
  }
  printf_("transfer %d done (%d doublewords so far)\n", t, g_n);
}

int main(void) {
  /* the source: cached stores, left dirty in the caches */
  for(uint32_t i = 0; i < NFRAME * 4096; i++) {
    pix[i] = (uint8_t)(i * 37u + (i >> 9) * 11u + 5u);
  }
  /* VA page k of VBASE -> frame NFRAME-1-k; the rest of the PTE page maps frame 0 */
  for(uint32_t k = 0; k < 1024; k++) {
    const uint32_t frame = pa_of(&pix[((k < NFRAME) ? (NFRAME - 1 - k) : 0) * 4096]);
    ptes[k] = ((frame >> 6) & 0x03ffffc0u) | 0x3u;
  }
  /* DMA TLB: entry 1 maps VBASE; the others name regions nothing uses */
  for(int e = 0; e < 4; e++) {
    MC(0x0184 + 16 * e) = (e == 1) ? VBASE : (0x7f000000u + (uint32_t)e * 0x00400000u);
    MC(0x018c + 16 * e) = (e == 1) ? ((pa_of(ptes) >> 6) & 0x03ffffc0u) : 0u;
  }
  check(0, "TLB hi readback", MC(0x0194), VBASE);
  /* 1: crosses VA pages 0 -> 1 (frames 7 -> 6), positive stride */
  run(1, VBASE + 0x0ff0 - 5, (3u << 16) | 37u, (1u << 16) | 11u, (1u << 16) | 37u, 0x50, 1);
  /* 2: zoom (first line 3 copies of 9 bytes, then 2 copies of 13), negative stride */
  run(2, VBASE + 3 * 4096 + 100, (4u << 16) | 13u, (2u << 16) | (uint16_t)(-40), (3u << 16) | 9u, 0x50, 1);
  /* 3: no TLB entry matches: the address is physical */
  run(3, pa_of(&pix[5 * 4096 + 7]), (2u << 16) | 20u, (1u << 16) | 0u, (1u << 16) | 20u, 0x50, 1);
  /* 4: no lines: completes, moves nothing */
  run(4, VBASE + 64, (0u << 16) | 16u, (1u << 16) | 0u, (1u << 16) | 16u, 0x50, 1);
  /* 5: downward -- not implemented: completes at once, moves nothing */
  run(5, VBASE + 64, (2u << 16) | 16u, (1u << 16) | 0u, (1u << 16) | 16u, 0x40, 0);
  printf_("vdma_test: %d doublewords, %d failures: %s\n", g_n, g_fail, g_fail ? "FAIL" : "PASS");
  printf_("checksum %d\n", g_fail);
  return 0;
}
