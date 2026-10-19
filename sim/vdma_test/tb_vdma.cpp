// Unit test for dma_engine's VDMA channel (the MC's memory -> GIO transfer).
// Reference = indysim sgi_mc.cc dma_perform (memory -> GIO branch) + dma_translate,
// run on the same memory image: every doubleword the channel hands to the GIO window
// must match, in order, and DMA_MEMADR after the transfer must match.
// Memory: 16 MB, big-endian bytes; a line load returns lane i = byte line + i.  One
// access outstanding with a random latency; the GIO window's ready is random.
#include "Vdma_engine.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <vector>

static const uint32_t MEMSZ = 1u << 24;
static uint8_t mem[MEMSZ];
static uint32_t tlb_hi[4], tlb_lo[4];

static uint32_t get_be32(uint32_t pa) {
  return ((uint32_t)mem[pa] << 24) | ((uint32_t)mem[pa + 1] << 16) | ((uint32_t)mem[pa + 2] << 8) | mem[pa + 3];
}
static void put_be32(uint32_t pa, uint32_t v) {
  mem[pa] = v >> 24; mem[pa + 1] = v >> 16; mem[pa + 2] = v >> 8; mem[pa + 3] = v;
}

/* ---- reference: indysim's dma_translate + dma_perform (memory -> GIO) ---- */
static uint32_t ref_translate(uint32_t va) {
  for(int e = 0; e < 4; e++) {
    if((va & 0xffc00000u) == (tlb_hi[e] & 0xffc00000u)) {
      const uint32_t pte_pa = ((tlb_lo[e] & 0x03ffffc0u) << 6) + (((va & 0x003ff000u) >> 12) << 2);
      const uint32_t pte = get_be32(pte_pa);
      return ((pte & 0x03ffffc0u) << 6) + (va & 0xfffu);
    }
  }
  return va;
}
static uint32_t ref_perform(uint32_t memadr, uint32_t size, uint32_t stride_r, uint32_t count,
                            std::vector<uint64_t> &out) {
  uint32_t m = memadr;
  uint32_t lines = size >> 16;
  uint32_t zoom = (count >> 16) & 0x3ff;
  uint32_t bytes = count & 0xffff;
  const uint32_t width = size & 0xffff, line_zoom = (stride_r >> 16) & 0x3ff;
  const int16_t stride = (int16_t)stride_r;
  while(lines > 0) {
    lines--;
    while(zoom > 0) {
      zoom--;
      while(bytes > 0) {
        const uint32_t len = bytes < 8 ? bytes : 8;
        uint64_t d = 0;
        for(uint32_t i = 0; i < len; i++) {
          d |= (uint64_t)mem[ref_translate(m) & (MEMSZ - 1)] << (56 - 8 * i);
          m++;
        }
        out.push_back(__builtin_bswap64(d));    /* lane i = bits [8i+7:8i] */
        bytes -= len;
      }
      bytes = width;
      if(zoom > 0) {
        m -= width;
      }
    }
    zoom = line_zoom;
    m += stride;
  }
  return m;
}

/* ---- DUT harness ---- */
static Vdma_engine *d;
static long cyc = 0;
static int64_t reply = -1;
static uint32_t req_addr = 0, req_op = 0;
static long n_loads = 0;
static std::vector<uint64_t> got;
static uint32_t got_gio = 0;
static int ready_pct = 70;
static bool g_verbose = false;

static void step() {
  d->dn_rsp_valid = 0;
  if(reply == cyc) {
    const uint32_t line = req_addr & ~15u;
    if(req_op != 4 || line >= MEMSZ) {
      printf("FAIL: bad access op %u addr %08x\n", req_op, req_addr);
      exit(1);
    }
    for(int i = 0; i < 4; i++) {
      d->dn_rsp_load_data[i] = (uint32_t)mem[line + 4*i] | ((uint32_t)mem[line + 4*i + 1] << 8) |
        ((uint32_t)mem[line + 4*i + 2] << 16) | ((uint32_t)mem[line + 4*i + 3] << 24);
    }
    d->dn_rsp_valid = 1;
    reply = -1;
    n_loads++;
  }
  d->v_rec_ready = (rand() % 100) < ready_pct;
  d->clk = 0; d->eval();
  if(d->v_rec_valid && d->v_rec_ready) {
    got.push_back(d->v_rec_lanes);
    got_gio = d->v_rec_addr;
  }
  if(d->dn_req_valid && reply < 0 && !d->dn_rsp_valid) {
    req_addr = (uint32_t)d->dn_req_addr; req_op = d->dn_req_opcode;
    if(g_verbose) {
      printf("  load %08x\n", req_addr);
    }
    reply = cyc + 1 + rand() % 6;
  }
  d->clk = 1; d->eval();
  d->v_go = 0;
  cyc++;
}

