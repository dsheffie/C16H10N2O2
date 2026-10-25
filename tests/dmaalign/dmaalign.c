/* dmaalign.c -- SCSI DMA into a buffer that does not start on a cache line, with the
 * CPU holding dirty lines around it.  IRIX 5.3 reads whole 512-byte blocks into
 * buffers 8 bytes into a 16-byte line (6.5 never does) and its root directory comes
 * back "corrupted" on henry, deterministically.  Bare metal under henry_tb:
 *     make && henry_tb --kernel dmaalign.elf --disk dmaalign.img --maxcyc 40000000
 * For each buffer offset (bytes past a 64-byte boundary):
 *   1. cached stores fill [guard | buffer | guard] with 0xA5 -> dirty L1D lines;
 *   2. one 512-byte READ(10) DMAs sector N into the buffer;
 *   3. check the block and both 64-byte guards, through kseg0 (what the CPU sees)
 *      and kseg1 (what reached DRAM).
 * Prints "<off>:" then D/d (block, cached), U/u (block, uncached), G/g (guards,
 * cached), H/h (guards, uncached); lower case = mismatch, followed by the first bad
 * byte offset and value.  Ends with 'P' (all good) or 'F'. */
#include <stdint.h>

#define HALT      0xbfd00000u
#define V(a)      (*(volatile uint32_t *)(a))
#define B(a)      (*(volatile uint8_t *)(a))

#define SCSI_SASR      0xbfbc4003u
#define SCSI_SCMD      0xbfbc4007u
#define HPC_SCSI_NBDP  0xbfb90004u
#define HPC_SCSI_CTRL  0xbfb91004u
#define DESC_PHYS      0x08280000u   /* descriptor in DRAM, built through kseg1 */
#define DESC_K1        0xa8280000u
#define BUF_K0         0x88400000u   /* one 4 KB page per case */
#define GUARD          64u
#define BLK            512u

#define WD_OWN_ID   0x00u
#define WD_TGT_LUN  0x0fu
#define WD_CDB      0x03u
#define WD_XFER_CNT 0x12u
#define WD_DEST_ID  0x15u
#define WD_STATUS   0x17u
#define WD_COMMAND  0x18u
#define CMD_SEL_ATN_XFER 0x08u
#define AUX_INT          0x80u
#define CTRL_ACTIVE      0x10u
#define CTRL_TODEV       0x04u   /* HPC3 SCSI ctrl DIR: 1 = memory -> device */
#define BC_EOX           0x80000000u

static void putch(uint32_t c) {
  __asm__ volatile("mtc0 %0, $7\n\tnop" : : "r"(c));
}
static void puthex(uint32_t v, int n) {
  for(int i = n - 1; i >= 0; i--) {
    putch("0123456789abcdef"[(v >> (4 * i)) & 0xf]);
  }
}
static void halt(void) {
  V(HALT) = 1;
  for(;;) {
  }
}

static void wd_set(uint8_t r, uint8_t v) { B(SCSI_SASR) = r; B(SCSI_SCMD) = v; }
static uint8_t wd_get(uint8_t r) { B(SCSI_SASR) = r; return B(SCSI_SCMD); }

/* one-block READ(10) of lba into dst_phys (the henry_disk.c sequence) */
/* READ(10) of nblk blocks scattered over nseg {phys, len} segments, one HPC3
 * descriptor each (16 bytes apart, chained through DP) */
