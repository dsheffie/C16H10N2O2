/* bcopy53_test.c -- IRIX 5.3's bcopy (bcopy53.S, verbatim from the kernel) against a
 * reference byte memmove, over source alignment 0..15, destination shift -24..+24
 * (overlap both ways) and length 0..80.  IRIX 5.3's EFS directory compaction (an
 * overlapping, unaligned bcopy) corrupts /tmp on henry, deterministically.
 * Bare metal: henry_tb --kernel bcopy53.elf, or mips-axi --start-pc 0x88010000.
 * Prints up to 8 failures as "F so sh len @off got/want", then the count and P/F. */
#include <stdint.h>

#define HALT 0xbfd00000u
#define V(a) (*(volatile uint32_t *)(a))

extern void bcopy53(const void *src, void *dst, int len);

static void putch(uint32_t c) {
  __asm__ volatile("mtc0 %0, $7\n\tnop" : : "r"(c));
}
static void puthex(uint32_t v, int n) {
  for(int i = n - 1; i >= 0; i--) {
    putch("0123456789abcdef"[(v >> (4 * i)) & 0xf]);
  }
}

static uint8_t buf[256] __attribute__((aligned(64)));
static uint8_t ref[256] __attribute__((aligned(64)));

int main(void) {
  uint32_t fails = 0, runs = 0;
  for(uint32_t so = 0; so < 16; so++) {
    for(int sh = -24; sh <= 24; sh++) {
      for(uint32_t len = 0; len <= 80; len++) {
        for(uint32_t i = 0; i < sizeof(buf); i++) {
          buf[i] = ref[i] = (uint8_t)(i * 31 + 7 + so + len);
        }
        uint32_t s = 64 + so, d = (uint32_t)((int)s + sh);
        if(d < len) {
          /* keep the reference copy direction-correct for overlap */
        }
        if(d < s) {
          for(uint32_t k = 0; k < len; k++) {
            ref[d + k] = ref[s + k];
          }
        }
        else {
          for(uint32_t k = len; k > 0; k--) {
            ref[d + k - 1] = ref[s + k - 1];
          }
        }
        bcopy53(buf + s, buf + d, (int)len);
        runs++;
        for(uint32_t i = 0; i < sizeof(buf); i++) {
          if(buf[i] != ref[i]) {
            if(fails < 8) {
              putch('F');
              putch(' ');
              puthex(so, 2);
              putch(' ');
              puthex((uint32_t)(sh & 0xff), 2);
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
