# ARM ↔ device protocol (staging rings)

Status: IMPLEMENTED, and the only device path (2026-10-14). Replaces the host-served /
beat-FIFO protocol for ENET and SCSI now that device DMA is snooped. The rings are not
build options. Since henry `d1c39b9` (2026-10-17) one `dma_engine` (`rtl/dma_engine.sv`)
serves SCSI, ENET TX and ENET RX as channels behind a single `dma_snoop_shim`; it replaced
`scsi_dma` + `scsi_stage` and `enet_ring_dma`, which stay in `rtl/` only as the unit tests'
reference implementation. The rings first shipped at RTL revision (AXI-Lite read `0x3F`)
`0x20261014`; the current revision is `0x20261018`.

## Why

Before the rings, the device engines (`scsi_dma`, `enet_dma`) already reached guest memory through
`dma_snoop_shim`, so their accesses were coherent with the L1/L2 by construction. The
problems were all in the split between the engines and the ARM:

| Before the rings | What it cost (2026-10-13 silicon) |
|---|---|
| The ARM reads guest descriptors from DRAM (SCSI read sizing, ENET packet boundaries, TX CRBDP) | appended-chain overrun of the reap bound; SCSI sizing is not snoop-coherent |
| Data crosses as 16 B beats over AXI-Lite (~5 register ops per beat), 16-deep FIFOs | slow TX service (ring fills, IRIX drops: `Oerrs`); FIFO overflow; >16 KB / >64 KB chain truncation |
| One engine FSM serves RX and TX and blocks on the ARM in both directions | RX/TX deadlock |
| Guest-visible state split between engine (BC write-back) and ARM (CRBDP, completion echo) | stale-BC write-back clobbering IRIX's EOX clear; wrong reap bounds |
| Pulse → sticky bits, shared read-to-clear status, 14-bit lengths | assorted workarounds |

## Invariants