static int disk_xfer(uint32_t op, uint32_t lba, uint32_t nblk, const uint32_t *seg, uint32_t nseg) {
  for(uint32_t i = 0; i < nseg; i++) {
    V(DESC_K1 + 16 * i + 0) = seg[2 * i];
    V(DESC_K1 + 16 * i + 4) = seg[2 * i + 1] | ((i == nseg - 1) ? BC_EOX : 0);
    V(DESC_K1 + 16 * i + 8) = (i == nseg - 1) ? 0 : DESC_PHYS + 16 * (i + 1);
  }
  wd_set(WD_OWN_ID, 0x07);
  wd_set(WD_DEST_ID, 1);
  wd_set(WD_TGT_LUN, 0);
  B(SCSI_SASR) = WD_CDB;
  B(SCSI_SCMD) = op;
  B(SCSI_SCMD) = 0;
  B(SCSI_SCMD) = lba >> 24;
  B(SCSI_SCMD) = lba >> 16;
  B(SCSI_SCMD) = lba >> 8;
  B(SCSI_SCMD) = lba;
  B(SCSI_SCMD) = 0;
  B(SCSI_SCMD) = nblk >> 8;
  B(SCSI_SCMD) = nblk;
  B(SCSI_SCMD) = 0;
  B(SCSI_SASR) = WD_XFER_CNT;
  B(SCSI_SCMD) = (nblk * BLK) >> 16;
  B(SCSI_SCMD) = (nblk * BLK) >> 8;
  B(SCSI_SCMD) = (nblk * BLK) & 0xff;
  V(HPC_SCSI_NBDP) = DESC_PHYS;
  V(HPC_SCSI_CTRL) = CTRL_ACTIVE | ((op == 0x2a) ? CTRL_TODEV : 0);
  wd_set(WD_COMMAND, CMD_SEL_ATN_XFER);
  for(uint32_t spins = 0; (B(SCSI_SASR) & AUX_INT) == 0; spins++) {
    if(spins > 100000000u) {
      return -1;
    }
  }
  uint8_t st = wd_get(WD_STATUS);
  uint8_t tgt = wd_get(WD_TGT_LUN);
  return (st == 0x16 && tgt == 0) ? 0 : ((st << 8) | tgt);
}

static int disk_readv(uint32_t lba, uint32_t nblk, const uint32_t *seg, uint32_t nseg) {
  return disk_xfer(0x28, lba, nblk, seg, nseg);
}

/* expected byte k of sector n (word W = 0x5E<n:16><W:8>, big-endian) */
static uint8_t expect(uint32_t n, uint32_t k) {
  uint32_t w = (0x5Eu << 24) | (n << 8) | (k >> 2);
  return (uint8_t)(w >> (8 * (3 - (k & 3))));
}

/* returns 1 if ok; else prints first bad offset/value */
static int check(uint32_t base, uint32_t dst, uint32_t n, int guards, char ok, char bad) {
  uint32_t lo = guards ? base : dst, hi = guards ? dst + BLK + GUARD : dst + BLK;
  for(uint32_t a = lo; a < hi; a++) {
    int in_blk = (a >= dst && a < dst + BLK);
    if(guards == in_blk) {
      continue;
    }
    uint8_t want = in_blk ? expect(n, a - dst) : 0xA5;
    uint8_t got = B(a);
    if(got != want) {
      putch(bad);
      putch('@');
      puthex(a - dst, 4);
      putch('=');
      puthex(got, 2);
      putch(' ');
      return 0;
    }
  }
  putch(ok);
  return 1;
}

