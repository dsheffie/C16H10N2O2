# Bus errors: detected at the MC, returned with the response

Status: **S1 IMPLEMENTED** (2026-10-16/17). Uncached loads and stores to empty GIO space
fault as on IP22:

- henry `rtl/mc.sv` decides "empty" and latches `GIO_ERROR_ADDR/STAT`; the MC bus-error line
  is INT3 `buserr[1]`.
- r9999 `c83cd5f`: the L1D forwards `mem_rsp_bad` on uncached-load responses, and the core
  raises a precise data bus error (cause 7) at retirement.
- The `henry_arcs` shim sets `CPUCTRL1.ABORT_EN` (r9999 `91129f9`).
- Bare-metal test: henry `tests/buserr`.

S2 (cached accesses to non-existent memory) and S3 (instruction bus errors) are not done.
Before this, a CPU access that nothing answered returned DRAM-shadow data, so the OS's probes
(Linux `get_dbe()`, IRIX `badaddr`) never saw a fault. The design below is what was built.

## Architecture (IP22 MC chip spec §5.14–5.17; MIPS R4000)

- A CPU **read** that times out on GIO (or hits no memory bank) gets an error
  response; the R4000 takes a precise **Data Bus Error** (ExcCode 7, EPC at the
  load, BadVAddr not written), or **Instruction Bus Error** (ExcCode 6) for a fetch.
- A **write** is posted; its error is reported asynchronously as the MC bus-error
  interrupt (INT3 bus-error input → IP6).
- The MC latches the cause:

| Register | Address | Contents |
|---|---|---|
| `CPU_ERROR_ADDR` | `0x1fa000e0/4` | address of a CPU-side error |
| `CPU_ERROR_STAT` | `0x1fa000e8/c` | bit 10 `ADDR`: no valid memory bank; write clears |
| `GIO_ERROR_ADDR` | `0x1fa000f0/4` | address of a GIO error |
| `GIO_ERROR_STAT` | `0x1fa000f8/c` | bit 10 `TIME`: GIO bus timed out; write clears |

- GIO time-outs only happen with `CPUCTRL1.ABORT_EN` (bit 4) set; without it the
  real machine hangs. We return zeros instead of hanging (today's behaviour).

## Design

The fault is decided where IP22 decides it -- the MC, in the SoC -- and travels
back up with the response. No platform knowledge in the core, and nothing on the
load-issue path: it rides the slow response paths.

1. **henry (MC):** decode "empty GIO" = `[0x1f000000, 0x1fa00000)` minus present
   windows (today: the REX3 `gio_window`), plus HPC3 chip 1 `[0x1fb00000, 0x1fb80000)`
   (an Indy has only chip 0; Linux probes the graphics slot only after chip 1's
   PBDMA read bus-errors). The firmware sets `ABORT_EN` at boot, as SGI's PROM does
   (Linux only read-modify-writes `CPUCTRL1`). With `ABORT_EN`:
   - load: complete through the device FSM with `bad` set (no DRAM access); latch
     `GIO_ERROR_ADDR`, `GIO_ERROR_STAT.TIME`.
   - store: absorbed (no DRAM write); latch the same.
   - the MC bus-error line = any error status bit set → INT3 `buserr[1]` (MC),
     cleared when the OS writes the status register.
2. **r9999 L2:** forward the response's `bad` on uncached-load responses to the L1D
   (today `mem_rsp_bad` is an unused input).
3. **r9999 L1D:** `INJECT_UNCACHE_LOAD` copies `bad` into the load's response as a
   new `bus_err` bit (no destination write). Uncached stores ignore it (posted).
4. **r9999 core:** `bus_err` marks the ROB entry faulted; at the head it becomes
   cause 7. EPC and BD come from the existing precise-exception path.
5. **Golden model:** the co-sim ISS (`interpret.cc` + its `sgi_mc`) and indysim get
   the same rule, so lockstep does not diverge at the first probe.

## Stages

- **S1 (done):** uncached loads/stores to empty GIO space. Enough for Linux's
  Newport probe and IRIX's GIO probes.
- **S2:** cached accesses to addresses with no memory bank (`CPU_ERROR_STAT.ADDR`):
  the L2 and L1D must not install the line; the requester gets DBE.
- **S3:** instruction fetch → IBE.

## Tests (henry `tests/buserr`, bare metal under henry_tb; prints P/F)

- uncached `lw` from `0xbf000000` with `ABORT_EN`: cause 7, EPC = the load, BD = 0,
  BadVAddr unchanged, `GIO_ERROR_ADDR` = `0x1f000000`, `GIO_ERROR_STAT.TIME` set;
  writing the status clears it.
- the same load in a branch delay slot: BD = 1, EPC = the branch.
- a load from the REX3 window (`0x1f0f133c`) still completes normally.
- a store to empty GIO: no exception, no DRAM write, MC bus-error interrupt pending
  in INT3 until the status is cleared.
- without `ABORT_EN`: the load returns 0, no exception (today's behaviour).
- the test must FAIL on today's RTL before any fix.
