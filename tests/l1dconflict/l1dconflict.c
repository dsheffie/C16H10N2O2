/* l1dconflict.c -- store to line A, then immediately a store to line B = A + 16 KB
 * (same index in the direct-mapped 16 KB L1D) that misses.  IRIX 5.3's /tmp directory
 * block came out with whole 16-byte lines replaced by the in-core superblock's line
 * except for the bytes actually stored: the l1d's index-only r_must_forward bypass
 * merged B's store into A's data.  For each store kind into B (sb sh sw sd swl sdl
 * sdr) at offsets 0..15: A and B are set up uncached (B absent from the cache, A
 * resident), then "sw A; <st> B" back to back; both lines are checked cached and
 * uncached (after a writeback pass).  Prints up to 8 failures and P/F. */
#include <stdint.h>

#define HALT 0xbfd00000u
#define V(a) (*(volatile uint32_t *)(a))
#define B8(a) (*(volatile uint8_t *)(a))
#define K1(a) ((a) + 0x20000000u)

static void putch(uint32_t c) {
  __asm__ volatile("mtc0 %0, $7\n\tnop" : : "r"(c));
}
static void puthex(uint32_t v, int n) {
  for(int i = n - 1; i >= 0; i--) {
    putch("0123456789abcdef"[(v >> (4 * i)) & 0xf]);
  }
}

#define ST(insn, addr, val) \
  __asm__ volatile(".set push\n\t.set noreorder\n\t.set mips3\n\t" \
                   "sw %2, 0(%3)\n\t" insn " %0, 0(%1)\n\tnop\n\t.set pop" \
                   : : "r"(val), "r"(addr), "r"(0x5a5a5a5au), "r"(a_line) : "memory")

static uint8_t expect_b[16];

/* writeback+invalidate one line (Hit_Writeback_Invalidate_D) */
static void wbinv(uint32_t a) {
  __asm__ volatile(".set push\n\t.set mips3\n\tcache 0x15, 0(%0)\n\t.set pop" : : "r"(a) : "memory");
}

int main(void) {
  uint32_t fails = 0, runs = 0;
  static const char *names[7] = {"sb", "sh", "sw", "sd", "swl", "sdl", "sdr"};
  for(uint32_t kind = 0; kind < 7; kind++) {
    for(uint32_t off = 0; off < 16; off++) {
      if((kind == 1 && (off & 1)) || (kind == 2 && (off & 3)) || (kind == 3 && (off & 7))) {
        continue;
      }
      uint32_t a_line = 0x88300000u + 0x40u * (kind * 16 + off);
      uint32_t b_line = a_line + 0x4000u;           /* same L1D index */
      for(uint32_t i = 0; i < 16; i++) {
        B8(K1(a_line) + i) = (uint8_t)(0xa0 + i);   /* A: a0..af */
        B8(K1(b_line) + i) = (uint8_t)(0x10 + i);   /* B: 10..1f */
        expect_b[i] = (uint8_t)(0x10 + i);
      }
      wbinv(a_line);
      wbinv(b_line);
      volatile uint32_t sink = V(a_line + 4);       /* A resident at the index */
      (void)sink;
      uint64_t val = 0x0102030405060708ull;
      uint32_t b = b_line + off;
      switch(kind)
        {
        case 0: ST("sb", b, (uint32_t)val); break;
        case 1: ST("sh", b, (uint32_t)val); break;
        case 2: ST("sw", b, (uint32_t)val); break;
        case 3: __asm__ volatile(".set push\n\t.set noreorder\n\t.set mips3\n\t" "lui $8,0x0102\n\tori $8,$8,0x0304\n\tdsll32 $8,$8,0\n\tlui $9,0x0506\n\tori $9,$9,0x0708\n\tdsll32 $9,$9,0\n\tdsrl32 $9,$9,0\n\tor $8,$8,$9\n\t" "sw %1,0(%2)\n\tsd $8,0(%0)\n\tnop\n\t.set pop" : : "r"(b), "r"(0x5a5a5a5au), "r"(a_line) : "$8", "$9", "memory"); break;
        case 4: ST("swl", b, (uint32_t)val); break;
        case 5: __asm__ volatile(".set push\n\t.set noreorder\n\t.set mips3\n\t" "lui $8,0x0102\n\tori $8,$8,0x0304\n\tdsll32 $8,$8,0\n\tlui $9,0x0506\n\tori $9,$9,0x0708\n\tdsll32 $9,$9,0\n\tdsrl32 $9,$9,0\n\tor $8,$8,$9\n\t" "sw %1,0(%2)\n\tsdl $8,0(%0)\n\tnop\n\t.set pop" : : "r"(b), "r"(0x5a5a5a5au), "r"(a_line) : "$8", "$9", "memory"); break;
        case 6: __asm__ volatile(".set push\n\t.set noreorder\n\t.set mips3\n\t" "lui $8,0x0102\n\tori $8,$8,0x0304\n\tdsll32 $8,$8,0\n\tlui $9,0x0506\n\tori $9,$9,0x0708\n\tdsll32 $9,$9,0\n\tdsrl32 $9,$9,0\n\tor $8,$8,$9\n\t" "sw %1,0(%2)\n\tsdr $8,0(%0)\n\tnop\n\t.set pop" : : "r"(b), "r"(0x5a5a5a5au), "r"(a_line) : "$8", "$9", "memory"); break;
        }
      /* expected B after the store (big-endian) */
      uint32_t o = off;
      uint8_t vb[8];
      for(int k = 0; k < 8; k++) {
        vb[k] = (uint8_t)(val >> (56 - 8 * k));
      }
      switch(kind)
        {
        case 0: expect_b[o] = vb[7]; break;
        case 1: expect_b[o] = vb[6]; expect_b[o + 1] = vb[7]; break;
        case 2: for(int k = 0; k < 4; k++) { expect_b[o + k] = vb[4 + k]; } break;
        case 3: for(int k = 0; k < 8; k++) { expect_b[o + k] = vb[k]; } break;
        case 4: for(uint32_t k = 0; k < 4 - (o & 3); k++) { expect_b[o + k] = vb[4 + k]; } break;
        case 5: for(uint32_t k = 0; k < 8 - (o & 7); k++) { expect_b[o + k] = vb[k]; } break;
        case 6: for(uint32_t k = 0; k <= (o & 7); k++) { expect_b[o - k] = vb[7 - k]; } break;
        }
      runs++;
      int bad = 0;
      for(uint32_t pass = 0; pass < 2 && !bad; pass++) {
        if(pass) {
          wbinv(a_line);
          wbinv(b_line);
        }
        for(uint32_t i = 0; i < 16 && !bad; i++) {
          uint8_t gb = pass ? B8(K1(b_line) + i) : B8(b_line + i);
          uint8_t wa = (i < 4) ? 0x5a : (uint8_t)(0xa0 + i);
          uint8_t ga = pass ? B8(K1(a_line) + i) : B8(a_line + i);
          if(gb != expect_b[i] || ga != wa) {
            if(fails < 8) {
              putch('F');
              putch(' ');
              for(const char *p = names[kind]; *p; p++) {
                putch(*p);
              }
              putch(' ');
              puthex(off, 1);
              putch(pass ? 'u' : 'c');
              putch(' ');
              putch(gb != expect_b[i] ? 'B' : 'A');
              putch('@');
              puthex(i, 1);
              putch(' ');
              puthex(gb != expect_b[i] ? gb : ga, 2);
              putch('/');
              puthex(gb != expect_b[i] ? expect_b[i] : wa, 2);
              putch('\n');
            }
            bad = 1;
          }
        }
      }
      fails += bad;
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
