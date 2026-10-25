/* buserr.c -- bus errors detected at the MC and returned with the response
 * (docs/bus-errors.md, stage S1).  Bare metal under henry_tb:
 *   make && henry_tb --kernel buserr.elf --maxcyc 20000000
 * Prints 'P', or 'F' + a letter for the first failed check, then magic-halts. */
#include <stdint.h>

#define HALT          0xbfd00000u
#define MC_CPUCTRL1   0xbfa0000cu
#define MC_GIO_EADDR  0xbfa000f4u
#define MC_GIO_ESTAT  0xbfa000fcu
#define INT3_ERRSTAT  0xbfbd98a7u                 /* byte; bit 1 = MC */
#define ABORT_EN      0x10u
#define GSTAT_TIME    0x400u
#define EMPTY_GIO     0xbf000000u                 /* GIO slot 0 base: nothing answers */
#define REX3_USTATUS  0xbf0f133cu                 /* inside the Newport window */
#define V(a)          (*(volatile uint32_t *)(a))
#define EXC_CAUSE     V(0xa0000300u)
#define EXC_EPC       V(0xa0000304u)
#define EXC_BADV      V(0xa0000308u)
#define EXC_COUNT     V(0xa000030cu)

extern uint32_t exc_handler[], exc_handler_end[];

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
static uint32_t badvaddr(void) {
  uint32_t v;
  __asm__ volatile("mfc0 %0, $8" : "=r"(v));
  return v;
}

/* an uncached load from addr; *pc = the load's address */
static uint32_t probe_load(uint32_t addr, uint32_t *pc) {
  uint32_t v = 0xdeadbeef, at;
  __asm__ volatile(".set push\n\t.set noreorder\n\t"
                   "la   %1, 1f\n"
                   "1:\tlw   %0, 0(%2)\n\t"
                   "nop\n\t.set pop"
                   : "+r"(v), "=&r"(at) : "r"(addr) : "memory");
  *pc = at;
  return v;
}
/* the same load in a branch delay slot; *pc = the branch's address */
static void probe_load_ds(uint32_t addr, uint32_t *pc) {
  uint32_t v, at;
  __asm__ volatile(".set push\n\t.set noreorder\n\t"
                   "la   %1, 1f\n"
                   "1:\tbeq  $0, $0, 2f\n\t"
                   "lw   %0, 0(%2)\n"
                   "2:\tnop\n\t.set pop"
                   : "=&r"(v), "=&r"(at) : "r"(addr) : "memory");
  *pc = at;
}

/* IRIX 5.3 wbadaddr (kernel 0x88011104..0x88011444, transcribed): interrupts off,
 * clear the MC error status, flush, then a posted store to the probed address,
 * flush with two uncached MC SYSID reads + an uncached DRAM read, then Cause.IP6
 * (the MC bus-error interrupt) says whether it faulted.  The R4000 is in order,
 * so the mfc0 reads Cause only after those loads returned.  On a fault: clear the
 * status, one flush read, restore SR.  Restoring SR with IP6 still pending takes
 * the bus-error interrupt -- the "IRIX Killed due to Bus Error" at 0x88011240.
 * Returns 1 if the probe faulted. */
static uint32_t probe_store_irix(uint32_t addr, uint32_t *val) {
  uint32_t r, sr, c, t;
  __asm__ volatile(".set push\n\t.set noreorder\n\t"
                   "mfc0 %1, $12\n\t"
                   "mtc0 $0, $12\n\t"
                   "nop\n\tnop\n\tnop\n\tnop\n\t"
                   "lui  %3, 0xbfa0\n\t"
                   "sw   $0, 0xec(%3)\n\t"
                   "sw   $0, 0xfc(%3)\n\t"
                   "lw   %3, 4(%3)\n\t"
                   "lw   %3, 0(%5)\n\t"
                   "sw   %3, 0(%4)\n\t"
                   "lui  %3, 0xbfa0\n\t"
                   "lw   %3, 4(%3)\n\t"
                   "lui  %3, 0xbfa0\n\t"
                   "lw   %3, 4(%3)\n\t"
                   "lui  %3, 0xa000\n\t"
                   "lw   %3, 0(%3)\n\t"
                   "mfc0 %2, $13\n\t"
                   "nop\n\t"
                   "andi %2, %2, 0x4000\n\t"
                   "bnez %2, 1f\n\t"
                   "move %0, $0\n\t"
                   "mtc0 %1, $12\n\t"
                   "b    2f\n\t"
                   "nop\n"
                   "1:\tlui  %3, 0xbfa0\n\t"
                   "sw   $0, 0xec(%3)\n\t"
                   "sw   $0, 0xfc(%3)\n\t"
                   "lw   %3, 4(%3)\n\t"
                   "nop\n\tnop\n\tnop\n\tnop\n\tnop\n\t"
                   "mtc0 %1, $12\n\t"
                   "li   %0, 1\n"
                   "2:\tnop\n\tnop\n\tnop\n\tnop\n\t.set pop"
                   : "=&r"(r), "=&r"(sr), "=&r"(c), "=&r"(t) : "r"(addr), "r"(val) : "memory");
  return r;
}

