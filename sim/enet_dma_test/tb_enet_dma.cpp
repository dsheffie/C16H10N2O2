// Standalone unit test for enet_dma.sv: RX deposit and TX gather through a model
// DRAM port and the two 16-deep host beat FIFOs.  Byte order mirrors henry (line
// lane = little-endian bytes of mem; descriptor words big-endian).
//
// The model port stores to the 16B-ALIGNED line holding req_addr, like the real
// arbiter/L2 path: an engine that sends an unaligned address with an unshifted
// mask writes the wrong bytes here, as it does on silicon.  Guard bytes around
// every RX buffer catch any write outside [BP, BP+len).
//
// Cases: RX at every BP offset 0..15 x several lengths; RX drop (ROWN=0) followed
// by a good frame (the dropped frame's beats must be drained); RX clamp (frame >
// buffer) followed by a good frame; TX multi-descriptor chain at odd offsets with a
// slow consumer (backpressure: no beat may be lost).
#include "Venet_dma.h"
#include "verilated.h"
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <deque>
#include <vector>

static const uint32_t MEMSZ = 1u << 18;
static uint8_t mem[MEMSZ];
static void put_be32(uint32_t pa, uint32_t v) { mem[pa]=v>>24; mem[pa+1]=v>>16; mem[pa+2]=v>>8; mem[pa+3]=v; }
static uint32_t get_be32(uint32_t pa) { return ((uint32_t)mem[pa]<<24)|((uint32_t)mem[pa+1]<<16)|((uint32_t)mem[pa+2]<<8)|mem[pa+3]; }

static const uint32_t BC_ROWN = 0x4000u, BC_ETXD = 0x8000u, BC_EOX = 0x80000000u;
static const uint8_t GUARD = 0xa5;
static inline uint8_t pat(uint32_t seed, uint32_t k) { return (uint8_t)(k * 7 + seed * 13 + 1); }

struct beat_t { uint32_t w[4]; };

static Venet_dma *d;
static long cyc = 0;
static int64_t reply = -1, resp_cyc = -100;
static uint32_t req_addr = 0, req_op = 0, req_mask = 0, req_sd[4];
static uint32_t last_addr = 0xffffffff, last_op = 0xff;
static const int LAT = 4;
static std::deque<beat_t> rx_src, rx_fifo, tx_fifo;
static int tx_pop_period = 1;
static std::vector<uint8_t> tx_out;
static int n_rx_done = 0, n_rx_drop = 0, n_tx_done = 0;

static beat_t pack(const uint8_t *b) {
  beat_t t;
  for(int i = 0; i < 4; i++) {
    t.w[i] = (uint32_t)b[4*i] | ((uint32_t)b[4*i+1]<<8) | ((uint32_t)b[4*i+2]<<16) | ((uint32_t)b[4*i+3]<<24);
  }
  return t;
}

static void step(int rx_go, uint32_t rx_nbdp, uint32_t rx_len, int tx_go, uint32_t tx_nbdp) {
  d->rx_go = rx_go; d->rx_nbdp = rx_nbdp; d->rx_len = rx_len;
  d->tx_go = tx_go; d->tx_nbdp = tx_nbdp;
  d->dma_rsp_valid = 0;
  if(reply == cyc) {
    uint32_t line = req_addr & ~15u;
    if(req_op == 4) {
      for(int i = 0; i < 4; i++) {
        uint32_t a = (line + 4*i) & (MEMSZ-1);
        d->dma_rsp_load_data[i] = (uint32_t)mem[a] | ((uint32_t)mem[a+1]<<8) | ((uint32_t)mem[a+2]<<16) | ((uint32_t)mem[a+3]<<24);
      }
    }
    else if(req_op == 7) {
      for(int i = 0; i < 16; i++) {
        if((req_mask >> i) & 1) {
          mem[(line + i) & (MEMSZ-1)] = (req_sd[i>>2] >> (8*(i&3))) & 0xff;
        }
      }
    }
    d->dma_rsp_valid = 1; reply = -1; resp_cyc = cyc;
  }
  d->rx_rd_valid = !rx_fifo.empty();
  if(!rx_fifo.empty()) {
    for(int i = 0; i < 4; i++) { d->rx_rd_data[i] = rx_fifo.front().w[i]; }
  }
  d->tx_wr_full = tx_fifo.size() >= 16;
  d->clk = 0; d->eval();
  if(d->dma_req_valid && reply < 0 && cyc > resp_cyc &&
     (d->dma_req_addr != last_addr || d->dma_req_opcode != last_op)) {
    req_addr = d->dma_req_addr; req_op = d->dma_req_opcode; req_mask = d->dma_req_mask;
    for(int i = 0; i < 4; i++) { req_sd[i] = d->dma_req_store_data[i]; }
    reply = cyc + LAT; last_addr = req_addr; last_op = req_op;
  }
  int rd_en = d->rx_rd_en, wr_en = d->tx_wr_en;
  beat_t wb;
  for(int i = 0; i < 4; i++) { wb.w[i] = d->tx_wr_data[i]; }
  d->clk = 1; d->eval();
  if(rd_en) { rx_fifo.pop_front(); }
  if(wr_en && tx_fifo.size() < 16) { tx_fifo.push_back(wb); }   /* full: dropped, like scsi_beat_fifo */
  if(!rx_src.empty() && rx_fifo.size() < 16) { rx_fifo.push_back(rx_src.front()); rx_src.pop_front(); }
  if(!tx_fifo.empty() && (cyc % tx_pop_period) == 0) {
    for(int k = 0; k < 16; k++) { tx_out.push_back((tx_fifo.front().w[k/4] >> (8*(k&3))) & 0xff); }
    tx_fifo.pop_front();
  }
  if(d->rx_done) { n_rx_done++; }
  if(d->rx_dropped) { n_rx_drop++; }
  if(d->tx_done) { n_tx_done++; }
  cyc++;
}

