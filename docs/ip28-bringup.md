# IP28 (Indigo2 R10000) bring-up plan

The reference for every item here is indysim's `--ip28 --cpu r10000`
(`dsheffie/indysim` d6f4a44), which runs the real IP28 PROM (070-1477-002) to the
System Maintenance Menu and the IRIX 6.5.22 IP28 miniroot to the `Inst>` menu.
IRIS (techomancer/iris) and MAME back it up.

## Phase 1 -- the core is an R10000 (r9999, under `ENABLE_R10000`) -- DONE

On r9999 branch `r10k-cacheact` (2026-10-30; uncommitted at the time of writing):

- PRId `0x0925`, FIR `0x0900`, Config `0x6c00a002` (SS = 0: 512 KB, which must be at
  least the L2's real size -- the kernel's index-op sweep covers what Config claims).
- R10000 CACHE ops: `0x14` is a NOP (barrier); the S ops `0x17`/`0x13`/`0x03` are one
  mem op each, sequenced by the L2 over the 128-byte block (L1D probe per line, dirty
  writeback unless dropping), with the L1I invalidating the block at every colour in
  the background.
- **xkphys / TLB cacheability: CCA 3, 4 and 5 cache** (`CCA_CACHED`).  The IP28 kernel
  runs at xkphys CCA 5 (`0xa8...`); caching only CCA 3 ran it uncached, aliased with
  its CCA 3 K2 pages -> lost stores (the `kptbl` panic / bit-lock spin).
- CP0: `mtc0 $25` with any select (perf counters); FrameMask/Diag/PerfCount/ECC/
  CacheErr/TagLo/TagHi read 0; EntryLo and the TLBR shadow keep the R10000's 28-bit
  PFN (IRIX keeps software bits above the PFN), the translating TLBs only 31 PA bits.
- The PROM's secondary-cache SRAM test needs tag/data SRAMs we do not have: either a
  keypress at "Cache diagnostic FAILED", or the 2-word PROM patch (`0xbfc021cc`
  `jal 0xbfc05bb4` -> `nop`, `0xbfc021d4` `move s0,v0` -> `move s0,zero`); no checksum.

Validated on `ooo_core --ip28` (Verilated core + indysim's device models in C++, now in
r9999): the PROM, sash64 and the IRIX 6.5.22 IP28 miniroot reach `Inst>`; the PROM /
sash / early kernel run clean under the co-sim checker with the store check.

## Phase 2 -- the IP28 board in this repo's `henry_soc` (henry_tb)

Henry models the Indy (IP22).  The IP28 board differs in the places below.  The
reference for every row is the C++ model `ooo_core --ip28` runs (r9999 `sgi_hpc.cc`,
`sgi_mc.cc`, `top.cc`; copied from indysim d6f4a44), with IRIS behind it.  Rows are in
the order the IP28 PROM's POST needs them.  Everything is a build-time choice
(`ENABLE_IP28`, or the fork simply diverges); the Indy build must stay intact.

