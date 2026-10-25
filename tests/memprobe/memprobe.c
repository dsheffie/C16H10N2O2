/* memprobe.c -- the IP24 PROM's memory sizing (0xbfc01070 -> 0xbfc01640), bare metal
 * under henry_tb:  make && henry_tb --kernel memprobe.elf --maxcyc 20000000
 * For each bank: make it the ONLY valid bank, at base 0x20000000 (MEMCFG field 0x3f80 =
 * valid | 128 MB | base 0x80), then walking ones through kuseg with ERL=1 (unmapped,
 * uncached) exactly like the PROM.  henry backs banks 0/1 only, so banks 0/1 must read
 * back and banks 2/3 must not; bank 0 must also alias at +128 MB (the size test).
 * Prints one letter per bank (P present / A absent), then 'P' or 'F'+why. */
#include <stdint.h>

#define HALT      0xbfd00000u
#define MEMCFG0   0xbfa000c4u
#define MEMCFG1   0xbfa000ccu
#define PROBE_CFG 0x3f80u
#define V(a)      (*(volatile uint32_t *)(a))

static void putch(uint32_t c) {
  __asm__ volatile("mtc0 %0, $7\n\tnop" : : "r"(c));
}
static void halt(void) {
  V(HALT) = 1;
  for(;;) {
  }
}
static void fail(char why) {
  putch('F');
  putch((uint32_t)why);
  putch('\n');
  halt();
}
static void set_bank(int b) {
  uint32_t c0 = 0, c1 = 0;
  uint32_t f = PROBE_CFG;
  if(b == 0) {
    c0 = f << 16;
  }
  else if(b == 1) {
    c0 = f;
  }
  else if(b == 2) {
    c1 = f << 16;
  }
  else {
    c1 = f;
  }
  V(MEMCFG0) = c0;
  V(MEMCFG1) = c1;
  (void)V(0xbfa00004u);                         /* flush, as the PROM does */
}
/* the PROM's presence test: 1 = all four walking-ones words read back */
static int present(uint32_t base) {
  uint32_t a = 0x11111111u;
  V(base + 0x0) = a;
  V(base + 0x4) = a << 1;
  V(base + 0x8) = a << 2;
  V(base + 0xc) = a << 3;
  return V(base + 0x0) == a && V(base + 0x4) == (a << 1) &&
         V(base + 0x8) == (a << 2) && V(base + 0xc) == (a << 3);
}

/* The real IP24 PROM probes with ERL clear, through TLB entries: four 16 MB pages
 * (PageMask 0x01ffe000), uncached (C=2), VA 0x20000000.. -> PA 0x20000000..  Map them
 * the same way: entry i covers VA 0x20000000 + i*32 MB (an even/odd pair of 16 MB). */
static void tlb_map_probe_window(void) {
  for(uint32_t i = 0; i < 4; i++) {
    uint32_t hi = 0x20000000u + i * 0x02000000u;
    uint32_t pfn0 = (hi >> 12), pfn1 = pfn0 + 0x1000u;
    uint32_t lo0 = (pfn0 << 6) | (2u << 3) | 0x7u;   /* C=2 uncached, D, V, G */
    uint32_t lo1 = (pfn1 << 6) | (2u << 3) | 0x7u;
    __asm__ volatile("mtc0 %0, $0\n\tmtc0 %1, $5\n\tmtc0 %2, $10\n\t"
                     "mtc0 %3, $2\n\tmtc0 %4, $3\n\tnop\n\tnop\n\ttlbwi\n\tnop\n\tnop"
                     : : "r"(i), "r"(0x01ffe000u), "r"(hi), "r"(lo0), "r"(lo1));
  }
}

static int probe_banks(char tag, int got[4]) {
  for(int b = 0; b < 4; b++) {
    set_bank(b);
    got[b] = present(0x20000000u);
    putch(got[b] ? 'P' : 'A');
  }
  putch(tag);
  putch('\n');
  return 0;
}

int main(void) {
  uint32_t sr;
  __asm__ volatile("mfc0 %0, $12" : "=r"(sr));
  sr |= (1u << 2);                              /* ERL: kuseg unmapped + uncached */
  __asm__ volatile("mtc0 %0, $12\n\tnop\n\tnop" : : "r"(sr));
  int got[4];
  for(int b = 0; b < 4; b++) {
    set_bank(b);
    got[b] = present(0x20000000u);
    putch(got[b] ? 'P' : 'A');
  }
  putch('\n');
  if(!got[0] || !got[1]) {
    fail('a');                                  /* a populated bank probed absent */
  }
  if(got[2] || got[3]) {
    fail('b');                                  /* an empty bank probed present */
  }
  set_bank(0);                                  /* size test: +128 MB wraps onto +0 */
  V(0x20000000u) = 0;
  V(0x28000000u) = 0x5a5a5a5au;
  if(V(0x20000000u) != 0x5a5a5a5au) {
    fail('c');
  }
  /* second pass, as the PROM does it: ERL clear, the probe window TLB-mapped uncached */
  sr &= ~(1u << 2);
  __asm__ volatile("mtc0 %0, $12\n\tnop\n\tnop" : : "r"(sr));
  tlb_map_probe_window();
  probe_banks('t', got);
  if(!got[0] || !got[1]) {
    fail('d');                                  /* TLB path: a populated bank probed absent */
  }
  if(got[2] || got[3]) {
    fail('e');                                  /* TLB path: an empty bank probed present */
  }
  V(MEMCFG0) = 0x3f203f40u;                     /* restore: 2 x 128 MB at 0x08000000 */
  V(MEMCFG1) = 0;
  putch('P');
  putch('\n');
  halt();
  return 0;
}