1. **After boot the ARM never reads or writes guest memory.** Guest memory is touched
   only by the r9999 core and by device engines through `dma_snoop_shim`, so coherence
   is snoop-only. No `EXTFLUSH`, no host-served paths. (Boot-time image loading,
   before the core runs, is the only exception. Separately, the MC's FILL engine for the
   PROM's power-on memory clear writes guest memory unsnooped; `mc.sv:64-69`.)
2. **Engines own everything the guest can observe.** That covers the descriptor walk
   (including EOXP packet splitting), BC write-back, CRBDP, ACTIVE/IRQ and SCSI status
   delivery. The ARM owns only the media: the tap and the disk image.
3. **The ARM and the engines exchange data only through staging memory**, using
   producer/consumer rings, and never wait on each other mid-transfer. An engine starts
   a packet or block only when the staging slot it needs is available.

## Block diagram

```
+------------------------- Zynq PS (A53) --------------------------+
|  mips-axi:   ENET servicer (tap0)      SCSI servicer (disk.img)   |
+-------+-------------------------------------------+---------------+
        | AXI-Lite: ring indices                    | uncached mmap
        |                                           v
        |                  +------------------ PS DDR, 496 MB window --+
        |                  | guest RAM 256 MB | PROM 16 MB | STAGING   |
        |                  | (guest PAs)      |            | 16 MB     |
        |                  +--------^---------+------------+----^------+
        |                           | M00_AXI (all PL DRAM traffic) |
+-------v---------------------------+-------------------------------+-------+
| PL                                |                               |       |
|   +---------------+      +--------+-------------------------------+--+    |
|   | S00_AXI regs  |      |                mem_arbiter                |    |
|   | prod/cons idx |      +---^-------------------------------------^--+    |
|   +-------+-------+          |                                     |       |
|           |            +----+---------+                     +-----+-----+ |
|           |            | dma_snoop_   |----- snoop port ---->| r9999     | |
|           |            | shim         |                     | core+L1+L2| |
|           |            +----^---------+                     +-----------+ |
|           |                 |                                             |
|           v                 |                                             |
|   +---------------+   +-----+------------------------------+              |
|   | scsi_shim     |---| dma_engine: SCSI, ENET TX, ENET RX |              |
|   | enet_shim     |---| (+ MC VDMA) channels               |              |
|   +---------------+   +------------------------------------+              |
|                         staging side: PA 0x1E000000+, passes the shim    |
|                         unsnooped (the core never caches that range)     |
+---------------------------------------------------------------------------+
```

Data path in one line per direction:

```
ENET TX : guest chain --snoop--> TX channel --> TX slot --(index)--> ARM --> tap0
ENET RX : tap0 --> ARM --> RX slot --(index)--> RX channel --snoop--> guest ring
SCSI W  : guest chain --snoop--> SCSI channel --> buffer --(cmd entry)--> ARM --> disk
SCSI R  : disk --> ARM --> buffer --(rsp entry)--> SCSI channel --snoop--> guest chain
```

Each channel has two kinds of access, both through the engine's one memory port and
`mem_arbiter`. **Guest side** accesses go through `dma_snoop_shim`: PRE-WBINV, then the
access, then POST-WBINV for writes. **Host side** accesses target staging PAs, which the
shim passes straight through (`dma_snoop_shim.sv:76-79`). That is safe because the core can never cache PA 0x1e000000–0x1effffff: it is
reserved on IP22, and `henry_soc` decodes CPU accesses to 0x18000000–0x1effffff as
no memory (`w_is_nomap`: an uncached load bus-errors, an uncached store is absorbed, and cached
traffic reads zeros or is dropped), so the core cannot
reach the staging area at all.

**Placement.** The kmod reserves `REGION_SZ = 496 MB`, so window offsets end at
0x1effffff. `M00_AXI` folds guest RAM (PA 0x08000000–0x17ffffff) to offsets
0–0x0fffffff, and PA 0x1f000000+ to 0x10000000+. Every other PA, including the reserved
GIO space 0x18000000–0x1effffff, maps one-to-one. Staging takes the top 16 MB. The
retired DRAM deep trace (`ENABLE_DRAM_TRACE`, off by default and no longer needed) used
this whole region as its ring, so it must never be enabled together with the rings.

## Staging memory map (window offset == device PA)

| Offset | Size | Contents |
|---|---|---|
| `0x1e000000` | 64 B | control block: magic and version (ARM-written) |
| `0x1e000040` | 16 B | PL-owned indices: `tx_prod`, `rx_cons`, `rx_drops`, reserved |
| `0x1e000050` | 16 B | PL-owned SCSI index: `scsi_cq_prod`, reserved |
| `0x1e000060` | 16 B | GIO-window ring producer index (`gio_window`, see [Newport on henry](newport-on-henry.md)) |
| `0x1e001000` | 4 KB | ENET TX completion ring: 256 × 16 B |
| `0x1e002000` | 4 KB | ENET RX submit ring: 256 × 16 B |
| `0x1e003000` | 1 KB | SCSI completion ring (PL→ARM): 64 × 16 B `{bytes, chain head, flags, req_seq}` |
| `0x1e100000` | 512 KB | ENET TX slots: 256 × 2 KB (slot *i* belongs to TX ring entry *i*) |
| `0x1e180000` | 512 KB | ENET RX slots: 256 × 2 KB (slot *i* belongs to RX ring entry *i*) |
| `0x1e200000` | | GIO-window capture ring (`gio_window.sv` `RING_PA`; Newport, 8042, VDMA records) |
| `0x1e400000` | 1 MB | `ENET_RING_TRACE` TX descriptor log, 64K × 16 B (debug option) |
| `0x1e800000` | 4 MB | SCSI READ data (ARM→device), restaged per chain |
| `0x1ec00000` | 4 MB | SCSI WRITE data (device→ARM), regathered per chain |

Entries are little-endian 32-bit words, the ARM's native order. Engines byte-swap only
guest-side descriptor words, as they already do.

## Ring mechanics

- Each ring has a **producer index** and a **consumer index**, both free-running 32-bit
  counters. Entry = `index % N`. Full when `prod - cons == N`, empty when equal.
- **ARM-owned indices are doorbells.** They are write-only S00_AXI registers, and the
  write carries the new index value:

  | Write reg | Index | Ring |
  |---|---|---|
  | `0x18` (`slv_reg24`) | `tx_cons` | ENET TX completions consumed |
  | `0x19` (`slv_reg25`) | `rx_prod` | ENET RX frames submitted |
  | `0x1a` (`slv_reg26`) | `scsi_cq_cons` | SCSI completions consumed |
  | `0x1b` (`slv_reg27`) | `scsi_rd_beats` | beats staged for the next SCSI READ chain |
  | `0x1c` (`slv_reg28`) | `scsi_rd_seq` | which command those beats belong to (written after `0x1b`) |

  They drive `dma_engine`'s doorbell inputs (`axi_is_the_worst_v1_0_S00_AXI.v:477-481`).
  The read side of each address keeps its own debug value.
- **PL-owned indices live in staging memory**, in the control block. The engines write
  `tx_prod`, `rx_cons`, the RX drop count and `scsi_cq_prod` there after the payload. The ARM polls them with uncached loads, so no read-mux entries are needed.
  This is the NVMe/virtio arrangement: the device writes completions to memory, the
  host rings doorbells.
- **Ordering rule: payload, then entry, then index.**
  - ARM: write the slot and the entry (uncached), `dsb st`, then the doorbell.
  - PL: the engine has one outstanding DRAM request, and the next request issues only
    after the previous response. Index stores therefore follow the payload stores they
    cover.
- No valid bits and no read-to-clear status. Counters only increase, so a missed poll
  loses nothing.

## ENET

### TX (guest → wire)
1. The guest writes the TX chain and sets `ctrl = ACTIVE`. `enet_shim` kicks the
   engine's TX channel.
2. The engine walks the chain through the snoop shim. For each **packet** (descriptors
   up to and including EOXP):
   1. Wait for a free TX slot (`prod - cons < 256`). This is the only stall, and it is
      on the ARM's consumer index, never mid-packet.
   2. Gather the packet into the slot, in byte order, from any BP offset (the existing
      packer).
   3. Write BC back with **byte 6 only** (ETXD). Never touch the EOX/EOXP/XIE byte, so
      IRIX's concurrent "clear EOX on the old tail" survives. The packet's **head**
      descriptor gets its ETXD last, after the packet's final descriptor is gathered:
      IRIX reads the head's ETXD as "whole packet sent".
   4. Write the completion entry `{len, guest_desc_of_first, flags}`, then bump `tx_prod`.
   5. Keep the shim's **live TX CRBDP** at the in-flight packet's head, and move it to the
      next descriptor at chain end. IRIX's `clean_xd_chain` reclaims every whole packet
      whose head lies before CRBDP, so a CRBDP inside a packet truncates it
      (`dma_engine.sv` header).
3. At EOX, or a null link, or 255 descriptors, the engine tells `enet_shim` the chain is
   done. The shim clears ACTIVE and raises the TX IRQ itself, with **no ARM echo**.
4. ARM: while `tx_cons != tx_prod`, write slot data to `tap0`, then `tx_cons++`. A full
   tap queue drops the frame (as real Ethernet would) and still frees the slot.

TX throughput no longer depends on ARM latency, except through the 256-packet slot
pool. IRIX's ring drains at engine speed.

### RX (wire → guest)
1. ARM: for each tap frame passing the address filter, wait for a free RX entry, write
   `[2 pad][frame][status]` into the slot, write the entry `{len}`, `dsb st`, then
   `rx_prod++`.
2. The RX channel, while `rx_cons != rx_prod` **and** the guest RX ring is armed:
   1. Read the guest descriptor through the snoop shim. If ROWN=0 (ring full), drop the
      frame: `rx_cons++` and increment the drop counter, as real HPC3 does. A buffer too
      small for `[2 pad][frame][status]` also drops the frame.
   2. Otherwise copy the slot to BP, at any offset, masked to `[BP, BP+len)`.
   3. Write BC back with **bytes 6–7 only** (ROWN clear, residual count).
   4. Update the live RX CRBDP, raise the RX IRQ through the shim, then `rx_cons++`.
3. RX and TX are **separate channels** of `dma_engine`, taking turns on its one memory
   port (round robin per access). Neither waits on the other or on the ARM mid-frame:
   TX waits for a free slot only before it opens a packet, and RX starts only when a
   whole frame is already staged.

## SCSI

The WD33C93/HPC3 register model stays in `scsi_shim`, and so does the per-command
**mailbox** (CDB, nbdp and direction read over AXI-Lite; status and residual written
back). It runs once per command and never touches guest memory, so turning it into a
ring buys nothing. What changes is the data path and the chain bookkeeping. The
engine's SCSI channel walks the HPC3 chain and moves the data between guest memory and
staging. (In the first ring build this was `scsi_dma` plus `rtl/scsi_stage.sv`, which
served its 16 B disk-beat port from staging; `dma_engine` replaced both.)

Each SELECT-AND-TRANSFER (a new command or a resume) is one *chain* with its own
`req_seq` from the shim. The `req_seq` pairs everything exactly:

1. **READ (disk → mem).** The ARM stages the request's remaining bytes (up to 4 MB) at
   `0x1e800000`, rings `scsi_rd_beats`, then `scsi_rd_seq = req_seq`. The engine
   accepts the count only when that seq matches the chain it is running. Leftovers
   from an older command can never feed a new chain, whether the doorbell lands
   before or after `go`. The engine takes what the chain needs. **The ARM never sizes
   the chain.**
2. **WRITE (mem → disk).** The engine gathers the chain through the snoop shim and
   stores the beats at `0x1ec00000` (past 4 MB they are dropped and the completion is
   flagged truncated).
3. **Completion.** Every chain posts one entry `{bytes, chain head, flags, req_seq}`
   and bumps `scsi_cq_prod`. The flags are:
   - `done`;
   - `starved`: a READ chain wanted more than was staged, i.e. a short transfer. The
     ARM posts the status, and the shim then cancels the engine.
   - `aborted`: the shim cancelled first.

   WRITE completions post only after the last beat has reached staging.
4. **The ARM** waits for the entry whose seq is its request's, skipping others. A
   no-data command can still run the engine, and nobody waits for that entry. The
   ARM then sets `moved = bytes`, and for a WRITE copies `bytes` from staging and
   writes the disk. Pause/resume (`g_pos`) and status are exactly as before.

A read-ahead still in flight when a new chain starts is dropped by a chain tag. The
protocol makes that timing impossible, because the next `go` needs the ARM's status,
and that waits for the completion. The tag is defensive and has its own unit test.

## Moved from ARM to RTL

- ENET: the EOXP split; live TX and RX CRBDP; ACTIVE/IRQ on completion; BC write-back
  byte masks (TX byte 6, RX bytes 6–7); RX drop on ROWN=0.
- SCSI: chain sizing (the ARM's `scsi_chain_bytes`), the per-chain byte count, and WRITE
  data capture (the ARM's `scsi_move` from guest DRAM).

## Deleted

- Beat FIFOs (`scsi_beat_fifo` instances for ENET RX/TX and SCSI data) and their AXI-Lite
  data registers: writes `0x20–0x23` and `0x2a–0x2f`; reads `0x02`, `0x05`, `0x06` and
  `0x20–0x23`. Bit 0 of `0x24`/`0x25` reads 0 (the ext-flush fields in their upper bits
  are unchanged). Several of these addresses were later reused for the GIO window and
  graphics: writes `0x20–0x23` (GIO answer/consumer), `0x24` (graphics counter select)
  and `0x2a` (GIO IRQ doorbell); reads `0x02` (graphics counter) and `0x20–0x23` (GIO
  window, VDMA counters). Reads `0x05` and `0x06` return 0.
- The ARM completion handshake for ENET: `tx_rsp_seq`, `rx_rsp_seq`, `rx_crbdp` and
  `tx_crbdp` registers (`0x12–0x15`).
- Driver: `EXTFLUSH`, `ENETFLUSH`, `XFPAGES`, the host-served ENET/SCSI paths
  (`enet_service.h` walkers, `scsi_move` into guest memory), `scsi_chain_bytes`, the
  `scsi_idle` hook, and the ARM guest-DRAM accessors (`scsi_arm_mem`, `enet_arm_mem`).

## Verification

1. **Per-engine unit tests**, extending `sim/enet_dma_test`. The DRAM model writes to
   the 16 B-aligned line and has guard bytes. Cases:
   - every BP offset;
   - multi-packet chains, and chains above 64 KB;
   - **the guest clearing EOX mid-walk**, which must survive the BC write-back;
   - ring full and ring empty;
   - RX drop on ROWN=0;
   - SCSI partial transfer and resume.
2. **One servicer for both sim and silicon.** Rewrite `henry_tb`'s device service
   against the ring protocol, using the **same servicer source** as the ARM driver
   (header-only, with a `Driver`-like register interface and a memory pointer). The
   testbench then exercises the exact protocol code the board runs. Before the rings it
   ran different code, and that hid every one of the 2026-10-13 bugs. Done:
   `sim/ring_service.h` is that shared servicer.
3. **Silicon:** the 24-round IRIX soak (telnet bulk plus the `disk3.py` raw-read and
   write worker). Pass means: 0 `Oerrs`, 0 SCSI mismatches, `xflush_hw = 0`, and no
   ARM access to the guest window, asserted by unmapping it in the driver after boot.
   The first ring bit (`0e7de40d`, 2026-10-14) passed a 24-round IRIX soak
   ([FPGA stats](fpga_stats.md)).

## Phasing

Steps 1–4 shipped in henry `a0d5e1e` and `4bc57b4` (the driver half lives in the board
driver, not this repo). Step 5 is not done: the default core still has a 16 KB L1D and a
32 KB L1I.

1. Staging control block, ring index registers, and the ARM servicer skeleton (driver +
   tb shared header).
2. ENET TX engine + ENET RX engine on rings; delete the ENET beat FIFOs and ARM echo.
3. SCSI on rings; delete the SCSI beat FIFO and `scsi_chain_bytes`.
4. Delete all host-served/flush code paths; unmap the guest window after boot.
5. 64K/64K L1 configuration on top (the original step 5).

## Open questions

- Device DRAM traffic doubles: every device byte now crosses the arbiter twice (guest
  side + staging side). Only DEVICE traffic doubles -- core traffic is unchanged, and the
  device share is small (the soak's ENET+SCSI load is a few MB/s against a core that
  misses to DRAM continuously). Expect at most a small rise in core DRAM latency while
  devices are busy; confirm with `memlat` under a disk+net load. Per device byte, DRAM
  is touched 3x (engine guest side, engine staging side, ARM staging side) versus 1x
  for the old beat-FIFO engine path, where the ARM half crosses AXI-Lite instead of
  DRAM. Of those, 2 go through the PL arbiter that the core shares; the ARM's access
  goes through the PS DDR controller directly.
- ~~Whether to give each ENET engine its own snoop shim, or put a 2-master front-end on
  the existing one.~~ Settled by `d1c39b9`: one `dma_engine` for all channels behind one
  shim.
- Whether a PL→PS interrupt is worth it later to replace polling. It is not needed for
  correctness.
