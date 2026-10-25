/* uncsdl.c -- uncached sdl/sdr/swl/swr through kseg1 while an unrelated line is cached
 * at the same L1D index.  IRIX 5.3's bcopy/blkclr run sdl/sdr on kseg1 directory
 * buffers; the l1d gave sdl/sdr a full-doubleword byte mask, so an uncached one wrote
 * the cached line's bytes (the in-core superblock) into the bytes it should not touch.
 * For each op and byte offset 0..15: the target line (uncached) holds 10..1f, a line
 * 16 KB away is cached holding a0..af, then one uncached store of 0102030405060708;
 * the target is checked uncached.  Prints up to 8 failures and P/F. */
#include <stdint.h>

#define HALT 0xbfd00000u
#define V(a) (*(volatile uint32_t *)(a))
#define B8(a) (*(volatile uint8_t *)(a))

static void putch(uint32_t c) {
  __asm__ volatile("mtc0 %0, $7\n\tnop" : : "r"(c));
}
static void puthex(uint32_t v, int n) {
  for(int i = n - 1; i >= 0; i--) {
    putch("0123456789abcdef"[(v >> (4 * i)) & 0xf]);
  }
}

#define LOAD64 "lui $8,0x0102\n\tori $8,$8,0x0304\n\tdsll32 $8,$8,0\n\tlui $9,0x0506\n\tori $9,$9,0x0708\n\tdsll32 $9,$9,0\n\tdsrl32 $9,$9,0\n\tor $8,$8,$9\n\t"
#define ST64(op, addr) __asm__ volatile(".set push\n\t.set noreorder\n\t.set mips3\n\t" LOAD64 op " $8,0(%0)\n\tnop\n\t.set pop" : : "r"(addr) : "$8", "$9", "memory")

int main(void) {
  uint32_t fails = 0, runs = 0;
  static const char *names[4] = {"sdl", "sdr", "swl", "swr"};
  uint8_t vb[8] = {1, 2, 3, 4, 5, 6, 7, 8};
  for(uint32_t kind = 0; kind < 4; kind++) {
    for(uint32_t off = 0; off < 16; off++) {
      uint32_t tgt = 0xa8300000u + 0x40u * (kind * 16 + off);   /* kseg1 target line */
      uint32_t other = (tgt - 0x20000000u) + 0x4000u;           /* kseg0, same index */
      uint8_t exp[16];
      for(uint32_t i = 0; i < 16; i++) {
        B8(tgt + i) = (uint8_t)(0x10 + i);
        exp[i] = (uint8_t)(0x10 + i);
        B8(other + i) = (uint8_t)(0xa0 + i);                     /* cached at the index */
      }
      volatile uint32_t sink = V(other);
      (void)sink;
      uint32_t a = tgt + off;
      uint32_t k8 = off & 7, k4 = off & 3;
      switch(kind)
        {
        case 0: ST64("sdl", a); for(uint32_t k = 0; k < 8 - k8; k++) { exp[off + k] = vb[k]; } break;
        case 1: ST64("sdr", a); for(uint32_t k = 0; k <= k8; k++) { exp[off - k] = vb[7 - k]; } break;
        case 2: ST64("swl", a); for(uint32_t k = 0; k < 4 - k4; k++) { exp[off + k] = vb[4 + k]; } break;
        case 3: ST64("swr", a); for(uint32_t k = 0; k <= k4; k++) { exp[off - k] = vb[7 - k]; } break;
        }
      runs++;
      for(uint32_t i = 0; i < 16; i++) {
        uint8_t got = B8(tgt + i);
        if(got != exp[i]) {
          if(fails < 8) {
            putch('F');
            putch(' ');
            for(const char *p = names[kind]; *p; p++) {
              putch(*p);
            }
            putch(' ');
            puthex(off, 1);
            putch(' ');
            putch('@');
            puthex(i, 1);
            putch(' ');
            puthex(got, 2);
            putch('/');
            puthex(exp[i], 2);
            putch('\n');
          }
          fails++;
          break;
        }
      }
    }
  }
  puthex(runs, 4);
  putch(' ');
  puthex(fails, 4);
  putch('\n');
  putch(fails ? 'F' : 'P');
  putch('\n');
  V(HALT) = 1;
  for(;;) {
  }
  return 0;
}
