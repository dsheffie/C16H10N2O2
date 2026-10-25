/* dirsim.c -- IRIX 5.3's /tmp directory compaction, replayed: a dirty line A (the
 * in-core superblock) shares the L1D index with a directory buffer B = A + 16 KB that
 * a SCSI READ DMAs in.  Then 5.3's own bcopy slides the entries up by 14 bytes and its
 * blkclr clears the gap (sdl head / sd / sdr tail), with stores to A in between, as
 * the kernel updates the superblock.  On henry the cleared lines came out holding A's
 * bytes except where the stores landed.  Bare metal: henry_tb --kernel dirsim.elf
 * --disk ../dmaalign/dmaalign.img, or mips-axi --start-pc 0x88010000. */
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

extern void bcopy53(const void *src, void *dst, int len);
extern void blkclr53(void *dst, int len);

static uint8_t model[512];

int main(void) {
  uint32_t fails = 0, runs = 0;
  for(uint32_t rep = 0; rep < 64; rep++) {
    uint32_t a = 0x88300000u + (rep & 7) * 0x200u;      /* "superblock" region */
    uint32_t b = a + 0x4000u;                            /* same L1D index */
    uint32_t lba = 1 + (rep & 15);
    for(uint32_t i = 0; i < 512; i += 4) {
      V(a + i) = 0xa5000000u | (rep << 16) | i;          /* A dirty in the L1D */
    }
    uint32_t seg[2] = {b & 0x1fffffffu, 512};
    if(disk_readv(lba, 1, seg, 1) != 0) {
      putch('E');
      fails++;
      continue;
    }
    for(uint32_t i = 0; i < 512; i++) {
      model[i] = expect(lba, i);
    }
    /* first_used .. removed entry: slide [0x1ae, 0x1ae+0x2a) up by 14, clear the gap */
    uint32_t from = 0x1ae - 2 * (rep & 3), len = 0x2a + (rep & 7), sh = 14;
    V(a + 0x6c) = 0x02000010u;                           /* superblock update */
    bcopy53((void *)(b + from), (void *)(b + from + sh), (int)len);
    for(int k = (int)len - 1; k >= 0; k--) {
      model[from + sh + k] = model[from + k];
    }
    V(a + 0x80) = 0x00001067u;                           /* superblock update */
    blkclr53((void *)(b + from), (int)sh);
    for(uint32_t k = 0; k < sh; k++) {
      model[from + k] = 0;
    }
    runs++;
    for(uint32_t view = 0; view < 2; view++) {
      uint32_t off = view ? 0x20000000u : 0, bad = 0;
      if(view) {
        for(uint32_t i = 0; i < 512; i += 16) {
          __asm__ volatile(".set push\n\t.set mips3\n\tcache 0x15, 0(%0)\n\tcache 0x15, 0(%1)\n\t.set pop" : : "r"(a + i), "r"(b + i) : "memory");
        }
      }
      for(uint32_t i = 0; i < 512 && !bad; i++) {
        uint8_t got = B(b + off + i);
        if(got != model[i]) {
          putch(view ? 'u' : 'c');
          puthex(rep, 2);
          putch('@');
          puthex(i, 3);
          putch('=');
          puthex(got, 2);
          putch('/');
          puthex(model[i], 2);
          putch('\n');
          bad = 1;
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
  halt();
  return 0;
}