int main(void) {
  static const uint32_t offs[] = {0, 4, 8, 16, 72};
  int allok = 1;
  for(uint32_t c = 0; c < sizeof(offs) / sizeof(offs[0]); c++) {
    uint32_t base = BUF_K0 + c * 0x1000u;          /* guard starts on a 64 B boundary */
    uint32_t dst = base + GUARD + offs[c];
    uint32_t n = c + 1;
    for(uint32_t a = base; a < dst + BLK + GUARD; a++) {
      B(a) = 0xA5;                                  /* cached: dirty lines */
    }
    puthex(offs[c], 2);
    putch(':');
    uint32_t seg1[2] = {dst & 0x1fffffffu, BLK};
    int rc = disk_readv(n, 1, seg1, 1);
    if(rc != 0) {
      putch('E');
      puthex((uint32_t)rc, 8);
      putch('\n');
      allok = 0;
      continue;
    }
    uint32_t k1 = 0x20000000u;                      /* kseg0 -> kseg1 */
    allok &= check(base, dst, n, 0, 'D', 'd');
    allok &= check(base + k1, dst + k1, n, 0, 'U', 'u');
    allok &= check(base, dst, n, 1, 'G', 'g');
    allok &= check(base + k1, dst + k1, n, 1, 'H', 'h');
    putch('\n');
  }
  /* chained: IRIX 5.3's 10-block read at LBA 2177 -- 2308 bytes from 12 bytes into a
   * line up to a page boundary, then 2812 contiguous bytes; and three 512-byte
   * segments at +8 in separate pages.  Checked as one stream of sectors. */
  {
    static const uint32_t cases[2][4] = { {10, 2, 2308, 2812}, {3, 3, 512, 512} };
    for(uint32_t c = 0; c < 2; c++) {
      uint32_t nblk = cases[c][0], nseg = cases[c][1];
      uint32_t lba = 16 + 16 * c, seg[8], k0[4];
      uint32_t page = BUF_K0 + 0x10000u + c * 0x10000u;
      for(uint32_t a = page; a < page + 0x8000u; a++) {
        B(a) = 0xA5;                                /* dirty everything around */
      }
      if(c == 0) {
        k0[0] = page + 0x1000u - 2308;              /* 0x...6fc: 12 into a line */
        k0[1] = page + 0x1000u;
      }
      else {
        for(uint32_t i = 0; i < nseg; i++) {
          k0[i] = page + 0x1000u * (i + 1) + 0x518u;  /* 8 into a line */
        }
      }
      for(uint32_t i = 0; i < nseg; i++) {
        seg[2 * i] = k0[i] & 0x1fffffffu;
        seg[2 * i + 1] = cases[c][2 + (i < 2 ? i : 1)];
      }
      putch('c');
      putch('0' + c);
      putch(':');
      int rc = disk_readv(lba, nblk, seg, nseg);
      if(rc != 0) {
        putch('E');
        puthex((uint32_t)rc, 8);
        putch('\n');
        allok = 0;
        continue;
      }
      for(uint32_t view = 0; view < 2; view++) {
        uint32_t off = view ? 0x20000000u : 0, pos = 0, bad = 0;
        for(uint32_t i = 0; i < nseg && !bad; i++) {
          for(uint32_t j = 0; j < seg[2 * i + 1]; j++, pos++) {
            uint8_t got = B(k0[i] + off + j);
            uint8_t want = expect(lba + pos / BLK, pos % BLK);
            if(got != want) {
              putch(view ? 'u' : 'd');
              putch('@');
              puthex(pos, 4);
              putch('=');
              puthex(got, 2);
              putch(' ');
              bad = 1;
              break;
            }
          }
          /* the byte after each segment must still be guard */
          if(!bad && B(k0[i] + off + seg[2 * i + 1]) != 0xA5 && !(c == 0 && i == 0)) {
            putch(view ? 'h' : 'g');
            putch('@');
            puthex(i, 2);
            putch(' ');
            bad = 1;
          }
        }
        if(!bad) {
          putch(view ? 'U' : 'D');
        }
        allok &= !bad;
      }
      putch('\n');
    }
  }
  /* buffer reuse, the buffer-cache pattern: DMA block A, the CPU reads it (clean
   * lines), DMA block B into the SAME buffer, the CPU must see B.
   *   r0: A's lines clean in the L1D
   *   r1: A's lines clean, evicted to the L2 only (64 KB of other loads)
   *   r2: buffer dirtied by stores, then evicted (dirty in the L2) before B lands
   * each at offsets 0 and 8.  Prints r<mode><off>: D/d U/u. */
  for(uint32_t mode = 0; mode < 3; mode++) {
    for(uint32_t o = 0; o < 2; o++) {
      uint32_t dst = BUF_K0 + 0x40000u + mode * 0x2000u + o * 0x1000u + (o ? 8u : 0u);
      uint32_t seg[2] = {dst & 0x1fffffffu, BLK};
      uint32_t a_lba = 40 + 4 * mode + 2 * o, b_lba = a_lba + 1;
      volatile uint32_t sink = 0;
      putch('r');
      putch('0' + mode);
      putch(o ? '8' : '0');
      putch(':');
      if(disk_readv(a_lba, 1, seg, 1) != 0) {
        putch('E');
        putch('\n');
        allok = 0;
        continue;
      }
      if(mode < 2) {
        for(uint32_t a = dst; a < dst + BLK; a++) {
          sink += B(a);                             /* clean copies of A in the L1D */
        }
      }
      else {
        for(uint32_t a = dst; a < dst + BLK; a++) {
          B(a) = 0x5A;                              /* dirty */
        }
      }
      if(mode >= 1) {
        for(uint32_t a = BUF_K0 + 0x80000u; a < BUF_K0 + 0x90000u; a += 16) {
          sink += B(a);                             /* evict the L1D (16 KB) */
        }
      }
      if(disk_readv(b_lba, 1, seg, 1) != 0) {
        putch('E');
        putch('\n');
        allok = 0;
        continue;
      }
      allok &= check(dst, dst, b_lba, 0, 'D', 'd');
      allok &= check(dst + 0x20000000u, dst + 0x20000000u, b_lba, 0, 'U', 'u');
      putch('\n');
      (void)sink;
    }
  }
  /* writes: the CPU builds a block in cached memory, WRITE(10) gathers it, then a
   * READ(10) into a separate buffer brings it back (checked uncached).
   *   w0: block dirty in the L1D
   *   w1: block dirty, evicted to the L2
   *   w2: block DMA'd in (clean), then every third byte rewritten (partly dirty lines)
   * each at offsets 0 and 8.  Prints w<mode><off>: W/w. */
  for(uint32_t mode = 0; mode < 3; mode++) {
    for(uint32_t o = 0; o < 2; o++) {
      uint32_t src = BUF_K0 + 0x60000u + mode * 0x2000u + o * 0x1000u + (o ? 8u : 0u);
      uint32_t back = BUF_K0 + 0x70000u + mode * 0x2000u + o * 0x1000u;
      uint32_t lba = 56 + 2 * mode + o;
      uint32_t sseg[2] = {src & 0x1fffffffu, BLK}, bseg[2] = {back & 0x1fffffffu, BLK};
      volatile uint32_t sink = 0;
      putch('w');
      putch('0' + mode);
      putch(o ? '8' : '0');
      putch(':');
      if(mode == 2) {
        if(disk_readv(1, 1, sseg, 1) != 0) {
          putch('E');
        }
        for(uint32_t k = 0; k < BLK; k++) {
          sink += B(src + k);
        }
        for(uint32_t k = 0; k < BLK; k += 3) {
          B(src + k) = (uint8_t)(k * 7 + lba);
        }
      }
      else {
        for(uint32_t k = 0; k < BLK; k++) {
          B(src + k) = (uint8_t)(k * 7 + lba);
        }
      }
      if(mode == 1) {
        for(uint32_t a = BUF_K0 + 0x80000u; a < BUF_K0 + 0x90000u; a += 16) {
          sink += B(a);
        }
      }
      int rc = disk_xfer(0x2a, lba, 1, sseg, 1);
      rc |= disk_readv(lba, 1, bseg, 1);
      if(rc != 0) {
        putch('E');
        puthex((uint32_t)rc, 8);
        putch('\n');
        allok = 0;
        continue;
      }
      uint32_t bad = 0;
      for(uint32_t k = 0; k < BLK && !bad; k++) {
        uint8_t want = (mode == 2 && (k % 3)) ? expect(1, k) : (uint8_t)(k * 7 + lba);
        uint8_t got = B(back + 0x20000000u + k);
        if(got != want) {
          putch('w');
          putch('@');
          puthex(k, 4);
          putch('=');
          puthex(got, 2);
          putch('/');
          puthex(want, 2);
          bad = 1;
        }
      }
      if(!bad) {
        putch('W');
      }
      allok &= !bad;
      putch('\n');
      (void)sink;
    }
  }
  putch(allok ? 'P' : 'F');
  putch('\n');
  halt();
  return 0;
}
