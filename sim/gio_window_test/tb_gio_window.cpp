// tb_gio_window.cpp -- unit test for rtl/gio_window.sv (docs/newport-on-henry.md).
// A CPU model (one access outstanding, random stores/loads) against an ARM model
// that consumes the capture ring at a random rate and answers READs.  Built with a
// 16-record ring (-GLG_RING_N=4) so ring-full back-pressure is exercised.
//   make -C sim/gio_window_test && ./sim/gio_window_test/obj_dir/Vgio_window
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <cstdlib>
#include <deque>
#include <vector>
#include <map>
#include "Vgio_window.h"
#include "verilated.h"

static const uint32_t BASE = 0x1f0f0000u, RING_PA = 0x1e200000u, PROD_PA = 0x1e000060u;
static const uint32_t RING_N = 16;
static long g_checks = 0, g_fail = 0;
#define CHECK(c, ...) do { g_checks++; if(!(c)) { g_fail++; if(g_fail <= 20) { fprintf(stderr, "FAIL: " __VA_ARGS__); fprintf(stderr, "\n"); } } } while(0)

struct access_t { bool store; uint32_t dwoff; uint8_t mask; uint64_t lanes; bool space; };
static std::map<uint32_t, std::vector<uint8_t>> g_mem;   /* 16-byte lines */
static uint8_t *line(uint32_t pa) { auto &v = g_mem[pa & ~15u]; if(v.empty()) { v.assign(16, 0); } return v.data(); }
static uint64_t answer_for(uint32_t recno, uint32_t dwoff) { return (uint64_t)recno * 0x9e3779b97f4a7c15ull ^ dwoff; }

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  Vgio_window *t = new Vgio_window;
  auto tick = [&]() { t->clk = 0; t->eval(); t->clk = 1; t->eval(); };
  t->reset = 1; t->sel = 0; t->mem_rsp_valid = 0; t->cons = 0; t->ans_seq = 0;
  for(int i = 0; i < 4; i++) { tick(); }
  t->reset = 0;

  srand(1);
  std::deque<access_t> issued;          /* accesses in CPU order, for the ARM-side check */
  uint32_t expect_recno = 1, cons = 0, arm_prod_seen = 0;
  bool cpu_busy = false; access_t cur{}; uint64_t cpu_wait = 0, max_wait = 0;
  int mem_lat = -1; long n_loads = 0, n_stores = 0, n_held_full = 0;
  uint32_t pending_ans_seq = 0; int ans_delay = -1; uint64_t pending_ans_val = 0;
  long arm_pause = 0, n_ring_full = 0;   /* the ARM thread goes away for a while: the ring fills */
  const long CYCLES = 400000;
  for(long cyc = 0; cyc < CYCLES; cyc++) {
    /* ---- CPU: one access outstanding ---- */
    t->sel = 0;
    if(!cpu_busy && (rand() % 3) == 0) {
      cur.store = (rand() % 5) != 0;
      cur.dwoff = rand() % 1024;
      int sz = 1 << (rand() % 4);                      /* 1,2,4,8 bytes, naturally aligned */
      int off = (rand() % (8 / sz)) * sz;
      cur.mask = (uint8_t)(((1u << sz) - 1) << off);
      cur.lanes = 0;
      for(int i = 0; i < 8; i++) { if((cur.mask >> i) & 1) { cur.lanes |= (uint64_t)(rand() & 0xff) << (8 * i); } }
      uint32_t pa = BASE + cur.dwoff * 8;
      t->addr = pa & ~15u;
      bool hi = pa & 8;
      t->mask = hi ? (cur.mask << 8) : cur.mask;
      for(int w = 0; w < 4; w++) { t->wdata[w] = 0; }
      uint64_t lanes = cur.store ? cur.lanes : 0;
      t->wdata[hi ? 2 : 0] = (uint32_t)lanes; t->wdata[hi ? 3 : 1] = (uint32_t)(lanes >> 32);
      t->is_store = cur.store;
      cur.space = (rand() % 4) == 0;                   /* the second ARM-served device */
      t->space = cur.space;
      t->eval();
      CHECK(t->hit, "hit for in-window address");
      t->sel = 1; cpu_busy = true; cpu_wait = 0;
      issued.push_back(cur);
      if(cur.store) { n_stores++; } else { n_loads++; }
    }
    /* ---- memory: random latency, one outstanding ---- */
    t->mem_rsp_valid = 0;
    if(t->mem_req_valid) {
      if(mem_lat < 0) { mem_lat = rand() % 5; }
      else if(mem_lat-- == 0) {
        uint32_t a = (uint32_t)t->mem_req_addr;
        CHECK(t->mem_req_opcode == 7, "store opcode");
        uint8_t *l = line(a);
        for(int b = 0; b < 16; b++) { if((t->mem_req_mask >> b) & 1) { l[b] = (uint8_t)(t->mem_req_store_data[b / 4] >> (8 * (b % 4))); } }
        t->mem_rsp_valid = 1; mem_lat = -1;
      }
    }
    tick();
    if(cpu_busy) {
      cpu_wait++;
      if(t->done) {
        cpu_busy = false; max_wait = std::max(max_wait, cpu_wait);
        if(!cur.store) {
          uint64_t got = ((uint64_t)t->rdata[1] << 32) | t->rdata[0];
          CHECK(got == pending_ans_val, "load answer %llx != %llx", (unsigned long long)got, (unsigned long long)pending_ans_val);
        }
      }
    }
    /* ---- ARM: read prod, consume records at a random rate, answer READs ---- */
    uint32_t prod; memcpy(&prod, line(PROD_PA) + (PROD_PA & 15), 4);
    CHECK(prod >= arm_prod_seen, "prod went backwards");
    arm_prod_seen = prod;
    if(ans_delay > 0 && --ans_delay == 0) { t->ans_seq = pending_ans_seq; }
    if(arm_pause > 0) { arm_pause--; }
    else if((rand() % 2000) == 0) { arm_pause = 100 + rand() % 400; }
    if(cpu_busy && cur.store && (t->prod - cons) >= RING_N - 2) { n_ring_full++; }
    if(arm_pause == 0 && ans_delay <= 0 && cons < prod && (rand() % 4) == 0) {
      const uint8_t *r = line(RING_PA + (cons % RING_N) * 16);
      uint32_t w0, recno; uint64_t lanes;
      memcpy(&w0, r, 4); memcpy(&recno, r + 4, 4); memcpy(&lanes, r + 8, 8);
      CHECK(recno == expect_recno, "recno %u != expected %u (slot overwritten or skipped)", recno, expect_recno);
      CHECK(!issued.empty(), "record with no access");
      if(!issued.empty()) {
        access_t a = issued.front(); issued.pop_front();
        CHECK(((w0 >> 30) & 3) == (a.store ? 0u : 1u), "type");
        CHECK(((w0 >> 22) & 0xff) == a.mask, "mask %x != %x", (w0 >> 22) & 0xff, a.mask);
        CHECK((w0 & 0x1fffff) == a.dwoff, "dwoff %u != %u", w0 & 0x1fffff, a.dwoff);
        CHECK(((w0 >> 21) & 1) == (a.space ? 1u : 0u), "space bit");
        if(a.store) {
          CHECK(lanes == a.lanes, "store lanes");
        }
        else {
          CHECK(issued.empty(), "READ consumed with later accesses already issued (CPU should be held)");
          pending_ans_val = answer_for(recno, a.dwoff);
          t->ans_lo = (uint32_t)pending_ans_val; t->ans_hi = (uint32_t)(pending_ans_val >> 32);
          pending_ans_seq = recno; ans_delay = 1 + rand() % 50;   /* answer later, seq written last */
        }
      }
      expect_recno++; cons++;
      t->cons = cons;
    }
    if(cpu_busy && cur.store && cpu_wait > 3) { n_held_full++; }
  }
  printf("stores %ld loads %ld | held-store cycles %ld (ring near full %ld) | max CPU wait %llu cycles | records %u\n",
         n_stores, n_loads, n_held_full, n_ring_full, (unsigned long long)max_wait, expect_recno - 1);
  CHECK(n_ring_full > 300, "ring-full back-pressure was not exercised (%ld cycles)", n_ring_full);
  printf("%ld checks, %ld failures\n", g_checks, g_fail);
  delete t;
  return g_fail ? 1 : 0;
}
