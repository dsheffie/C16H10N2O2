/* blkclr53_test.c -- IRIX 5.3's blkclr (blkclr53.S, verbatim: sdl head / sd / sdr tail)
 * against a reference byte clear, start offset 0..15 x length 0..40, with a nonzero
 * pattern around the target and the store buffer seeded with junk by stores to an
 * unrelated line just before (pass 1), or the target evicted from the L1D (2) / L2 (3).  On henry the 5.3 /tmp directory gap clear (start 2 into
 * a doubleword, 14 bytes) left garbage beside the sdl and sdr.
 * Prints up to 8 failures "F off len @byte got/want", then runs/fails and P/F. */
#include <stdint.h>

#define HALT 0xbfd00000u
#define V(a) (*(volatile uint32_t *)(a))

extern void blkclr53(void *dst, int len);

static void putch(uint32_t c) {
  __asm__ volatile("mtc0 %0, $7\n\tnop" : : "r"(c));
}
static void puthex(uint32_t v, int n) {
  for(int i = n - 1; i >= 0; i--) {
    putch("0123456789abcdef"[(v >> (4 * i)) & 0xf]);
  }
}

static uint8_t buf[128] __attribute__((aligned(64)));
static uint8_t ref[128] __attribute__((aligned(64)));
static volatile uint32_t junk[16] __attribute__((aligned(64)));

int main(void) {
  uint32_t fails = 0, runs = 0;
  for(uint32_t pass = 0; pass < 4; pass++) {
    for(uint32_t off = 0; off < 16; off++) {
      for(uint32_t len = 0; len <= 40; len++) {
        for(uint32_t i = 0; i < sizeof(buf); i++) {
          buf[i] = ref[i] = (uint8_t)(0x80 | (i * 13 + off + len));
        }
        for(uint32_t k = 0; k < len; k++) {
          ref[32 + off + k] = 0;
        }
        if(pass == 1) {
          for(uint32_t k = 0; k < 16; k++) {
            junk[k] = 0x10670200u + k;        /* leave data in the store buffer */
          }
        }
        if(pass >= 2) {                       /* 2: evict from the L1D, 3: and the L2 */
          volatile uint32_t sink = 0;
          uint32_t span = (pass == 2) ? 0x10000u : 0x80000u;
          for(uint32_t a = 0x88200000u; a < 0x88200000u + span; a += 16) {
            sink += V(a);
          }
          (void)sink;
        }
        blkclr53(buf + 32 + off, (int)len);
        runs++;
        for(uint32_t i = 0; i < sizeof(buf); i++) {
          if(buf[i] != ref[i]) {
            if(fails < 8) {
              putch('F');
              putch(' ');
              puthex(off, 2);
              putch(' ');
              puthex(len, 2);
              putch(' ');
              putch('@');
              puthex(i, 2);
              putch(' ');
              puthex(buf[i], 2);
              putch('/');
              puthex(ref[i], 2);
              putch('\n');
            }
            fails++;
            break;
          }
        }
      }
    }
  }
  puthex(runs, 8);
  putch(' ');
  puthex(fails, 8);
  putch('\n');
  putch(fails ? 'F' : 'P');
  putch('\n');
  V(HALT) = 1;
  for(;;) {
  }
  return 0;
}
