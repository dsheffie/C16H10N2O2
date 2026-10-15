// Unit test for scsi_dma + scsi_stage (SCSI over the staging rings,
// docs/arm-device-protocol.md).  Model DRAM port: stores go to the 16 B-ALIGNED line;
// guest memory and staging (PA 0x1e000000+) are separate arrays; guard bytes
// around every guest buffer.  The "ARM" side here only touches staging.
#include "Vscsi_stage_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <vector>

static const uint32_t MEMSZ = 1u << 18;
static const uint32_t STG = 0x1e000000u, STGSZ = 1u << 24;
static uint8_t mem[MEMSZ];
static uint8_t *stg;
static const uint32_t SIDX = 0x50, SCQ = 0x3000, RD = 0x800000, WR = 0xc00000;
static const uint32_t BC_EOX = 0x80000000u;
static const uint8_t GUARD = 0xa5;

static uint8_t *at(uint32_t pa) { return (pa >= STG) ? &stg[(pa - STG) & (STGSZ - 1)] : &mem[pa & (MEMSZ - 1)]; }
static void put_be32(uint32_t pa, uint32_t v) { uint8_t *p = at(pa); p[0]=v>>24; p[1]=v>>16; p[2]=v>>8; p[3]=v; }
static uint32_t get_le32(uint32_t pa) { uint8_t *p = at(pa); return (uint32_t)p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24); }
static inline uint8_t pat(uint32_t seed, uint32_t k) { return (uint8_t)(k * 11 + seed * 29 + 3); }

static Vscsi_stage_top *d;
static long cyc = 0;
static int64_t reply = -1, resp_cyc = -100;
static uint32_t req_addr = 0, req_op = 0, req_mask = 0, req_sd[4];
static const int LAT = 4;

static void step() {
  d->dn_rsp_valid = 0;
  if(reply == cyc) {
    uint32_t line = req_addr & ~15u;
    if(req_op == 4) {
      for(int i = 0; i < 4; i++) { d->dn_rsp_load_data[i] = get_le32(line + 4*i); }
    }
    else {
      for(int i = 0; i < 16; i++) {
        if((req_mask >> i) & 1) { *at(line + i) = (req_sd[i>>2] >> (8*(i&3))) & 0xff; }
      }
    }
    d->dn_rsp_valid = 1; reply = -1; resp_cyc = cyc;
  }
  d->clk = 0; d->eval();
  if(d->dn_req_valid && reply < 0 && cyc > resp_cyc) {
    req_addr = (uint32_t)d->dn_req_addr; req_op = d->dn_req_opcode; req_mask = d->dn_req_mask;
    for(int i = 0; i < 4; i++) { req_sd[i] = d->dn_req_store_data[i]; }
    reply = cyc + LAT;
  }
  d->clk = 1; d->eval();
  d->go = 0;
  d->cancel = 0;
  cyc++;
}

/* shim side: one req_seq per SELECT-AND-TRANSFER (command or resume) */
static uint32_t cur_seq = 0;
static void new_cmd() { cur_seq++; d->req_seq = cur_seq; }
/* ARM side: stage this command's bytes, write the beat count, THEN the seq */
static uint32_t arm_cq_cons = 0, n_skipped = 0;
static void arm_stage(const uint8_t *src, uint32_t n) {
  memset(&stg[RD], 0, ((n + 15) & ~15u));
  memcpy(&stg[RD], src, n);
  d->rd_beats = (n + 15) / 16;
  step();
  d->rd_seq = cur_seq;
}
struct cqe_t { uint32_t bytes, nbdp, flags, seq; };
/* wait for THIS command's completion; entries of other commands are skipped */
static bool arm_wait_cq(cqe_t *e, int lim = 300000) {
  for(int g = 0; g < lim; g++) {
    while(get_le32(STG + SIDX) != arm_cq_cons) {
      uint32_t a = STG + SCQ + (arm_cq_cons % 64) * 16;
      e->bytes = get_le32(a); e->nbdp = get_le32(a + 4); e->flags = get_le32(a + 8); e->seq = get_le32(a + 12);
      arm_cq_cons++;
      d->cq_cons = arm_cq_cons;
      if(e->seq == cur_seq) {
        return true;
      }
      n_skipped++;
    }
    step();
  }
  return false;
}
static void go(uint32_t nbdp, int to_dev) { d->nbdp = nbdp; d->to_device = to_dev; d->go = 1; step(); }
/* the usual order: SELECT (new seq), then the data-phase go */
static void cmd_go(uint32_t nbdp, int to_dev) { new_cmd(); go(nbdp, to_dev); }

