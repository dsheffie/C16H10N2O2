---
title: Methodology — MAME as the golden oracle
status: stable
---

# Methodology — MAME as Henry's golden oracle

Every fact in this spec was derived by driving **real IRIX 6.5.22 booting on the SGI Indy in MAME**, not from
datasheets alone. MAME is Henry's **golden reference model**: it runs the actual PROM + kernel, so it tells us
what IRIX *actually* requires (vs. what's merely architecturally possible), and the values it produces are the
**block-level test vectors** Henry's RTL is checked against. This page is the reproducible recipe.

## The headless harness

- **Run the local instrumentable build:** `~/code/mame/mame` (the system `/usr/games/mame` is *not* the
  checkout). Launch from the IRIX image dir so relative paths + nvram resolve.
- **Headless requires SDL dummy drivers** — without them SDL tries DRM/KMS and dies:
  ```sh
  SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy ~/code/mame/mame indy_4610 \
    -gio64_gfx xl24 -hard1 irix65.chd -rompath indy_4610/ -nodrc \
    -video none -sound none -nothrottle -seconds_to_run N -autoboot_script probe.lua
  ```
  `-nodrc` = the interpreter (instrumentable). The Indy core is `r4600be(:maincpu)` (the legacy `mips3.cpp`),
  which is fine — IRIX's CPU usage is the same at the level we care about.
- **Drive it with Lua (`-autoboot_script`), not the in-tree debugger** — the debugger is unusable headless
  (segfaults / no output). Lua `io.write`/`print` go to stdout; CPU state is `cpu.state["NAME"].value`
  (PC, all GPRs, CP0 EntryHi/Lo/Index/Wired/Count/Compare/Cause, FCR31, FPRs…); MMU-translated memory reads
  are `cpu.spaces["program"]:readv_u32/u8(addr)` (the non-`v` variants read raw and return junk for kseg).

## Exact single-instruction breakpoints (the workhorse)

Lua + the debugger *core* (`-debug -debugger none`) gives precise PC traps without a display:

```lua
local dbg = manager.machine.debugger
cpu.debug:bpset(0x88005960, "1", "")     -- 3 args required; fewer SEGFAULTS the binding
-- in register_periodic: if dbg.execution_state == "stop" then read state; dbg.execution_state = "running"
```

Caveats learned the hard way: `execution_state` reads `"stop"` (not `"stopped"`); the periodic still fires
while paused; poll-resume adds **~16 ms wall per hit**, so never breakpoint high-frequency sites. **Register
reads at a *watchpoint* (mid-instruction) are stale** — use single-step + read PC, or read CP0 (those are
reliable). This is how the wirepda/wired-TLB question was answered.

## C++ instrumentation (for high-volume counts + device capture)

For things Lua can't do at speed — opcode/cache histograms, device-traffic capture — patch the MAME source
and rebuild incrementally (`cd ~/code/mame && make -j$(nproc)`; ~1–2 min relink). Pattern = a file-static
counter/buffer + a hook at the handler + an `fprintf(stderr,…)` dump. Hooks used this session (uncommitted in
the MAME tree):

| File | Hook | Yields |
|---|---|---|
| `src/devices/cpu/mips/mips3.cpp` | counter on `case 0x2f /*CACHE*/` + `case 0x11 /*COP1*/`, dumped in `device_stop()` | the **cache-op histogram** (5.2M ops/boot) and the COP1 histogram |
| `src/mame/sgi/ioc2.cpp` | `scc_dc_w` wrapper on the SCC `ab_dc` write | **serial-console capture** (the `du_putchar` → Z8530 TX stream) |

The serial capture is what proved the console path; `null_modem` + `-bitb` captured **0 bytes** (baud/port
ambiguity), so the C++ SCC hook is the reliable headless serial sink. Getting serial at all also needs
`console=d` in the PROM nvram (`setenv -f console d`, a one-time GUI step).

## How a Henry block gets validated

1. **Spec** the block from the SGI doc (cross-checked, ✅/⚠️-tagged against MAME).
2. **Capture golden vectors** from MAME — the values IRIX reads/writes during boot. Examples already captured:
   `MEMCFG0 = 0x23200000` (→ 16 MB bank @ `0x08000000`); the SPB bytes at phys `0x1000` (sig "ARCS", the
   35-entry romvec addresses); the wired PDA TLB entry (`EntryHi=0xFFFFA000 → 0x0838E000`, global, slot 0,
   Wired=8); the SCC TX byte stream; the FR=1 transitions; the per-boot cache-op histogram.
3. **Implement** the block in `rtl/` against the spec.
4. **Co-simulate / diff** against MAME booting the same IRIX image: same instruction stream, same device
   register reads/writes, same console output. Divergence localizes the bug (this is exactly how the wirepda
   "real HW takes no miss → r9999 faults spuriously" conclusion was reached).

## Boot bring-up order (what to make work, in order)

1. **CPU + RAM + the ARCS shim** → reach `/unix` `start` (a0=8) without the early UTLB-miss panic (needs
   `eaddr` set). See [Firmware](firmware-arcs.md), [Boot & console](boot-and-console.md).
2. **MC MEMCFG** → `szmem` sizes RAM correctly. See [MC](peripherals/mc.md).
3. **IOC2 minimal SCC** → "IRIX is alive" on the serial console. See [IOC2](peripherals/ioc2.md).
4. **Cache ops honored** (not NOP'd) → code coherence + DMA correctness. See
   [Cache, coherence & TLB](coherence-cache-tlb.md).
5. **HPC3 SCSI + WD33C93** → read the root disk. See [HPC3](peripherals/hpc3.md).
6. Empty GIO64 slots / no graphics → IRIX skips graphics cleanly. On a real Indy an empty slot
   bus-errors, and Henry now does the same (2026-10, stage S1 of [Bus errors](bus-errors.md)):
   `henry_soc.sv` decodes empty GIO space (`0x1f000000–0x1f9fffff` minus the Newport window, plus
   HPC3 chip 1) as `w_is_gio_empty`. With `CPUCTRL1.ABORT_EN` set, an uncached load there completes
   with `bad` set and the core takes a precise Data Bus Error (r9999 `c83cd5f`); a store is
   absorbed. Either way the MC latches `GIO_ERROR_ADDR/STAT` and raises INT3 `buserr[1]`. The
   Newport REX3 window (`0x1f0f0000–0x1f0f1fff`) is served by the ARM through `gio_window`, so
   IRIX finds a graphics board ([Newport on henry](newport-on-henry.md)); a `DISABLE_NEWPORT`
   build leaves it undecoded, the probe bus-errors, and IRIX comes up on the serial console.
   Cached accesses to non-existent memory and instruction bus errors are not done yet. See
   [GIO64](peripherals/gio64.md).

## Chasing a bug on silicon — HW watchpoint + the ISS diff

MAME-as-oracle only helps when the bug reproduces in MAME. When it only shows up **on the FPGA** — a
sim/synth timing hazard, or (as here) IRIX wedging somewhere MAME never reaches — you have to catch state
*on the running part*. The workflow that cracked the IRIX `bad istack` panic:

**1. Freeze the pipeline at the offending instruction (core.sv).** Reuse the single-step gate: a
**driver-programmable** breakpoint + store watchpoint (`bp_pc`/`bp_wp_addr`/`bp_wp_val` from AXI
`slv_reg9-11`, compiled in by `` `ENABLE_DEBUG_WATCHPOINT ``, which henry's `gen_mipscore.sh` passes by
default) that latches a "hit" flop and folds it into `w_step_ok`, so the core **stops retiring without a
reset** — the register file and DRAM stay coherent at the moment of interest. Because the trap
PC/addr/value are ports, moving the breakpoint does not need a re-synth. Arm with control-register bit 17
(`bp_enable`); bit 19 (`bp_fault_only`) switches to fault-only mode; `fault_clear` (bit 18) re-arms.

The trap has been reworked since the `bad istack` hunt below (`core.sv:963-1037`, current form):

```verilog
// PC breakpoint: freeze after retiring bp_pc, or (bp_fault_only) on a FAULT at bp_pc.
wire w_bp_match = bp_enable &
  (bp_fault_only
   ? (t_arch_fault & (t_rob_head.pc[31:0] == bp_pc))
   : ((t_retire     & (t_rob_head.pc[31:0]      == bp_pc)) |
      (t_retire_two & (t_rob_next_head.pc[31:0] == bp_pc))));
// Store watchpoint, now keyed on the STORE'S PC (bp_wp_addr holds a producer PC) and a
// threshold: freeze when that store's data is SMALLER than bp_wp_val (a small int
// written where a heap pointer belongs).  The data comes from the LSU store buffer.
wire w_wp_match = w_wp_data_here & (lsu_sb.data[31:0] < bp_wp_val);
// Fault trap: while armed (and not fault-only), the first fatal USERSPACE AdEL/AdES/IBE/DBE
// latches {epc,cause,badvaddr} and sets r_fault_hit.
wire w_step_ok  = (r_single_step | r_bp_hit | r_wp_hit | r_fault_hit) ? t_step_edge : 1'b1;
```

- **Timing trap (from the original sp watchpoint; the current `bp_pc` match above does compare
  the ROB head PC):** compare the *flopped* retire outputs (`retire_reg_data/ptr/valid`), **not** the
  combinational ROB head — the ROB-head read is already the near-critical retire path, and a 32-bit masked
  compare hung off it cost **WNS −3.6 ns**. Registering it (flop→logic→flop) closes timing at the price of
  the freeze landing ~1–2 instructions late (disassemble the window). Adding a probe *moves the critical
  path* — classic bring-up.

**2. Read the state out (driver, over AXI-Lite).** With the core frozen (not reset) the debug reads are
coherent: `read32(7)`=last PC, `read32(0xb)`=CP0 EPC, `read32(0x26)&31`=Cause, and the GPRs via
`write32(14,i); read32(0xe)` (a shadow register file rebuilt from the retire stream).
- **Gotcha that cost a synth (fixed):** the henry AXI wrapper once dropped `retire_reg_valid` end-to-end,
  so every GPR read returned 0. It is wired now: `henry_soc.sv` exports `retire_reg_valid`, and the wrapper
  feeds `w_reg_val0/1` into the S00_AXI shadow (`ip_hdl/axi_is_the_worst_v1_0.v:445-450, 718-723`).

**3. Read guest DRAM (`devmem`).** The driver mmaps guest RAM at host phys `0x5ff00000`. The M00 AXI
master folds guest physical addresses (`ip_hdl/axi_is_the_worst_v1_0_M00_AXI.v:524-540`, mirrored by
`fpga_map` in `sim/henry_tb.cpp`): guest `0x08000000–0x17ffffff` → offset `pa[27:0]` (so `host = 0x5ff00000
+ guest_pa` for `0x08000000–0x0fffffff`, and the upper 128 MB folds down to offset 0), and the device/PROM
window `0x1f000000–0x1fffffff` → offset `0x10000000 + pa[23:0]` (the PROM at guest `0x1fc00000` lands at
`+0x10C00000`).
The guest is **big-endian**, so byte-swap `devmem`'s output. **Caveat:** only *flushed* memory is DRAM-visible
— a freshly written-back-cached word (e.g. a just-updated scheduler global) reads stale `0`. An old global
(the wired int-stack ptr at `0xFFFFA020`) reads correctly; a hot one (the idle-sp global `0xFFFFA164`) doesn't.

**4. Diff against the ISS (`interp_mips`) — the silicon's oracle.** interp_mips boots the *identical*
kernel+disk fast and correctly, so it tells you what a value *should* be. This is what turns "sp is
`0x8834afb8`" into "corrupted" vs "legitimate." Trace the same PC in the ISS (a temp hook in `interpret.cc`,
or `--gdb`), read the same global via its `va_translate`, and compare.
- `PRID=<val>` env override (added at `interpret.cc` PRId init) sweeps R4400↔R4600 without a rebuild.
- `PCTRACEOUT=<file>` dumps one PC per retired instruction. **ALWAYS bound it with `-m <icnt>`, never a
  wall-clock `timeout`** — a 50 s run traced 1.4 **billion** PCs → 12.8 GB/file → filled the disk and OOM'd
  the box. The divergence you want is usually in the first few million instructions anyway.

**Worked example — the `bad istack` chase.** The watchpoint (freeze when sp is written `0x8834a___`) fired
at `resumeidle+0x2c: lw sp,-24156(zero)` → sp=`0x8834afb8`, which *looked* like sp corruption into the PDA
region. But reading that idle-sp global (`mem[0xFFFFA164]`) in the **ISS** returned the **same** `0x8834afb8`
— so it's the *legitimate* idle-thread stack pointer, not corruption. Reframe: the FPGA can't mount root
(SCSI), gets **stuck in the idle thread**, the timer fires during idle (sp above the int-stack boundary), and
`VEC_int`'s int-stack-only exit rejects it → panic. The ISS never hits it because with a working disk it
mounts root and stays *busy*. **The value of the tooling wasn't finding a corruption — it was *definitively
ruling one out*,** redirecting the hunt from the CPU to the SCSI/root-mount path. (Full trail:
`~/.../memory/project_irix_boot.md`.) At the time this trap was a hardcoded `BP_PC` + sp-watchpoint compiled
into the bitstream; it is now **driver-programmed** (`bp_pc`/`bp_wp_*` via `slv_reg9-11`), so the same hunt no
longer costs a re-synth to move the breakpoint.

**Reading FPGA timing/util after a probe:** the routed reports live in `…/<proj>.runs/impl_N/`
(`*_timing_summary_routed.rpt` WNS, `*_utilization_placed.rpt`). Grep the *fresh* one — the
`utilization_synth.rpt` is easy to misread if a prior run's copy is stale. Two knobs that bought timing
margin for the probe on a 94%-LUT-full die: shrinking the **ALU matrix scheduler 8→4**
(`LG_INT_SCHED_ENTRIES 3→2`) — the O(N²) wakeup/select is *on the critical path*, so it's a real WNS lever
(not an area win; the FPU dominates the LUTs) — **but that downsize proved buggy (mis-issue → replay) and was
reverted, so the live config stays 8 entries (`LG_INT_SCHED_ENTRIES=3`)**; and **L2 1024→8 lines** (a BRAM
knob, no LUT/correctness impact; at the time the L2 was not inclusive of the L1D, so shrinking was
safe). The L2 has since become inclusive of the L1D (r9999 `1079cf5..ff34709`): a small L2 is still
correct, but every eviction of a line the L1D may hold now costs a back-invalidate probe. Today the L2
default is 128 KB (`LG_L2_NUM_SETS=13`), and any cache size can be overridden from the build line
(`SV2V_DEFINES="LG_L2_NUM_SETS=8" ./gen_mipscore.sh`; see `machine.vh`).

## Verification tooling today (2026-10)

MAME remains the oracle for *what IRIX requires*. The core and SoC are now checked mostly against
`interp_mips` and with directed/random/formal tests. Everything below exists in code: in this repo or
the `r9999` submodule unless noted.

| Tool | What it does | Where |
|---|---|---|
| **Lockstep co-sim checker** | The ISS embedded in r9999 steps on every RTL retire and compares the written register, PC, and committed stores. | `sim/henry_tb.cpp --checker` (seed with `--iss-seed`); r9999 `ooo_core -c 1` (`top.cc`) |
| **Random-instruction co-sim** | Generates random MIPS3 programs and runs each under `ooo_core -c 1`, in parallel across seeds. | `r9999/tests/randgen/` (`gen_mips_test.py`, `run_parallel.sh`) |
| **Directed suites** | Per-feature assembly tests (TLB/XTLB, D-side TLB, cache ops, exceptions, IRQs, FPU, SCC, device regs, …) and the `exchammer` exception hammers used to chase the 2026-10 `EXCEPTION_DRAIN` hang. | `r9999/tests/*`, `r9999/tests/exchammer/` |
| **Checkpoints** | Resume from an `interp_mips` checkpoint (`--checkpoint`, `--cimg` preamble image), snapshot/restore the real Verilator state (`--save-at`/`--save-file`/`--restore`), and diff committed memory against an independent ISS checkpoint (`--verify-ckpt`). | `sim/henry_tb.cpp`; checkpoint→ELF loader shim in `~/code/mips-ckpt-shim` |
| **XPG flush injection** | Fires ARM-style whole-cache (`--extflush N`) or page-list (`--xfpages base,n,drop`) flushes into a running boot, to race the [XPG path](coherence-cache-tlb.md#dma-coherence-on-silicon-arm-requested-flushes-xpg) against live traffic. | `sim/henry_tb.cpp` |
| **HW retirement trace ring** | 2048-entry, two-bank (one bank per retire slot) record of retired instructions, frozen on a retired indirect jump to 0 / poison PC, read back over AXI. Opt-in with `ENABLE_PC_TRACE`; a sim-only per-retire trace buffer is `ENABLE_TRACE_BUFFER`. | `r9999/core.sv`, `LG_RTRACE_ENTRIES` in `machine.vh` |
| **Formal (yosys SAT/BMC)** | Decode (no valid destination of `$0`, no hidden physreg-0 write), free-list bank allocation, physreg 0 reads as 0 (BMC + induction), L1D store→load forwarding and response integrity, and the mispredict/delay-slot retire protocol. | `r9999/formal/run_*_formal.sh` |
| **Murphi models** | Explicit-state (CMurphi) proofs of the cache protocol: the non-inclusive baseline (`r9999_main.m`), the inclusive L2 with back-invalidate probes, presence bits and DMA snoop (`r9999_incl.m`, generated by `gen/make_incl.py`), the VA-indexed L1D with `pd`/`pidx` alias tracking (`r9999_va.m`), a non-blocking L2 (`r9999_nb.m`), DMA coherence options and the XPG page walk (`r9999_dma.m`, `r9999_pagewalk.m`). Every model carries `BUG_*` negative controls that must fail. | `r9999/formal/murphi/` (`run_*.sh`, see its `README.md`); CMurphi itself is not vendored |

## Related work

**Project CYAN** ([wiki.unix-haters.org](https://wiki.unix-haters.org/doku.php?id=sgimips:cyan))
is a from-scratch FPGA SoC of the SGI **Indigo IP20**, the board generation just
*before* Henry's Indy IP22. It's a sibling effort and the inspiration for this one, and it cross-checks
Henry from an independent direction.

- **haterMIPS** — CYAN's clean-room **R4000SC** core (8-stage R4000 pipeline, 48-entry TLB, 8 KB L1s +
  1 MB secondary cache, MIPS III + FPU; PRId `0x430`; verified vs Sail, cheritest, and the SGI PROM). It
  **independently corroborates** Henry's cache model: incoherent L1 + software `CACHE` flush for SMC, no
  snoop (see [Cache, coherence & TLB](coherence-cache-tlb.md)). Confirms `PageMask`-invalid → Machine
  Check `ExcCode=24` and the Wired/Random interaction too.
- **CYAN Express/Elan study** — the best open register-level reconstruction of the **GR2** graphics
  programming model (FIFO token interface, HQ2 registers, the `0xDEADBEEF` board probe, RE2/RE3 register
  map, from NetBSD `grtworeg.h` + MAME `sgi_re2`). Henry's [Express / XZ](graphics/express-xz.md) page
  borrows it for the Indy **GR4** equivalent.

**Different theses, deliberately.** CYAN aims for an **exact** SGI replica (precise R4000 microarchitecture).
Henry keeps only the **software-visible contract** IRIX/PROM probe (48-entry TLB, MIPS III, CP0, PRId,
`CACHE` semantics, phys-addr width) and is free to **modernize the microarchitecture** behind it (e.g. a
micro-TLB in front of the 48-entry JTLB to close timing — not something a faithful R4000 would have). Two
independent implementations triangulating the same under-documented machine is exactly why mining CYAN is
useful here: where CYAN and MAME agree, Henry's spec is on solid ground.

## Source material

- MAME (the oracle): `~/code/mame` (v0.287), Indy `indy_4610` + the IRIX 6.5.22 CHD.
- SGI chip docs: `~/code/sgi/docs/arcs_spec.pdf`, `~/code/sgi/docs/indy_docs/ip22/{mc,ioc,hpc3,gio64,vdma,dmux1}.pdf`.
- The symbolized IRIX kernel: `~/code/chd-dumper/extracted/unix` (ELF, with symbols).
- The r9999 working notes (in the submodule): `IRIX_CPU_REQUIREMENTS.md`, `IRIX_KERNEL_GAPS.md`,
  `IP22_CHIP_REGISTERS.md`, `MAME_QUESTIONS.md`.