int main(void) {
  /* install the handler at the general vector, through kseg1 so the I-cache
   * cannot hold stale bytes; then clear SR.BEV, keep interrupts off, and clear
   * ERL/EXL: the CPU leaves reset with ERL=1, and with ERL set ERET clears ERL
   * (not EXL) -- EXL would then stay set and the next fault would not write EPC */
  uint32_t n = (uint32_t)(exc_handler_end - exc_handler);
  for(uint32_t i = 0; i < n; i++) {
    V(0xa0000180u + 4 * i) = exc_handler[i];
  }
  EXC_COUNT = 0;
  uint32_t sr;
  __asm__ volatile("mfc0 %0, $12" : "=r"(sr));
  sr &= ~((1u << 22) | (1u << 2) | (1u << 1) | 1u);
  __asm__ volatile("mtc0 %0, $12\n\tnop\n\tnop" : : "r"(sr));

  uint32_t pc, bv0;
  /* 1: no ABORT_EN -> no bus error (the real MC would hang; we return 0) */
  V(MC_CPUCTRL1) = V(MC_CPUCTRL1) & ~ABORT_EN;
  (void)probe_load(EMPTY_GIO, &pc);
  if(EXC_COUNT != 0) {
    fail('a');
  }
  /* 2: ABORT_EN -> precise DBE at the load; BadVAddr untouched; MC latches */
  V(MC_CPUCTRL1) = V(MC_CPUCTRL1) | ABORT_EN;
  V(MC_GIO_ESTAT) = 0;
  bv0 = badvaddr();
  (void)probe_load(EMPTY_GIO, &pc);
  if(EXC_COUNT != 1) {
    fail('b');
  }
  if(((EXC_CAUSE >> 2) & 0x1f) != 7) {
    fail('c');
  }
  if(EXC_EPC != pc || (EXC_CAUSE >> 31)) {
    fail('d');
  }
  if(badvaddr() != bv0) {
    fail('e');
  }
  if(V(MC_GIO_EADDR) != 0x1f000000u || !(V(MC_GIO_ESTAT) & GSTAT_TIME)) {
    fail('f');
  }
  V(MC_GIO_ESTAT) = 0;
  if(V(MC_GIO_ESTAT) & GSTAT_TIME) {
    fail('g');
  }
  /* 3: the same load in a branch delay slot -> BD, EPC at the branch */
  probe_load_ds(EMPTY_GIO, &pc);
  if(EXC_COUNT != 2 || ((EXC_CAUSE >> 2) & 0x1f) != 7) {
    fail('h');
  }
  if(!(EXC_CAUSE >> 31) || EXC_EPC != pc) {
    fail('i');
  }
  V(MC_GIO_ESTAT) = 0;
  /* 4: a present device (the REX3 window) still answers */
  (void)probe_load(REX3_USTATUS, &pc);
  if(EXC_COUNT != 2) {
    fail('j');
  }
  /* 5: a store to empty GIO: posted -- no exception, the MC latches it and
   *    raises its bus-error interrupt until the status is cleared */
  V(EMPTY_GIO + 0x10) = 0x12345678;
  (void)V(MC_GIO_ESTAT);                         /* order behind the store */
  if(EXC_COUNT != 2) {
    fail('k');
  }
  if(!(V(MC_GIO_ESTAT) & GSTAT_TIME) || V(MC_GIO_EADDR) != 0x1f000010u) {
    fail('l');
  }
  if(!(*(volatile uint8_t *)INT3_ERRSTAT & 2)) {
    fail('m');
  }
  V(MC_GIO_ESTAT) = 0;
  if(*(volatile uint8_t *)INT3_ERRSTAT & 2) {
    fail('n');
  }
  /* 6: IRIX's write probes, in its boot order, with IE + IM6 live around them: each
   *    must see IP6 and take no interrupt (a late IP6 = an interrupt after SR restore) */
  {
    static const uint32_t probes[4] = {0xbfb00010u, 0xbfb00050u, 0xbf980010u, 0xbf980050u};
    uint32_t val = 0xaaaa;
    __asm__ volatile("mfc0 %0, $12" : "=r"(sr));
    sr |= (1u << 14) | 1u;
    __asm__ volatile("mtc0 %0, $12\n\tnop\n\tnop" : : "r"(sr));
    for(int i = 0; i < 4; i++) {
      if(probe_store_irix(probes[i], &val) != 1) {
        fail('o');
      }
      if(EXC_COUNT != 2) {
        fail('p');
      }
    }
    sr &= ~((1u << 14) | 1u);
    __asm__ volatile("mtc0 %0, $12\n\tnop\n\tnop" : : "r"(sr));
  }
  putch('P');
  putch('\n');
  halt();
  return 0;
}
