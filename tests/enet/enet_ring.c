/* enet_ring.c -- bare-metal end-to-end test of ENET over the staging rings
 * (docs/arm-device-protocol.md), run in henry_tb with ENET_LOOPBACK=1.
 *
 * Programs the HPC3 ENET channels the way IRIX's ec driver does, but builds every
 * frame and descriptor with CACHED stores and never writes a cache line back: the
 * device sees the data only through the snoop shims.  The RX buffers are read into
 * the cache before the frames arrive, so a missing post-write invalidate shows up as
 * stale data.
 *
 * TX chain: 3 packets in 4 descriptors -- a 60 B frame; a 400 B frame split over two
 * descriptors at BP offsets 2 and 6; a 1514 B frame ending the chain.  The testbench
 * loops TX back to RX; the RX buffers sit at BP mod 16 = 8, as IRIX's do.
 * Prints 'P' or 'F' + a letter for the first failed check, then magic-halts.
 *
 *   build: see tests/enet/Makefile
 *   run:   ENET_LOOPBACK=1 ./obj_dir/henry_tb --kernel ../tests/enet/enet_ring.elf --maxcyc 20000000
 */
#include <stdint.h>

#define HPC3      0xbfb80000u                    /* kseg1 */
#define HALT      0xbfd00000u
#define K0(pa)    ((volatile uint8_t *)(0x80000000u | (pa)))
#define K0W(pa)   ((volatile uint32_t *)(0x80000000u | (pa)))

#define RX_NBDP   0x14004u
#define RX_CTRL   0x15004u
#define TX_NBDP   0x16004u
#define TX_CTRL   0x17004u
#define ACTIVE    0x200u

#define BC_EOX    0x80000000u
#define BC_EOXP   0x40000000u
#define BC_ROWN   0x00004000u
#define BC_ETXD   0x00008000u

#define TXRING    0x08300000u
#define RXRING    0x08310000u
#define TXBUF     0x08320000u
#define RXBUF     0x08340008u                    /* BP mod 16 = 8, like IRIX */
#define NRX       8
#define RXSZ      1600u

static void putch(uint32_t c) {
  __asm__ volatile("mtc0 %0, $7\n\tnop" : : "r"(c));
}
static void halt(void) {
  *(volatile uint32_t *)HALT = 1;
  for(;;) {
  }
}
static void fail(char why) {
  putch('F');
  putch((uint32_t)why);
  putch('\n');
  halt();
}
static void hpc_wr(uint32_t off, uint32_t v) {
  *(volatile uint32_t *)(HPC3 + off) = v;
}
static uint32_t hpc_rd(uint32_t off) {
  return *(volatile uint32_t *)(HPC3 + off);
}
static uint8_t fbyte(int f, uint32_t k) {
  if(k < 6) {
    return 0xff;                                 /* broadcast */
  }
  if(k < 12) {
    return (uint8_t)(0x08 + k);                  /* source */
  }
  if(k == 12) {
    return 0x88;                                 /* ethertype 0x88b5: local experimental */
  }
  if(k == 13) {
    return 0xb5;
  }
  return (uint8_t)(k * 31u + (uint32_t)f * 77u + 5u);
}

static const uint32_t flen[3] = {60, 400, 1514};

void main(void) {
  uint32_t i, k;

  /* ---- RX ring: 8 descriptors, ROWN, 1600 B buffers at offset 8 ---- */
  for(i = 0; i < NRX; i++) {
    uint32_t d = RXRING + 16 * i;
    K0W(d)[0] = RXBUF + i * 0x800;
    K0W(d)[1] = BC_ROWN | RXSZ;
    K0W(d)[2] = RXRING + 16 * ((i + 1) % NRX);
  }
  /* pull every RX buffer line into the cache: the engine's writes must invalidate them */
  for(i = 0; i < NRX; i++) {
    uint32_t acc = 0;
    for(k = 0; k < RXSZ; k += 16) {
      acc += K0(RXBUF + i * 0x800)[k];
    }
    if(acc == 0x12345678u) {
      putch('?');
    }
  }
  hpc_wr(RX_NBDP, RXRING);
  hpc_wr(RX_CTRL, ACTIVE);

  /* ---- TX: build the frames (cached), then the chain ---- */
  uint32_t b0 = TXBUF, b1a = TXBUF + 0x1002, b1b = TXBUF + 0x2006, b2 = TXBUF + 0x3000;
  for(k = 0; k < flen[0]; k++) {
    K0(b0)[k] = fbyte(0, k);
  }
  for(k = 0; k < 100; k++) {
    K0(b1a)[k] = fbyte(1, k);
  }
  for(k = 100; k < flen[1]; k++) {
    K0(b1b)[k - 100] = fbyte(1, k);
  }
  for(k = 0; k < flen[2]; k++) {
    K0(b2)[k] = fbyte(2, k);
  }
  K0W(TXRING + 0x00)[0] = b0;  K0W(TXRING + 0x00)[1] = flen[0] | BC_EOXP;        K0W(TXRING + 0x00)[2] = TXRING + 0x10;
  K0W(TXRING + 0x10)[0] = b1a; K0W(TXRING + 0x10)[1] = 100;                      K0W(TXRING + 0x10)[2] = TXRING + 0x20;
  K0W(TXRING + 0x20)[0] = b1b; K0W(TXRING + 0x20)[1] = 300 | BC_EOXP;            K0W(TXRING + 0x20)[2] = TXRING + 0x30;
  K0W(TXRING + 0x30)[0] = b2;  K0W(TXRING + 0x30)[1] = flen[2] | BC_EOXP | BC_EOX; K0W(TXRING + 0x30)[2] = TXRING + 0x40;
  hpc_wr(TX_NBDP, TXRING);
  hpc_wr(TX_CTRL, ACTIVE);

  /* ---- TX completes: ACTIVE clears, every descriptor has ETXD, EOX survives ---- */
  for(k = 0; hpc_rd(TX_CTRL) & ACTIVE; k++) {
    if(k > 2000000) {
      fail('a');
    }
  }
  for(i = 0; i < 4; i++) {
    if(!(K0W(TXRING + 16 * i)[1] & BC_ETXD)) {
      fail('t');
    }
  }
  if(!(K0W(TXRING + 0x30)[1] & BC_EOX)) {
    fail('x');
  }

  /* ---- RX: 3 frames land in descriptors 0..2 ---- */
  for(k = 0; K0W(RXRING + 0x20)[1] & BC_ROWN; k++) {
    if(k > 4000000) {
      fail('r');
    }
  }
  for(i = 0; i < 3; i++) {
    uint32_t bc = K0W(RXRING + 16 * i)[1];
    volatile uint8_t *b = K0(RXBUF + i * 0x800);
    if((bc & BC_ROWN) || ((bc & 0x3fff) != RXSZ - (flen[i] + 3))) {
      fail('c');
    }
    if(b[0] != 0 || b[1] != 0) {
      fail('p');
    }
    for(k = 0; k < flen[i]; k++) {
      if(b[2 + k] != fbyte((int)i, k)) {
        fail((char)('0' + i));
      }
    }
    if(b[2 + flen[i]] != 0x30) {
      fail('s');
    }
  }
  if(!(K0W(RXRING + 0x30)[1] & BC_ROWN)) {
    fail('e');                                   /* a 4th frame appeared */
  }
  putch('P');
  putch('\n');
  halt();
}
