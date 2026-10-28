---
title: Architecture
status: draft
---

# Henry architecture

Henry is the **r9999** CPU core wired to a re-implementation of the SGI **IP22** chipset, in a memory-mapped
system that boots IRIX. This page is the system-level view; each block has its own spec under
[Peripherals](peripherals/mc.md).

## Blocks & responsibilities

| Block | Role | Spec |
|---|---|---|
| **r9999** | Out-of-order MIPS III CPU core, presents as an **R4400** (`PRId 0x0440`). 32 KB 2-way L1i (not kept coherent with D-side stores) + 16 KB VA-indexed L1d, 128 KB inclusive L2 hidden from software (`Config.SC=1`). | [CPU integration](cpu-integration.md), [microarchitecture](r9999-microarchitecture.md) |
| **MC** | Memory controller: DRAM banks + sizing, the GIO64 bus arbiter, error/refresh/timers, the graphics (V)DMA master. | [MC](peripherals/mc.md) |
| **HPC3** | Peripheral/DMA controller: SCSI ×2, Ethernet, PBUS; the ds1386 RTC/NVRAM and serial EEPROM. | [HPC3](peripherals/hpc3.md), [SCSI disk](peripherals/scsi_disk_theory_of_operation.md) |
| **IOC2** | I/O controller: the **Z8530 serial console**, the INT3 interrupt controller, the 8254 timer, keyboard/mouse, parallel. | [IOC2](peripherals/ioc2.md), [SCC](peripherals/scc.md) |
| **GIO64** | The expansion/graphics bus (16 × 4 MB slots). On Henry the REX3 window is an ARM-served Newport; the rest of the slot space is empty and bus-errors. | [GIO64](peripherals/gio64.md), [Newport on henry](newport-on-henry.md) |
| **VDMA** | The MC's virtual-DMA graphics master (its own page-table walker). Henry implements memory → GIO as a DMA-engine channel. | [VDMA](peripherals/vdma.md) |
| **ARCS shim** | The firmware state Henry plants so `/unix` boots without the real PROM/sash. | [Firmware](firmware-arcs.md) |

## How Henry realizes it (RTL + FPGA)

The real chips are not reproduced one-for-one; `rtl/henry_soc.sv` wraps the r9999 core (`core_l1d_l1i`) and
decodes the core's L2-miss bus (16-byte lines, one request outstanding) into device slaves, passing everything
else through to DRAM:

| Henry module | Implements | Notes |
|---|---|---|
| `mc.sv` | MC registers @ `0x1fa00000` | `MEMCFG0` reset value describes 128 MB @ `0x08000000`; the `henry_arcs` FSBL reprograms it to `0x3f203f40` (2 × 128 MB = 256 MB) before the kernel runs |
| `hpc3.sv` | HPC3 registers @ `0x1fb80000` (minus IOC2) | incl. the ds1386 clock registers @ `+0x60000` (a running 100 Hz BCD clock); the bbRAM at `0x1fbe0040–0x1fbe7fff` is left to DRAM, which the host populates |
| `ioc.sv` | IOC2 @ `0x1fbd9800` | Z8530 SCC console (Tx + Rx FIFO), i8254 |
| `int3.sv` | INT3 interrupt mux (IOC2 `+0x80`) | separate module, instantiated in `henry_soc.sv` |
| `scsi_shim.sv` | WD33C93 + HPC3 SCSI channel | register model; the DMA engine walks the `{BP,BC,DP}` chain and the ARM serves the disk image through the staging rings ([protocol](arm-device-protocol.md)) |
| `enet_shim.sv` | Seeq 8003 + HPC3 ENET | register model; the ENET channels of `dma_engine.sv` walk the descriptor chains and the ARM moves frames through the staging rings ([protocol](arm-device-protocol.md)) |
| `dma_engine.sv` | the SoC's one DMA engine | channels SCSI, ENET TX, ENET RX and MC VDMA (`CH_V`), behind one `dma_snoop_shim` so guest-memory accesses are coherent with the L1/L2 |
| `gio_window.sv` | ARM-served GIO window | REX3 @ `0x1f0f0000` and the IOC2 8042: accesses (and VDMA data) become records in a staging-region ring that the ARM's device models consume ([Newport on henry](newport-on-henry.md)) |
| `mem_arbiter.sv` | DRAM arbitration | two instances, one per AXI lane (two AXI IDs, concurrent): lane 0 is the CPU alone; lane 1 is a weighted round-robin of the DMA engine (2 slots) and the GIO window ring / MC fill (1 slot), with 64 B bursts. Each lane has one request outstanding |
| `ip_hdl/axi_is_the_worst_*.v` | AXI4 master to PS DRAM + AXI-Lite control/debug registers | packaged as the Vivado user IP |

