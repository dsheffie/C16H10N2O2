/* enet_order.c -- store-ordering test: cached descriptor stores, then an uncached kick.
 *
 * IRIX's ec driver writes a TX descriptor with cached stores and then kicks the HPC3
 * with an uncached store.  A snooping DMA engine reads the descriptor right after the
 * kick, so every older cached store must be visible (in the L1D or below) by the time
 * the kick reaches the device -- as on an R4400, whose write buffer is FIFO across
 * cached and uncached stores.  If the core lets the uncached kick overtake retired
 * cached stores still draining, the engine reads the STALE descriptor from DRAM.
 *
 * Each iteration: put a stale BC (count STALE) in DRAM through kseg1, back up the store
 * queue with stores to cold lines, write the real BC (count n) cached, kick at once.
 * The testbench loops TX back to RX (ENET_LOOPBACK=1); the received length must be n.
 * Prints 'P' or 'F' + iteration info, then magic-halts.
 */
#include <stdint.h>

#define HPC3      0xbfb80000u
#define HALT      0xbfd00000u
#define K0W(pa)   ((volatile uint32_t *)(0x80000000u | (pa)))
#define K1W(pa)   ((volatile uint32_t *)(0xa0000000u | (pa)))
#define K0(pa)    ((volatile uint8_t *)(0x80000000u | (pa)))

#define RX_NBDP   0x14004u
#define RX_CTRL   0x15004u
#define TX_NBDP   0x16004u
#define TX_CTRL   0x17004u
#define ACTIVE    0x200u
#define BC_EOX    0x80000000u
#define BC_EOXP   0x40000000u
#define BC_ROWN   0x00004000u

#define TXD       0x08400000u      /* one fresh descriptor line per iteration */
#define TXBUF     0x08500000u
#define RXRING    0x08310000u
#define RXBUF     0x08340008u
#define COLD      0x08600000u      /* cold lines to back up the store queue */
#define NRX       16
#define RXSZ      1600u
#define ITERS     64
#define STALE     64u

static void putch(uint32_t c) { __asm__ volatile("mtc0 %0, $7\n\tnop" : : "r"(c)); }
static void puthex(uint32_t v) {
  for(int i = 7; i >= 0; i--) {
    uint32_t d = (v >> (4 * i)) & 0xf;
    putch(d < 10 ? '0' + d : 'a' + d - 10);
  }
}
static void halt(void) { *(volatile uint32_t *)HALT = 1; for(;;) { } }
static void hpc_wr(uint32_t off, uint32_t v) { *(volatile uint32_t *)(HPC3 + off) = v; }
static uint32_t hpc_rd(uint32_t off) { return *(volatile uint32_t *)(HPC3 + off); }

void main(void) {
  uint32_t i, k, rx = 0;
  for(i = 0; i < NRX; i++) {
    uint32_t d = RXRING + 16 * i;
    K1W(d)[0] = RXBUF + i * 0x800;
    K1W(d)[1] = BC_ROWN | RXSZ;
    K1W(d)[2] = RXRING + 16 * ((i + 1) % NRX);
  }
  hpc_wr(RX_NBDP, RXRING);
  hpc_wr(RX_CTRL, ACTIVE);
  for(k = 0; k < 2048; k++) {                    /* frame payload: broadcast, ethertype 88b5 */
    K1W(TXBUF)[k / 4] = 0;
  }
  for(k = 0; k < 6; k++) { *(volatile uint8_t *)(0xa0000000u | (TXBUF + k)) = 0xff; }
  *(volatile uint8_t *)(0xa0000000u | (TXBUF + 12)) = 0x88;
  *(volatile uint8_t *)(0xa0000000u | (TXBUF + 13)) = 0xb5;

  for(i = 0; i < ITERS; i++) {
    uint32_t d = TXD + 16 * i;                   /* never touched by the CPU cache before */
    uint32_t n = 100 + 13 * i;
    K1W(d)[0] = TXBUF;                           /* stale copy in DRAM: wrong count */
    K1W(d)[1] = STALE | BC_EOXP | BC_EOX;
    K1W(d)[2] = 0;
    /* back up the store queue: stores to cold lines (L1D misses) */
    for(k = 0; k < 24; k++) {
      K0W(COLD + 0x1000 * i + 64 * k)[0] = k;
    }
    K0W(d)[1] = n | BC_EOXP | BC_EOX;            /* the real BC, CACHED, never written back */
    hpc_wr(TX_NBDP, d);                          /* uncached kick right behind it */
    hpc_wr(TX_CTRL, ACTIVE);
    for(k = 0; hpc_rd(TX_CTRL) & ACTIVE; k++) {
      if(k > 2000000) { putch('F'); putch('a'); halt(); }
    }
    /* the looped-back frame: residual tells its length */
    uint32_t rd = RXRING + 16 * (rx % NRX);
    for(k = 0; K1W(rd)[1] & BC_ROWN; k++) {
      if(k > 4000000) { putch('F'); putch('r'); puthex(i); halt(); }
    }
    uint32_t got = RXSZ - (K1W(rd)[1] & 0x3fff) - 3;
    if(got != n) {
      putch('F'); putch('o'); puthex(i); putch(' '); puthex(n); putch(' '); puthex(got); putch('\n');
      halt();
    }
    K1W(rd)[1] = BC_ROWN | RXSZ;                 /* give the RX buffer back */
    rx++;
    if((rx % NRX) == 0) {
      hpc_wr(RX_NBDP, RXRING);                   /* re-arm at the ring head */
      hpc_wr(RX_CTRL, ACTIVE);
    }
  }
  putch('P');
  putch('\n');
  halt();
}
