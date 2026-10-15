// Unit test for enet_ring_dma.sv against the staging-ring protocol
// (docs/arm-device-protocol.md).  Model DRAM port as in tb_enet_dma.cpp: stores go
// to the 16B-ALIGNED line holding req_addr, guest descriptor words big-endian,
// line lanes little-endian.  Guest memory and staging (PA 0x1e000000+) are separate
// arrays, so a staging access can never alias a guest one.
#include "Venet_ring_dma.h"
#include "verilated.h"
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <map>
#include <vector>

static const uint32_t MEMSZ = 1u << 18;            // guest: 256 KB
static const uint32_t STGSZ = 1u << 22;            // staging: 4 MB of the 16 MB at PA 0x1e000000
static const uint32_t STG = 0x1e000000u;
static uint8_t mem[MEMSZ];
static uint8_t stg[STGSZ];
static const uint32_t IDX = 0x40, TXCQ = 0x1000, RXSQ = 0x2000, TXS = 0x100000, RXS = 0x180000;
static const uint32_t BC_ROWN = 0x4000u, BC_ETXD = 0x8000u, BC_EOX = 0x80000000u, BC_EOXP = 0x40000000u;
static const uint8_t GUARD = 0xa5;

static uint8_t *at(uint32_t pa) { return (pa >= STG) ? &stg[(pa - STG) & (STGSZ - 1)] : &mem[pa & (MEMSZ - 1)]; }
static void put_be32(uint32_t pa, uint32_t v) { uint8_t *p = at(pa); p[0]=v>>24; p[1]=v>>16; p[2]=v>>8; p[3]=v; }
static uint32_t get_be32(uint32_t pa) { uint8_t *p = at(pa); return ((uint32_t)p[0]<<24)|((uint32_t)p[1]<<16)|((uint32_t)p[2]<<8)|p[3]; }
static void put_le32(uint32_t pa, uint32_t v) { uint8_t *p = at(pa); p[0]=v; p[1]=v>>8; p[2]=v>>16; p[3]=v>>24; }
static uint32_t get_le32(uint32_t pa) { uint8_t *p = at(pa); return (uint32_t)p[0]|((uint32_t)p[1]<<8)|((uint32_t)p[2]<<16)|((uint32_t)p[3]<<24); }
static inline uint8_t pat(uint32_t seed, uint32_t k) { return (uint8_t)(k * 7 + seed * 13 + 1); }

static Venet_ring_dma *d;
static long cyc = 0;
static int64_t reply = -1, resp_cyc = -100;
static uint32_t req_addr = 0, req_op = 0, req_mask = 0, req_sd[4];
static const int LAT = 4;
static int n_tx_done = 0, n_rx_done = 0, n_rx_drop = 0;
/* ordering probes: last load cycle per line, first ETXD (byte-6) store cycle per line */
static std::map<uint32_t, long> g_last_load, g_etxd_store;
static std::map<uint32_t, int>  g_crbdp_seen;      /* every TX CRBDP value exposed */
static uint32_t watch_addr = 0xffffffff, watch_hits = 0;   // count loads of one address

static void step() {
  d->dma_rsp_valid = 0;
  if(reply == cyc) {
    uint32_t line = req_addr & ~15u;
    if(req_op == 4) {
      g_last_load[line] = cyc;
    }
    else if(req_mask == 0x0040 && !g_etxd_store.count(line)) {
      g_etxd_store[line] = cyc;
    }
    if(req_op == 4) {
      for(int i = 0; i < 4; i++) { d->dma_rsp_load_data[i] = get_le32(line + 4*i); }
      if(line == (watch_addr & ~15u)) { watch_hits++; }
    }
    else {
      for(int i = 0; i < 16; i++) {
        if((req_mask >> i) & 1) { *at(line + i) = (req_sd[i>>2] >> (8*(i&3))) & 0xff; }
      }
    }
    d->dma_rsp_valid = 1; reply = -1; resp_cyc = cyc;
  }
  d->clk = 0; d->eval();
  /* one access at a time, held until the response; a 1-cycle gap after each reply */
  if(d->dma_req_valid && reply < 0 && cyc > resp_cyc) {
    req_addr = (uint32_t)d->dma_req_addr; req_op = d->dma_req_opcode; req_mask = d->dma_req_mask;
    for(int i = 0; i < 4; i++) { req_sd[i] = d->dma_req_store_data[i]; }
    reply = cyc + LAT;
  }
  d->clk = 1; d->eval();
  if(d->tx_done) { n_tx_done++; }
  g_crbdp_seen[d->tx_crbdp]++;
  if(d->rx_done) { n_rx_done++; d->rx_nbdp = d->rx_next_nbdp; }
  if(d->rx_dropped) { n_rx_drop++; }
  d->tx_go = 0;
  cyc++;
}