The IP22 512 KB **System Memory Alias** (physical `0x0–0x7ffff` → `0x08000000`) is applied in `henry_soc.sv`
to CPU accesses before arbitration, as is the PROM's memory-bank probe window at `0x20000000` (banks 0/1 reach
their DRAM; empty banks read 0). In `0x1f000000–0x1fffffff`, the REX3 window and the 8042 go to `gio_window`, and
the rest of GIO space is decided "empty" by the MC (a bus error with `CPUCTRL1.ABORT_EN`, see
[Bus errors](bus-errors.md)). Other addresses fall through to the AXI master, which maps a 16 MB window into shared
DRAM. The boot-PROM range is DRAM-backed this way: the host (`henry_tb` in sim, the ARM driver on the FPGA) loads the ARCS first-stage
image (`henry_arcs.bin`) there and starts the core at the reset vector `0xbfc00000`.

## Buses & topology

- **sysad** — the 64-bit, **big-endian** processor bus between r9999 and the MC. The big-endianness has a
  concrete consequence: 32-bit MC registers sit on the low 32 data lines, so a big-endian CPU reads each
  register at its **`+4`/`+c`** byte alias (see [MC](peripherals/mc.md)).
- **GIO64** (`0x1f000000–0x1f9fffff`) — the expansion/graphics bus, mastered by the CPU (through the MC
  arbiter), by graphics, and by long-burst DMA. Sixteen 4 MB slots; IP22 wires only graphics + two expansion
  slots, and an access to an unpopulated slot returns a **bus error** — which is exactly how IRIX's GIO probe
  decides "no device." Henry models this: the MC returns the error with the response and r9999 takes a
  precise data bus error ([Bus errors](bus-errors.md)). Slot 0 holds an ARM-served Newport
  ([Newport on henry](newport-on-henry.md)).
- **Local I/O** (`0x1fb80000+`) — HPC3 + IOC2 + the boot PROM. HPC3 bridges GIO64 to the peripherals and the
  PBUS (where the RTC/NVRAM, EEPROM, audio, and parallel live).

## Memory-mapped layout