static uint32_t rnd() { return ((uint32_t)rand() << 16) ^ (uint32_t)rand(); }

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Vdma_engine;
  srand(argc > 1 ? atoi(argv[1]) : 1);
  for(uint32_t i = 0; i < MEMSZ; i++) {
    mem[i] = (uint8_t)rand();
  }
  d->reset = 1; d->go = 0; d->tx_go = 0; d->rx_armed = 0; d->v_go = 0;
  for(int i = 0; i < 5; i++) { step(); }
  d->reset = 0;
  const int NT = 3000;
  long total_recs = 0;
  int n_phys = 0, n_zoom = 0, n_negstride = 0;
  for(int t = 0; t < NT; t++) {
    /* four TLB entries: distinct 4 MB VA regions above 1 GB (so a physical address
     * < 16 MB never matches), each with its own page of PTEs */
    for(int e = 0; e < 4; e++) {
      tlb_hi[e] = (0x40000000u + (uint32_t)(e * 7 + 1 + (t % 5)) * 0x00400000u) | (rnd() & 0x003fffffu);
      const uint32_t ptpage = (0x00100000u + (rnd() % 3800) * 0x1000u) & (MEMSZ - 1);
      tlb_lo[e] = ((ptpage >> 6) & 0x03ffffc0u) | (rnd() & 0x3fu) | (rnd() & 0xfc000000u);
      for(uint32_t k = 0; k < 1024; k++) {
        const uint32_t frame = 0x00010000u + (rnd() % 4000) * 0x1000u;
        put_be32(ptpage + 4 * k, ((frame >> 6) & 0x03ffffc0u) | (rnd() & 0x3fu));
      }
    }
    if(t % 7 == 3) {
      /* a stale duplicate: entry 2 shadows entry 1's region (the first match wins) */
      tlb_hi[2] = tlb_hi[1];
    }
    const uint32_t lines = rand() % 7;
    const uint32_t width = 1 + rand() % 40;
    const uint32_t lzoom = (rand() % 4 == 0) ? (rand() % 4) : 1;
    const int16_t stride = (int16_t)((rand() % 130) - 64);
    const uint32_t cbytes = (rand() % 4 == 0) ? (uint32_t)(rand() % 41) : width;
    const uint32_t czoom = (rand() % 4 == 0) ? (uint32_t)(rand() % 4) : lzoom;
    uint32_t memadr;
    if(rand() % 4 == 0) {
      memadr = 0x00100000u + rnd() % 0x00e00000u;      /* no entry: physical */
      n_phys++;
    }
    else {
      memadr = (tlb_hi[rand() % 4] & 0xffc00000u) + 0x00010000u + rnd() % 0x003e0000u;
    }
    const uint32_t size = (lines << 16) | width;
    const uint32_t stride_r = (lzoom << 16) | (uint16_t)stride;
    const uint32_t count = (czoom << 16) | cbytes;
    const uint32_t gio = 0x1f0f0000u + ((rnd() % 0x400) << 3);
    n_zoom += (lzoom != 1 || czoom != 1);
    n_negstride += (stride < 0);
    ready_pct = (t % 3 == 0) ? 100 : 20 + rand() % 70;

    std::vector<uint64_t> exp;
    const uint32_t exp_end = ref_perform(memadr, size, stride_r, count, exp);
    got.clear();
    g_verbose = (getenv("VDBG") != nullptr) && (t == atoi(getenv("VDBG")));
    if(g_verbose) {
      printf("t=%d memadr %08x -> %08x lines %u width %u\n", t, memadr, ref_translate(memadr), lines, width);
      for(int e = 0; e < 4; e++) {
        printf("  tlb %d hi %08x lo %08x\n", e, tlb_hi[e], tlb_lo[e]);
      }
    }
    d->v_memadr = memadr; d->v_size = size; d->v_stride = stride_r; d->v_count = count; d->v_gio = gio;
    for(int e = 0; e < 4; e++) {
      d->v_tlb_hi[e] = tlb_hi[e];
      d->v_tlb_lo[e] = tlb_lo[e];
    }
    d->v_go = 1;
    long t0 = cyc;
    bool done = false;
    while(!done) {
      step();
      done = d->v_done;
      if(cyc - t0 > 2000000) {
        printf("FAIL t=%d: no v_done\n", t);
        return 1;
      }
    }
    if(got.size() != exp.size()) {
      printf("FAIL t=%d: %zu doublewords, expected %zu (lines %u width %u zoom %u/%u count %u stride %d memadr %08x)\n",
             t, got.size(), exp.size(), lines, width, czoom, lzoom, cbytes, stride, memadr);
      return 1;
    }
    for(size_t i = 0; i < exp.size(); i++) {
      if(got[i] != exp[i]) {
        printf("FAIL t=%d: doubleword %zu = %016lx, expected %016lx (memadr %08x width %u)\n",
               t, i, (unsigned long)got[i], (unsigned long)exp[i], memadr, width);
        return 1;
      }
    }
    if(!exp.empty() && got_gio != gio) {
      printf("FAIL t=%d: GIO address %08x, expected %08x\n", t, got_gio, gio);
      return 1;
    }
    if(d->v_memadr_end != exp_end) {
      printf("FAIL t=%d: memadr after %08x, expected %08x\n", t, d->v_memadr_end, exp_end);
      return 1;
    }
    total_recs += (long)exp.size();
    for(int i = 0; i < 3; i++) { step(); }
  }
  printf("transfers %d (physical %d, zoomed %d, negative stride %d), doublewords %ld, loads %ld, cycles %ld\n",
         NT, n_phys, n_zoom, n_negstride, total_recs, n_loads, cyc);
  printf("PASS\n");
  delete d;
  return 0;
}