/* ARM side: stage one RX frame, ring the rx_prod doorbell */
static uint32_t arm_rx_prod = 0;
static void arm_rx_submit(const std::vector<uint8_t> &f) {
  uint32_t slot = arm_rx_prod % 256;
  for(size_t k = 0; k < f.size(); k++) { stg[RXS + slot*2048 + k] = f[k]; }
  memset(&stg[RXSQ + slot*16], 0, 16);
  put_le32(STG + RXSQ + slot*16, (uint32_t)f.size());
  arm_rx_prod++;
  d->rx_prod = arm_rx_prod;
}

static int wait_for(int *ctr, int before, int lim = 400000) {
  for(int g = 0; g < lim; g++) {
    if(*ctr != before) { return 1; }
    step();
  }
  return 0;
}

int main(int argc, char **argv) {
  Verilated::commandArgs(argc, argv);
  d = new Venet_ring_dma;
  d->reset = 1; d->clk = 0; d->tx_go = 0; d->rx_armed = 0; d->tx_cons = 0; d->rx_prod = 0; d->eval();
  for(int i = 0; i < 4; i++) { step(); }
  d->reset = 0;
  int fails = 0, checks = 0;
  auto check = [&](bool ok, const char *what, int a, int b) {
    checks++;
    if(!ok) { fails++; printf("  FAIL %s (%d, %d)\n", what, a, b); }
  };

  /* ---- RX: every BP offset x lengths, guard bytes, BC bytes 4-5 untouched ---- */
  const uint32_t lens[] = {3, 15, 16, 17, 61, 310, 1517};
  const uint32_t BUFSZ = 1600;
  uint32_t seed = 0;
  d->rx_armed = 1;
  for(uint32_t off = 0; off < 16; off++) {
    for(uint32_t len : lens) {
      seed++;
      memset(mem, GUARD, sizeof(mem));
      uint32_t bp = 0x4000 + off;
      put_be32(0x1000, bp); put_be32(0x1004, BC_ROWN | 0x20000000u | 0x01000000u | BUFSZ); put_be32(0x1008, 0x1010);
      d->rx_nbdp = 0x1000;
      std::vector<uint8_t> f(len);
      for(uint32_t k = 0; k < len; k++) { f[k] = pat(seed, k); }
      int before = n_rx_done;
      arm_rx_submit(f);
      check(wait_for(&n_rx_done, before) == 1, "RX no rx_done", off, len);
      for(int k = 0; k < 20; k++) { step(); }        /* let R_IDX publish */
      bool data = true, guard = true;
      for(uint32_t k = 0; k < len; k++) { data &= mem[bp + k] == f[k]; }
      for(uint32_t a = 0x3f00; a < bp; a++) { guard &= mem[a] == GUARD; }
      for(uint32_t a = bp + len; a < bp + BUFSZ + 64; a++) { guard &= mem[a] == GUARD; }
      check(data, "RX data mismatch", off, len);
      check(guard, "RX wrote outside the frame", off, len);
      uint32_t bc = get_be32(0x1004);
      check(!(bc & BC_ROWN) && (bc & 0x3fff) == BUFSZ - len, "RX bad BC writeback", off, len);
      check((bc >> 16) == 0x2100, "RX BC bytes 4-5 touched", off, (int)(bc >> 16));
      check(get_le32(STG + IDX + 4) == arm_rx_prod, "RX rx_cons not published", off, (int)get_le32(STG + IDX + 4));
      check(d->rx_crbdp == 0x1000, "RX crbdp", off, (int)d->rx_crbdp);
    }
  }
  printf("RX offsets x lengths: %d checks, %d failures\n", checks, fails);

  /* ---- RX drop: ROWN=0 -> dropped, buffer untouched, cons + drops advance ---- */
  memset(mem, GUARD, sizeof(mem));
  put_be32(0x1000, 0x4008); put_be32(0x1004, BUFSZ); put_be32(0x1008, 0x1010);
  d->rx_nbdp = 0x1000;
  std::vector<uint8_t> f1(100);
  for(uint32_t k = 0; k < 100; k++) { f1[k] = pat(901, k); }
  int dr0 = n_rx_drop;
  arm_rx_submit(f1);
  check(wait_for(&n_rx_drop, dr0) == 1, "RX drop: no rx_dropped", 0, 0);
  bool untouched = true;
  for(uint32_t a = 0x4000; a < 0x4100; a++) { untouched &= mem[a] == GUARD; }
  check(untouched, "RX drop: buffer written", 0, 0);
  check(get_le32(STG + IDX + 8) == 1, "RX drop: drops not published", (int)get_le32(STG + IDX + 8), 0);
  check(get_le32(STG + IDX + 4) == arm_rx_prod, "RX drop: cons not advanced", 0, 0);

  /* ---- TX: 3 packets in one chain; pkt A = 2 descs (offsets 2, 8), B = 1, C = 1 + EOX.
   *      The "guest" flips a bit in desc0's BC byte 4 after the engine read it: the
   *      ETXD write-back must not undo it. ---- */
  memset(mem, 0, sizeof(mem));
  memset(stg, 0, sizeof(stg));
  struct { uint32_t bp, cnt, flags; } td[4] = {
    {0x6002, 100, 0}, {0x7008, 150, BC_EOXP}, {0x8000, 60, BC_EOXP}, {0x9005, 333, BC_EOXP | BC_EOX}};
  std::vector<uint8_t> want[3];
  for(int i = 0; i < 4; i++) {
    uint32_t a = 0x1100 + 16*i;
    put_be32(a, td[i].bp); put_be32(a + 4, td[i].cnt | td[i].flags); put_be32(a + 8, a + 16);
    for(uint32_t k = 0; k < td[i].cnt; k++) {
      mem[td[i].bp + k] = pat(950 + i, k);
      want[i == 0 ? 0 : i - 1].push_back(pat(950 + i, k));
    }
  }
  d->tx_cons = 0;
  g_last_load.clear(); g_etxd_store.clear(); g_crbdp_seen.clear();
  watch_addr = 0x1100; watch_hits = 0;
  int td0 = n_tx_done;
  d->tx_nbdp = 0x1100; d->tx_go = 1;
  bool flipped = false;
  for(int g = 0; g < 400000 && n_tx_done == td0; g++) {
    step();
    if(!flipped && watch_hits > 0) { mem[0x1104] ^= 0x01; flipped = true; }   /* guest edits byte 4 */
  }
  check(n_tx_done != td0, "TX no tx_done", 0, 0);
  for(int k = 0; k < 20; k++) { step(); }
  check(get_le32(STG + IDX) == 3, "TX tx_prod", (int)get_le32(STG + IDX), 3);
  for(int p = 0; p < 3; p++) {
    uint32_t e = TXCQ + 16*p;
    uint32_t len = get_le32(STG + e) & 0xffff;
    check(len == want[p].size(), "TX packet len", p, (int)len);
    bool same = true;
    for(uint32_t k = 0; k < want[p].size(); k++) { same &= stg[TXS + p*2048 + k] == want[p][k]; }
    check(same, "TX packet bytes", p, 0);
  }
  for(int i = 0; i < 4; i++) {
    check(get_be32(0x1104 + 16*i) & BC_ETXD, "TX ETXD not set", i, 0);
  }
  check((mem[0x1104] & 0x01) == ((0x00 ^ 0x01) & 0x01) && flipped, "TX clobbered guest byte 4", mem[0x1104], 0);
  check(get_be32(0x1134) & BC_EOX, "TX EOX lost on last desc", 0, 0);
  check(d->tx_crbdp == 0x1140, "TX crbdp at done", (int)d->tx_crbdp, 0x1140);
  /* IRIX reclaims a packet when its HEAD shows ETXD: that must come after the packet's
   * last descriptor was read (packet A = 0x1100 + 0x1110) */
  check(g_etxd_store.count(0x1100) && g_etxd_store[0x1100] > g_last_load[0x1110],
        "TX head ETXD before the packet's last descriptor was read", (int)g_etxd_store[0x1100], (int)g_last_load[0x1110]);
  /* IRIX's clean_xd_chain reclaims whole packets before CRBDP: CRBDP must never point
   * inside a packet (0x1110 is packet A's second descriptor) */
  check(!g_crbdp_seen.count(0x1110), "TX CRBDP exposed a mid-packet descriptor", g_crbdp_seen.count(0x1110) ? g_crbdp_seen[0x1110] : 0, 0);

  /* ---- TX backpressure: 1 free slot -> 1 packet, then wait; release -> rest ---- */
  memset(stg, 0, TXCQ + 4096);
  for(int i = 0; i < 4; i++) { put_be32(0x1104 + 16*i, td[i].cnt | td[i].flags); }
  d->tx_cons = 3 + 1 - 256;                    /* prod = 3: 255 in flight, 1 free */
  td0 = n_tx_done;
  d->tx_nbdp = 0x1100; d->tx_go = 1;
  for(int g = 0; g < 20000; g++) { step(); }
  check(n_tx_done == td0 && get_le32(STG + IDX) == 4, "TX backpressure: posted past the free slots", (int)get_le32(STG + IDX), 4);
  d->tx_cons = 4;
  check(wait_for(&n_tx_done, td0) == 1, "TX backpressure: never resumed", 0, 0);
  for(int k = 0; k < 20; k++) { step(); }
  check(get_le32(STG + IDX) == 6, "TX backpressure: tx_prod", (int)get_le32(STG + IDX), 6);

  /* ---- RX and TX together: both complete, both correct ---- */
  memset(mem + 0x4000, GUARD, 0x1000);
  put_be32(0x1000, 0x4004); put_be32(0x1004, BC_ROWN | BUFSZ); put_be32(0x1008, 0x1010);
  d->rx_nbdp = 0x1000;
  for(int i = 0; i < 4; i++) { put_be32(0x1104 + 16*i, td[i].cnt | td[i].flags); }
  d->tx_cons = 6;
  std::vector<uint8_t> f2(777);
  for(uint32_t k = 0; k < 777; k++) { f2[k] = pat(990, k); }
  int rd0 = n_rx_done; td0 = n_tx_done;
  arm_rx_submit(f2);
  d->tx_nbdp = 0x1100; d->tx_go = 1;
  for(int g = 0; g < 400000 && (n_rx_done == rd0 || n_tx_done == td0); g++) { step(); }
  check(n_rx_done != rd0 && n_tx_done != td0, "RX+TX: both done", n_rx_done - rd0, n_tx_done - td0);
  bool ok5 = true;
  for(uint32_t k = 0; k < 777; k++) { ok5 &= mem[0x4004 + k] == f2[k]; }
  check(ok5, "RX+TX: RX data", 0, 0);
  for(int k = 0; k < 20; k++) { step(); }
  check(get_le32(STG + IDX) == 9, "RX+TX: tx_prod", (int)get_le32(STG + IDX), 9);

  /* ---- TX oversize: one 2100-byte packet -> 2048 bytes + truncated flag ---- */
  for(uint32_t k = 0; k < 2100; k++) { mem[0x20000 + k] = pat(77, k); }
  put_be32(0x1200, 0x20000); put_be32(0x1204, 2100 | BC_EOXP | BC_EOX); put_be32(0x1208, 0x1210);
  d->tx_cons = 9;
  td0 = n_tx_done;
  d->tx_nbdp = 0x1200; d->tx_go = 1;
  check(wait_for(&n_tx_done, td0) == 1, "TX oversize: no done", 0, 0);
  for(int k = 0; k < 20; k++) { step(); }
  uint32_t e9 = get_le32(STG + TXCQ + 16*9);
  check((e9 & 0xffff) == 2100 && (e9 & 0x10000), "TX oversize: len/trunc flag", (int)(e9 & 0xffff), (int)(e9 >> 16));
  bool ok6 = true;
  for(uint32_t k = 0; k < 2048; k++) { ok6 &= stg[TXS + 9*2048 + k] == pat(77, k); }
  check(ok6, "TX oversize: first 2048 bytes", 0, 0);
  check(stg[TXS + 10*2048] == 0, "TX oversize: wrote past its slot", stg[TXS + 10*2048], 0);

  printf("== enet_ring_dma unit test: %d checks, %d failures: %s ==\n", checks, fails, fails ? "FAIL" : "PASS");
  delete d;
  return fails ? 1 : 0;
}