/* run one RX frame: go, feed beats, wait for done/drop.  Returns 1 done, 2 drop, 0 timeout */
static int rx_frame(uint32_t nbdp, const std::vector<uint8_t> &f) {
  int dn = n_rx_done, dr = n_rx_drop;
  std::vector<uint8_t> pad(f);
  pad.resize((f.size() + 15) & ~15u, 0);
  for(size_t b = 0; b < pad.size(); b += 16) { rx_src.push_back(pack(&pad[b])); }
  step(1, nbdp, (uint32_t)f.size(), 0, 0);
  for(int g = 0; g < 200000; g++) {
    if(n_rx_done != dn) { return 1; }
    if(n_rx_drop != dr) { return 2; }
    step(0, 0, 0, 0, 0);
  }
  return 0;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Venet_dma;
  d->reset = 1; d->clk = 0; d->eval();
  for(int i = 0; i < 4; i++) { step(0,0,0,0,0); }
  d->reset = 0;
  int fails = 0, checks = 0;
  auto check = [&](bool ok, const char *fmt, int a, int b) {
    checks++;
    if(!ok) { fails++; printf("  FAIL "); printf(fmt, a, b); printf("\n"); }
  };

  /* ---- RX: every BP offset x lengths; guard bytes on both sides ---- */
  const uint32_t lens[] = {3, 15, 16, 17, 61, 64, 310, 1517};
  const uint32_t BUFSZ = 1600;
  uint32_t seed = 0;
  for(uint32_t off = 0; off < 16; off++) {
    for(uint32_t len : lens) {
      seed++;
      memset(mem, GUARD, sizeof(mem));
      uint32_t bp = 0x4000 + off;
      put_be32(0x1000, bp); put_be32(0x1004, BC_ROWN | 0x20000000u | BUFSZ); put_be32(0x1008, 0x1010);
      std::vector<uint8_t> f(len);
      for(uint32_t k = 0; k < len; k++) { f[k] = pat(seed, k); }
      int r = rx_frame(0x1000, f);
      check(r == 1, "RX off %d len %d: no rx_done", off, len);
      bool data = true, guard = true;
      for(uint32_t k = 0; k < len; k++) { data &= mem[bp + k] == f[k]; }
      for(uint32_t a = 0x3f00; a < bp; a++) { guard &= mem[a] == GUARD; }
      for(uint32_t a = bp + len; a < bp + BUFSZ + 64; a++) { guard &= mem[a] == GUARD; }
      check(data, "RX off %d len %d: data mismatch", off, len);
      check(guard, "RX off %d len %d: wrote outside the frame", off, len);
      uint32_t bc = get_be32(0x1004);
      check(!(bc & BC_ROWN) && (bc & 0x3fff) == BUFSZ - len, "RX off %d len %d: bad BC writeback", off, len);
      check(rx_fifo.empty() && rx_src.empty(), "RX off %d len %d: beats left in FIFO", off, len);
    }
  }
  printf("RX offsets x lengths: %d checks\n", checks);

  /* ---- RX drop then a good frame: the dropped frame's beats must not leak ---- */
  memset(mem, GUARD, sizeof(mem));
  put_be32(0x1000, 0x4008); put_be32(0x1004, 0x20000000u | BUFSZ); put_be32(0x1008, 0x1010);   /* ROWN=0 */
  put_be32(0x1010, 0x5008); put_be32(0x1014, BC_ROWN | BUFSZ);     put_be32(0x1018, 0x1020);
  std::vector<uint8_t> f1(100), f2(77);
  for(uint32_t k = 0; k < 100; k++) { f1[k] = pat(901, k); }
  for(uint32_t k = 0; k < 77; k++) { f2[k] = pat(902, k); }
  check(rx_frame(0x1000, f1) == 2, "RX drop: expected rx_dropped %d %d", 0, 0);
  check(rx_fifo.empty() && rx_src.empty(), "RX drop: %d beats left (src %d)", (int)rx_fifo.size(), (int)rx_src.size());
  bool untouched = true;
  for(uint32_t a = 0x4000; a < 0x4000 + 200; a++) { untouched &= mem[a] == GUARD; }
  check(untouched, "RX drop: buffer written %d %d", 0, 0);
  check(rx_frame(0x1010, f2) == 1, "RX after drop: no rx_done %d %d", 0, 0);
  bool ok2 = true;
  for(uint32_t k = 0; k < 77; k++) { ok2 &= mem[0x5008 + k] == f2[k]; }
  check(ok2, "RX after drop: data mismatch (stale beats?) %d %d", 0, 0);

  /* ---- RX clamp: 100B frame into a 64B buffer, then a good frame ---- */
  memset(mem, GUARD, sizeof(mem));
  put_be32(0x1000, 0x4008); put_be32(0x1004, BC_ROWN | 64);   put_be32(0x1008, 0x1010);
  put_be32(0x1010, 0x5004); put_be32(0x1014, BC_ROWN | BUFSZ); put_be32(0x1018, 0x1020);
  check(rx_frame(0x1000, f1) == 1, "RX clamp: no rx_done %d %d", 0, 0);
  bool ok3 = true, g3 = true;
  for(uint32_t k = 0; k < 64; k++) { ok3 &= mem[0x4008 + k] == f1[k]; }
  for(uint32_t a = 0x4008 + 64; a < 0x4100; a++) { g3 &= mem[a] == GUARD; }
  check(ok3 && g3, "RX clamp: data %d guard %d", ok3, g3);
  check(rx_frame(0x1010, f2) == 1, "RX after clamp: no rx_done %d %d", 0, 0);
  bool ok4 = true;
  for(uint32_t k = 0; k < 77; k++) { ok4 &= mem[0x5004 + k] == f2[k]; }
  check(ok4, "RX after clamp: data mismatch %d %d", 0, 0);

  /* ---- TX: 3 descriptors at odd offsets, 310B total, slow consumer ---- */
  for(int period : {1, 200}) {
    memset(mem, 0, sizeof(mem));
    tx_out.clear(); tx_pop_period = period;
    const uint32_t bps[3] = {0x6002, 0x7008, 0x8000}, cnts[3] = {100, 150, 60};
    std::vector<uint8_t> want;
    for(int i = 0; i < 3; i++) {
      uint32_t a = 0x1100 + 16*i;
      put_be32(a, bps[i]); put_be32(a + 4, cnts[i] | (i == 2 ? BC_EOX : 0)); put_be32(a + 8, a + 16);
      for(uint32_t k = 0; k < cnts[i]; k++) { mem[bps[i] + k] = pat(950 + i, k); want.push_back(pat(950 + i, k)); }
    }
    int td = n_tx_done;
    step(0, 0, 0, 1, 0x1100);
    int g = 0;
    for(; g < 400000 && n_tx_done == td; g++) { step(0, 0, 0, 0, 0); }
    for(int k = 0; k < 4000; k++) { step(0, 0, 0, 0, 0); }   /* let the consumer drain */
    check(n_tx_done != td, "TX period %d: no tx_done (%d)", period, g);
    check(d->tx_len == 310, "TX period %d: tx_len %d", period, (int)d->tx_len);
    bool same = tx_out.size() >= 310;
    for(uint32_t k = 0; same && k < 310; k++) { same &= tx_out[k] == want[k]; }
    check(same, "TX period %d: gathered bytes wrong (got %d)", period, (int)tx_out.size());
    check((get_be32(0x1104) & BC_ETXD) && (get_be32(0x1124) & BC_ETXD), "TX period %d: ETXD not set %d", period, 0);
  }

  printf("== enet_dma unit test: %d checks, %d failures: %s ==\n", checks, fails, fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