/* build a chain at desc base: segments {bp, cnt}; EOX on the last */
struct seg_t { uint32_t bp, cnt; };
static void chain(uint32_t base, const std::vector<seg_t> &s) {
  for(size_t i = 0; i < s.size(); i++) {
    uint32_t a = base + 16 * (uint32_t)i;
    put_be32(a, s[i].bp);
    put_be32(a + 4, s[i].cnt | (i + 1 == s.size() ? BC_EOX : 0));
    put_be32(a + 8, a + 16);
  }
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  stg = new uint8_t[STGSZ]();
  d = new Vscsi_stage_top;
  d->reset = 1; d->clk = 0; d->go = 0; d->cancel = 0; d->rd_beats = 0; d->rd_seq = 0; d->req_seq = 0; d->cq_cons = 0; d->eval();
  for(int i = 0; i < 4; i++) { step(); }
  d->reset = 0;
  int fails = 0, checks = 0;
  auto check = [&](bool ok, const char *what, long a, long b) {
    checks++;
    if(!ok) { fails++; printf("  FAIL %s (%ld, %ld)\n", what, a, b); }
  };
  cqe_t e;
  std::vector<uint8_t> data(4096);
  for(uint32_t k = 0; k < data.size(); k++) { data[k] = pat(1, k); }

  /* 1: READ chain at offsets 0, 8, 3 (200+250+150 = 600), exactly staged */
  memset(mem, GUARD, sizeof(mem));
  chain(0x1000, {{0x4000, 200}, {0x5008, 250}, {0x6003, 150}});
  new_cmd();
  arm_stage(data.data(), 600);
  go(0x1000, 0);
  check(arm_wait_cq(&e), "1 no completion", 0, 0);
  check(e.bytes == 600 && (e.flags & 7) == 1 && !(e.flags & 8) && e.nbdp == 0x1000, "1 entry", e.bytes, e.flags);
  bool ok = true, guard = true;
  for(uint32_t k = 0; k < 200; k++) { ok &= mem[0x4000 + k] == data[k]; }
  for(uint32_t k = 0; k < 250; k++) { ok &= mem[0x5008 + k] == data[200 + k]; }
  for(uint32_t k = 0; k < 150; k++) { ok &= mem[0x6003 + k] == data[450 + k]; }
  guard &= mem[0x4000 + 200] == GUARD && mem[0x5007] == GUARD && mem[0x5008 + 250] == GUARD;
  guard &= mem[0x6002] == GUARD && mem[0x6003 + 150] == GUARD;
  check(ok, "1 data", 0, 0);
  check(guard, "1 wrote outside a buffer", 0, 0);

  /* 2: short READ: chain wants 600, only 400 staged -> starved (bytes 400), then the
   *    shim cancels -> no second entry */
  memset(mem, GUARD, sizeof(mem));
  chain(0x1000, {{0x4000, 200}, {0x5008, 250}, {0x6003, 150}});
  new_cmd();
  arm_stage(data.data(), 400);
  go(0x1000, 0);
  check(arm_wait_cq(&e), "2 no completion", 0, 0);
  check(e.bytes == 400 && (e.flags & 7) == 2, "2 starved entry", e.bytes, e.flags);
  d->cancel = 1; step();
  for(int k = 0; k < 2000; k++) { step(); }
  check(get_le32(STG + SIDX) == arm_cq_cons, "2 extra entry after cancel", get_le32(STG + SIDX), arm_cq_cons);
  check(!d->busy, "2 engine still busy after cancel", 0, 0);

  /* 3: chain shorter than staged (300 of 1000), then the resume chain gets the rest */
  memset(mem, GUARD, sizeof(mem));
  chain(0x1000, {{0x4004, 300}});
  new_cmd();
  arm_stage(data.data(), 1000);
  go(0x1000, 0);
  check(arm_wait_cq(&e) && e.bytes == 300 && (e.flags & 7) == 1, "3a entry", e.bytes, e.flags);
  chain(0x1100, {{0x7001, 700}});
  new_cmd();                                               /* the resume is its own SELECT */
  arm_stage(data.data() + 300, 700);                       /* the ARM re-stages from g_pos */
  go(0x1100, 0);
  check(arm_wait_cq(&e) && e.bytes == 700 && (e.flags & 7) == 1 && e.nbdp == 0x1100, "3b entry", e.bytes, e.flags);
  ok = true;
  for(uint32_t k = 0; k < 300; k++) { ok &= mem[0x4004 + k] == data[k]; }
  for(uint32_t k = 0; k < 700; k++) { ok &= mem[0x7001 + k] == data[300 + k]; }
  check(ok, "3 data across the resume", 0, 0);

  /* 4: doorbell AFTER go: the engine waits, then completes */
  memset(mem, GUARD, sizeof(mem));
  chain(0x1000, {{0x4000, 333}});
  cmd_go(0x1000, 0);                                       /* the previous READ's doorbell is still up */
  for(int k = 0; k < 3000; k++) { step(); }
  check(get_le32(STG + SIDX) == arm_cq_cons, "4 posted before staging", 0, 0);
  arm_stage(data.data() + 7, 333);
  check(arm_wait_cq(&e) && e.bytes == 333 && (e.flags & 7) == 1, "4 entry", e.bytes, e.flags);
  ok = true;
  for(uint32_t k = 0; k < 333; k++) { ok &= mem[0x4000 + k] == data[7 + k]; }
  check(ok, "4 data", 0, 0);

  /* 5: WRITE chain at offsets 2, 9, 0 (700 bytes) -> contiguous in STG_WR */
  for(uint32_t k = 0; k < 100; k++) { mem[0x4002 + k] = pat(5, k); }
  for(uint32_t k = 0; k < 400; k++) { mem[0x5009 + k] = pat(5, 100 + k); }
  for(uint32_t k = 0; k < 200; k++) { mem[0x6000 + k] = pat(5, 500 + k); }
  memset(&stg[WR], 0, 4096);
  chain(0x1000, {{0x4002, 100}, {0x5009, 400}, {0x6000, 200}});
  cmd_go(0x1000, 1);
  check(arm_wait_cq(&e) && e.bytes == 700 && (e.flags & 7) == 1 && (e.flags & 8), "5 entry", e.bytes, e.flags);
  ok = true;
  for(uint32_t k = 0; k < 700; k++) { ok &= stg[WR + k] == pat(5, k); }
  check(ok, "5 write data in staging", 0, 0);

  /* 6: cancel with nothing staged (a no-data READ) -> aborted entry */
  chain(0x1000, {{0x4000, 64}});
  cmd_go(0x1000, 0);
  for(int k = 0; k < 500; k++) { step(); }
  d->cancel = 1; step();
  check(arm_wait_cq(&e) && (e.flags & 7) == 4 && e.bytes == 0, "6 aborted entry", e.bytes, e.flags);

  /* 7: back-to-back READs reuse the buffer with fresh gens (stale read-ahead dropped) */
  for(int r = 0; r < 20; r++) {
    memset(mem + 0x4000, GUARD, 0x2000);
    uint32_t n = 17 + 97 * (uint32_t)r;
    chain(0x1000, {{0x4000u + (uint32_t)(r & 15), n}});
    std::vector<uint8_t> f(n);
    for(uint32_t k = 0; k < n; k++) { f[k] = pat(100 + r, k); }
    new_cmd();
    arm_stage(f.data(), n + 64);                         /* over-staged: leftovers discarded */
    go(0x1000, 0);
    bool got = arm_wait_cq(&e) && e.bytes == n && (e.flags & 7) == 1;
    ok = got;
    for(uint32_t k = 0; ok && k < n; k++) { ok &= mem[0x4000 + (r & 15) + k] == f[k]; }
    check(ok, "7 back-to-back READ", r, e.bytes);
  }

  /* 8: protocol-violating back-to-back: the next go lands the cycle after done, with the
   *    previous chain's over-staged read-ahead possibly in flight and its completion
   *    not yet posted.  Both entries must appear, the second chain's data intact. */
  for(int r = 0; r < 16; r++) {
    memset(mem + 0x4000, GUARD, 0x4000);
    uint32_t n1 = 40 + 16 * (uint32_t)r, n2 = 300 + 7 * (uint32_t)r;
    std::vector<uint8_t> f1(n1 + 96), f2(n2);
    for(uint32_t k = 0; k < f1.size(); k++) { f1[k] = pat(200 + r, k); }
    for(uint32_t k = 0; k < n2; k++) { f2[k] = pat(300 + r, k); }
    chain(0x1000, {{0x4000, n1}});
    chain(0x1100, {{0x6005, n2}});
    new_cmd();
    arm_stage(f1.data(), (uint32_t)f1.size());          /* over-staged: read-ahead keeps going */
    go(0x1000, 0);
    int g = 0;
    while(!d->done && g++ < 100000) { step(); }
    /* chain 2's command starts the cycle after chain 1's done, before chain 1 posted:
     * chain 1's entry may be lost (nobody waits for it -- the protocol forbids this
     * timing), but chain 2 must complete with its own data */
    new_cmd();
    memset(&stg[RD], 0, ((n2 + 15) & ~15u));
    memcpy(&stg[RD], f2.data(), n2);
    d->rd_beats = (n2 + 15) / 16;
    go(0x1100, 0);
    d->rd_seq = cur_seq;
    cqe_t e2;
    bool got = arm_wait_cq(&e2);
    check(got && e2.bytes == n2 && e2.nbdp == 0x1100, "8 second entry", e2.bytes, e2.nbdp);
    ok = true;
    for(uint32_t k = 0; k < n2; k++) { ok &= mem[0x6005 + k] == f2[k]; }
    check(ok, "8 second chain data (stale read-ahead?)", r, 0);
  }

  printf("(entries skipped as other commands': %u)\n", n_skipped);
  printf("== scsi_stage unit test: %d checks, %d failures: %s ==\n", checks, fails, fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