| # | Item | Henry (IP22) today | IP28 needs | Reference |
|---|---|---|---|---|
| 1 | **Clock dividers** | `ioc.sv` `PIT_DIV = 100`, `hpc3.sv` `RTC_DIV = 1000000`: a 100 MHz core | the IP28 build runs at **50 MHz**: derive every divider from one `CORE_MHZ` define, or the 8254 and RTC run at half speed (IRIX's clock, its delays and SCSI timeouts all follow) | -- |
| 2 | **IDs** | MC SYSID `0x13`; IOC2 SYSID `0x26` | MC SYSID **`0x15`** (rev D + EISA present; the PROM rejects rev < 5 once HPC3 says Full House); HPC3 SYS_ID **`0x1b`** as a word *and* byte `0x5985b` (Linux reads the byte) | `sgi_mc.cc` `0x1c`; `sgi_hpc.cc` |
| 3 | **Register read-back for the PROM's register tests** | MC/HPC3 DMA-channel registers mostly write-absorbed, reads 0 | the PROM walks 1s/0s through MC registers and the HPC3 DMA registers (e.g. ENET RX NBDP `0x14004`) and fails POST on any mismatch: plain storage for every register it tests | `sgi_hpc.cc` read/write pairs |
| 4 | **Memory map** | 256 MB DRAM at `0x08000000`; probe window at `0x20000000` with MEMCFG base `0x80` in 4 MB units; `w_is_nomap` = `0x18000000-0x1effffff` and `>= 0x30000000` | RAM at **`0x20000000`**, MEMCFG in **16 MB units** (base `0x20`, size `(field+1)*16 MB`), up to `0x5fffffff`; bank 0 = the 256 MB the board backs (wraps as SIMMs alias), banks 1-3 empty (loads 0, stores vanish); the **low 512 KB alias** reaches the base of RAM (`0x20000000`); the reserved decode moves above `0x60000000` | `top.cc` `ip28_mem_pa` |
| 5 | **The board decodes 32 PA bits** | `c_req_addr[35:32]` != 0 is reserved (bus error / zeros) | drop PA[35:32] at the SoC decode: IRIX's PTEs put software bits there (the core's TLB already drops them; xkphys addresses can still carry them) | IRIS `phys_mask` |
| 6 | **DMA addresses** | DMA engines (SCSI, ENET, MC VDMA) fold IP22 PAs onto board DRAM | the same fold for `0x2xxxxxxx` (incl. the low alias), so a DMA and the CPU reach the same bytes | indysim `mc_alias` (`ip28_bank0`) |
| 7 | **INT2 at `0x1fbd9000`** | INT3 at `0x1fbd9880` (`int3.sv`) | the same register set at **`0x1fbd9000`** (IOC offset `0x59000`; indysim remaps it onto INT3 `+0x880`) | `sgi_hpc.cc` `ip28_int2` |
| 8 | **8254 timers** | counter 2 only, for calibration (Indy IRIX ticks on CP0 Compare); `timer1_irq` tied 0 | counters **0 (rtclock -> IP4) and 1 (kgclock -> IP5)**, both clocked by **counter 2's output** (startrtclock: ctr2 = 200, ctr0 = 50 -> 100 Hz), latched in INT2 and acked through TIMER CLEAR (`+0x20`, bits 0/1).  IRIX IP28 ticks only on these. | `sgi_hpc.cc` `pit[]`, `pit_period`, `pit_irq` |
| 9 | **93CS56 EEPROM** | present (`hpc3.sv`), MAC words only | the IP28 PROM keeps its **environment** there too: IRIS's default image (layout revision 9), byte port `0x3000b` as well as the word | `sgi_hpc.cc` `ip28_eeprom_t` |
| 10 | **8042** | decoded (`w_is_kbd`) | present even without graphics (POST tests it): answer self-test / interface test | `sgi_ps2.cc` |
| 11 | **Second WD33C93 at HPC `0x48000`** | absent | registers present, every selection times out (local0 bit 2, no DMA channel); PROM, sash and IRIX probe it | `sgi_hpc.cc` (scsi1) |
| 12 | **EISA** | n/a (Indy) | SYSID says EISA present, so IRIX probes EISA I/O (`0x00080000`...) and memory: answer "no cards" without inventing phantoms (an open item in indysim too) | IRIS |
| 13 | **L2 size** | `LG_L2_NUM_SETS` per build | at most **512 KB** (Config SS = 0) | -- |

**Status (2026-10-31, uncommitted).**  All behind `ENABLE_IP28` (the fork's
`gen_mipscore.sh` passes `ENABLE_IP28 CORE_MHZ=50`; `sim/Makefile` `+define+ENABLE_IP28`);
the Indy configuration lints clean.  Driven by running the IP28 PROM on henry_tb
(`--prom ip28prom_nosccachediag.bin --disk irix65_ip28.img`) and fixing each wall:

| # | Done | Seen on henry_tb |
|---|---|---|
| 1 | `CORE_MHZ` drives the 8254 (`PIT_DIV`), ds1386 (`RTC_DIV`) and RPSS dividers | sv2v at 50 MHz: `PIT_DIV = 50`, `RTC_DIV = 500000` |
| 2 | MC SYSID `0x15`; IOC SYSID `0x1b` (word and byte `0x5985b`) | -- |
| 3 | MC GIO64_ARB (`0x84`) reads back; ENET CBP/NBDP already did | -- |
| 4, 5 | MEMCFG decode in 16 MB units at `0x20000000`; bank 0 = the 256 MB, wrapping; other banks empty; reserved from `0x60000000`; 32-bit PA decode | "No usable memory found" gone |
| 6 | one guest-PA -> board fold (`ip28_board_pa`) for the CPU and both DMA masters | the PROM's MC-DMA memory clear |
| 7 | INT2 at `0x1fbd9000` remapped onto the INT3 / 8254 registers | "Data path" and "INT path" POST failures gone |
| 8 | 8254 counter 2 output pulse; counter 1 (byte `0xb7`); counters 0/1 count counter 2; timer1 -> IP5 | not yet exercised (IRIX) |
| 9 | a writable 93CS56 (READ/WRITE/ERASE/EWEN/EWDS/ERAL/WRAL), byte lane `0x3000b`, reset to the IRIS erased-part image | "Could not set NVRAM variable" gone |
| 10 | nothing needed: the ARM-served 8042 passes POST | -- |
| 11 | a second `scsi_shim` (HD1 at `0x48000`, HPC3 channel 1) that times out every selection, INTRQ -> local0 bit 2 | "SCSI controller 1 diagnostic FAILED" (fix being verified) |
| 12 | `0x00080000-0x07ffffff` floats high (reads all ones, stores dropped) | -- |
| 13 | -- | build check |

`DISABLE_DMA_SNOOP` (`make NOSNOOP=1`) drops the DMA snoop shim; to be validated on IP28.

Not needed: graphics (the IP28 kernel has no Newport driver; serial console), the
R10000's speculative-store hazard (r9999 never speculates uncached accesses; `cache 0x14`
is a NOP), real tag/data SRAMs (see Phase 1), the audio HAL2 ("AES receiver not
responding" is harmless), the PBUS channel configuration ("pbus configuration failed"
is printed on IRIS/indysim boots too).

Coherence: henry's DMA snoop shims stay.  IRIX IP28 also flushes and invalidates its
DMA buffers with the S block ops (`0x17`/`0x13`), which `ooo_core --ip28` (no snooping
at all) shows are sufficient on their own -- so the shims are a second line of defence
here, not a requirement.

**Validation.**  henry_tb runs the IP28 PROM to the System Maintenance Menu, then
sash64 and the miniroot to `Inst>`, compared against `ooo_core --ip28` (same core, C++
devices) and indysim.  Bring the C++ checker's PROM/IRIX mode (device-load adoption,
interrupt sync, store check -- r9999 `top.cc`) to henry_tb as far as it goes; henry_tb
already has the store check.  Per-row directed tests where a device has state (8254
cascade and acks, MEMCFG decode incl. the alias and wrap, EEPROM protocol, INT2
latching).

**Order of work.**  Rows 1-3 get POST past its first register tests; 4-6 are memory
sizing and the kernel's first DMA; 7-8 the clock (without them IRIX sleeps forever --
seen on `ooo_core` before its 8254 was clocked); 9-12 the device probes; 13 is a build
check.

## Phase 3 -- driver and firmware

- The ARM driver loads the IP28 PROM at the reset vector (`0x1fc00000`); stock image
  plus a keypress, or the 2-word cache-diagnostic patch above.
- EEPROM contents (environment, MAC): preloaded from a file the driver keeps, as the
  board's bbRAM is today.
- The disk: the same SCSI path as IRIX on IP22 (`irix65_ip28.img`: a VH with sash64,
  `unix.IP28` and the miniroot in swap; boot `5` -> `boot -f dksc(0,1,8)sash64` ->
  `boot -f dksc(0,1,8)unix`).  A complete IP28 install comes from IRIS (CD install) and
  is converted CHD -> raw.
- The PL runs at 50 MHz (clk50.xdc; `PL0_REF_CTRL` = `0x01011E00` on the board).

## Phase 4 -- silicon

IP28 PROM -> sash64 -> IRIX 6.5.22 IP28 miniroot; Linux (ip28_defconfig) to a
Debian root.