See the [canonical address map](index.md#canonical-physical-address-map-ip22-henry). The essentials:

- **DRAM** at physical `0x08000000` (sized from the MC `MEMCFG` registers, *not* via firmware), aliased into
  the bottom 512 KB so the exception vectors at `0x0`/`0x80` are real RAM. IP22 physical addresses are
  **30-bit** (a high-memory window exists at `0x20000000`); Henry's 256 MB configuration (`0x08000000–0x17ffffff`) only exercises ~29
  bits. (The r9999 core itself carries 36-bit physical addresses.)
- **Device space** at `0x1f000000+`: GIO64, then the MC registers (`0x1fa00000`), then HPC3/IOC2
  (`0x1fb80000`), then the boot PROM (`0x1fc00000`).

## DMA & coherence (the architecturally load-bearing part)

There are two DMA masters — **HPC3** (SCSI/Ethernet/PBUS, the real system I/O path) and the MC's **VDMA**
(graphics). **Neither snoops the CPU caches** on a uniprocessor R4000, and HPC3 DMA uses **raw physical
addresses** (no IOMMU). Combined with r9999's **incoherent L1i**, this means Henry's correctness depends on
software cache management: the IRIX `cache` instruction is **not** a NOP, and r9999 must honor specific
ops (I-cache invalidate for code coherence; D-cache invalidate-*without*-writeback for DMA-in). This is the
single most important cross-block contract — see [Cache, coherence & TLB](coherence-cache-tlb.md).

**How Henry keeps DMA coherent (current).** All device DMA (SCSI, Ethernet, VDMA) goes through `dma_engine.sv`,
whose guest-memory accesses pass a `dma_snoop_shim` (write back + invalidate the line in the core's caches through
the inclusive L2's snoop port, access DRAM, and snoop again after a write). The ARM exchanges data with the engine through staging rings and never touches guest memory after
boot, so no flushes are needed ([ARM device protocol](arm-device-protocol.md)).

**Earlier (flush-based) builds.** Before the snooped engine, the SCSI and Ethernet "DMA" was done by the **ARM** writing and
reading guest buffers in the shared DRAM, below the r9999 caches. IRIX's own `cache` ops are honored (see
[CPU integration](cpu-integration.md)),
but they are not sufficient on their own, so the ARM driver also asks the core to flush around each transfer:

- **whole-cache flush** — an AXI control bit drives the core's `ext_flush_req`; the core injects a serializing
  `XFLUSH` op (whole L1D written back + invalidated, L2 chained) and restarts;
- **page-list flush** — the ARM pushes up to 16 physical page numbers and fires `go`; the SoC sequencer issues one
  injected `XPG_WBINV` (before a transfer) or `XPG_INV` (after a deposit) page op per page, and a 17th page
  falls back to the whole-cache flush.

Every L1D flush (CACHE op, page op, whole flush, DMA invalidate) starts only once the L1D is fully drained
(`w_l1d_drained` in `r9999/l1d.sv`). In those builds the DMA→L2 snoop FIFO (`snoop_fifo.sv`) was opt-in and
inert (the core tied its L2 snoop port off). It is no longer instantiated: the core's snoop port now belongs to
`dma_snoop_shim`. The injected-flush hardware (`ext_flush_*` in `henry_soc.sv`) is still wired, but the
staging-ring driver does not need it. Details and silicon history are in
[Cache, coherence & TLB](coherence-cache-tlb.md).

## Interrupts

Peripheral interrupt sources (HPC3 DMA-done/error, GIO64 device lines, the 8254 timers) aggregate in the
**INT3** controller inside IOC2, which drives five `CPU_INT_N` lines into r9999's CP0 `Cause.IP[6:2]`. The CPU's
own periodic tick is the on-chip **CP0 Count/Compare** timer, not a peripheral. See [IOC2](peripherals/ioc2.md).
In Henry (`int3.sv`, wired in `henry_soc.sv`) the live sources are SCSI0 (Local0 bit 1), ENET (Local0 bit 3) and
MC DMA completion (Local0 bit 4) → IP2; the ARM-driven Local1 lines (bit 7 = Newport VRETRACE) → IP3; the SCC
Rx/Tx (Serial DUART mappable bit 5) and the ARM-served 8042 (mappable bit 4) via the map mask; i8254 counter 0
(Timer0 → IP4); and the MC bus-error line. Timer1 is tied off.

## Build/verify strategy

The spec is the contract; **MAME is the oracle** for the platform, and the in-sim ISS lock-step checker
(`henry_tb`) is the oracle for the CPU. Each block is implemented against its register spec and the
golden vectors captured from MAME (e.g. `MEMCFG0=0x23200000`, the SPB bytes, the wired-PDA TLB entry, the SCC
TX stream), then co-simulated/diffed against MAME booting the same IRIX image. See [Methodology](methodology.md).
