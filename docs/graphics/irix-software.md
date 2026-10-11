---
title: How IRIX drives Newport (Xsgi, ng1 driver, GL)
status: reference (static reverse engineering of IRIX 6.5.22; nothing run on henry)
---
# How IRIX drives Newport: Xsgi, the `ng1` kernel driver, and GL

> Intro: this is the **software** side of the Newport pages. [rex3.md](rex3.md) and its siblings describe
> the hardware; this page describes what IRIX 6.5.22 actually *does* to that hardware, from static reverse
> engineering of the shipped binaries. It is what a henry graphics path (or a QEMU/ISS model) has to satisfy.
> The henry design study that uses these numbers is `NEWPORT_FEASIBILITY.md` at the repo root.
>
> **Nothing here was run on henry.** Facts marked *(inferred)* were not confirmed against a branch target or
> a running system.

## Sources

| Piece | IRIX path | Notes |
|---|---|---|
| X server | `usr/gfx/arch/IP22NG1/Xsgi` (`Xsgi.hyper.rex3`) | n32, REX3 DDX linked in statically, function names in dynsym |
| XL X module | `usr/lib/X11/dyDDX/ng1.so` | Indigo2 XL (NEWPRESS) build |
| Kernel driver | `usr/cpu/sysgen/IP22boot/ng1.a` | `newport.o`, `newport_init.o`, `newport_retrace.o`, `newport_dma.o`, `corona_i2c.o`, `newport_tp.o`; unstripped, DWARF |
| OpenGL | `usr/gfx/arch/IP22NG132/libGLcore.so` | n32, unstripped with debug info (`IP22NG1` = o32 MIPS-II build) |
| IRIS GL | `usr/gfx/arch/IP22NG132/libgl.so` | n32, unstripped |
| Header | `usr/include/sys/gfx.h` | `GFX_*` ioctls |
| Kernel | `unix.clean` (6.5.22f) | `MCdma` at `0x880cb7b4` |

Extracted straight from the inst images (`/mnt/ssd/irixdist/m1/dist/*.sw`) with `/mnt/ssd/irixdist/x/idbx.py`,
no loop mount. **Everything is kept in `~/ip22-assets/newport_re/`**:
- the binaries and their disassemblies (`*.dis`)
- `xsgi.lab`: Xsgi disassembly labelled by function, and `fn.sh` to print one function from it
- `ng1a/*.dis`: kernel driver disassembly, including `ng1a/pdma.txt` (the pixel-DMA path)
- `mcdma.txt`: `MCdma` from `unix.clean`

## 1. Who touches REX3

**User space maps REX3 directly.**
- Xsgi opens `/dev/gfx` and attaches through the `GFX_*` ioctls (`GFX_ATTACH_BOARD` = 103, etc.) and the RRM
  layer (`rrm*`).
- `newportMapGfx` calls `v_mapsegment(..., 16 pages)`, mapping the REX3 window into the process.
- From then on Xsgi, OpenGL and IRIS GL issue **plain uncached loads and stores** to REX3.

**The kernel is only involved for:**
- FIFO-full flow control (section 3)
- vertical retrace (buffer swaps, gamma, cursor, VC2/XMAP writes)
- graphics context switches (section 5)
- pixel DMA (section 4)

## 2. Access patterns

### Drawing is posted stores; it never polls

There is no FIFO-credit counting ("check every N writes") anywhere. Across all of Xsgi there are only **120
loads from STATUS/USTATUS**, and they are only in:
- init (`rex3InitHW` 48, `rex3Init` 12)
- colormap/cursor DCB code (`rex3Store*Colors`, `rex3Install*Map`, `rex3DisplayCursor`)
- `rex3ReadImage*`

The polls that do exist are a compiler-unrolled spin, `while (status & bit);` unrolled six times:
```
lw a4,4924(s0); andi a4,a4,0x8; beqz ...   (x6, then loop)
```
- `0x8` = GFXBUSY, read via **USTATUS** (`0x133c`) from user code
- `0x10` = BACKBUSY, read via **STATUS** (`0x1338`) from the kernel, always before a DCB access
- user-level finish is `gl_finishasm` in libgl (`lw 4924; andi 0x8; bnez`)
- in libGLcore, polls appear only in `__glNptRect`, copy/readpixels and accum setup

> **STATUS is read-to-clear, and the kernel reads it in ordinary polls,** not just in the interrupt handler.
> A model must clear interrupt bits on any STATUS read.

### Per-primitive access density

| Primitive | Setup stores | Stores per item | Reads |
|---|---|---|---|
| Solid rect (`rex3DrawSolidRects`) | 4 (DRAWMODE1, DRAWMODE0=0x326, WRMASK, COLORI) | **2 per rect** (`sw 336` XYSTARTI, `sw 2388` XYENDI+GO) | 0 |
| Zero-width line (`rex3SolidZeroSeg`, `rex3LineSS`) | — | 2 per segment | 0 |
| Text (P2C, 13-row font) | — | ~2 + 13 per glyph pair, **≈7–8 per character** | 0 |
| PutImage (PIO) | DRAWMODE0/1, WRMASK, XYSTARTI/XYENDI | 1 `sw 2608` (HOSTRW0+GO) per 32-bit word | 0 |
| CopyArea (`rex3CopyRect`) | XYSTARTI/XYENDI | **1** `sw 2324` (XYMOVE+GO); REX3 copies VRAM→VRAM internally | 0 |
| GL smooth triangle | slopes, once per triangle | ~4–5 per scanline (3× `swc1` color, `sw 2392` XSTARTENDI+GO, YSTART on y-step) | 0 |
| GL line/point (n32) | — | 2–4 `sd` per vertex | 0 |
| GetImage / ReadPixels (PIO) | priming write + GFXBUSY spin | — | **1 uncached read per word** |
| Context swap (kernel) | — | ~50 writes | ~50 reads |

Notes:
- **Glyphs:** one ZPATTERN+GO store (`sw 2068` = `0x814`) per glyph row; `rex3PolyGlyphBltP2C`/`P3C`/`P4C`/`P5C`
  pack 2–5 glyphs side by side into one pattern word.
- **GetImage (PIO):** DRAWMODE0=`0x45`, a dummy `0xdeadbeef` to HOSTRW0+GO to prime, spin on USTATUS GFXBUSY,
  then each `lw 2608` returns one word and starts the next read. This is the one round-trip-bound path.
- **CopyArea** is a cheap store that hides a large backend job (an xterm scroll is ~620K pixels of work).

### Store widths a bridge must accept

| Who | Stores to REX3 |
|---|---|
| Xsgi | 32-bit `sw` only (no `sd`/`ld`); DCB accesses are narrow: `sh 578`, `sb`/`lbu 579` (DCBDATA0+2/+3), `sw` to DCBMODE (568) |
| Kernel I²C/VC2 | `lbu 579(rex3)` |
| n32 OpenGL (`libGLcore`) | **64-bit `sd` on register pairs**: `sd 312/320` (XSTARTF:YSTARTF, XENDF:YENDF), `sd 2360` (XYSTARTF pair + GO), `sd 512/520/528` (colour/slope pairs), `sd 2568/2584` (colour pairs + GO), `sd 2608` (HOSTRW0:1 + GO, two pixels per store, in `__glNptProcess*TexSpan_asm`) |
| n32 OpenGL | **`swc1`** straight to colour registers (324 sites, e.g. `__glNptSmoothRGBSubTriangle`) |
| n32 IRIS GL | `sd` in `__line_shade`, `_line2d`, `__pnt` |
| o32 (MIPS-II) builds | `sw` only |

So the path from the CPU to REX3 must handle `sw`, `sd`, `sh`, `sb`/`lbu`, and FP-unit stores (`swc1`).

## 3. Flow control: the FIFO-full interrupt

- `initRex3` writes `rex3_config_default = 0x000230c2` to CONFIG: GIO64, BUSWIDTH=64, GFIFODEPTH=16, BFIFODEPTH=8.
- `ng1_init` registers `ip24_newportInterrupt` (Indy) or `ip22_newportInterrupt` (Indigo2) with `setgiovector`.
- The handler reads STATUS (`0x1338`) and tests:
  - VRINT `0x20` → `newportRetraceHandler`
  - VIDEOINT `0x40` → `ev1_interrupt`
  - `0xc0000` BFIFO_INT | GFIFO_INT
- If INT2 local0 bit0 ("FIFO full") is pending and unmasked, it calls **`newportFIFO`**:
  1. mask the LIO bit, `flushbus`
  2. if interrupted from user mode: `spl0`, `gfx_waitf_on`
  3. spin on the **LIO status byte** (not REX3) with `us_delay(1)`, up to `0x1e8480` iterations (~2 s)
  4. on timeout: `cmn_err` + `ng1_error`
  5. re-enable the mask

  So a writing process stalls inside the kernel ISR until the FIFO-full line drops; the line must deassert
  level-sensitively as the FIFO drains.
- **The interrupt is optional in practice.** `~/code/iris` (a Rust IRIX emulator, `src/rex3.rs`) uses a 64K-entry
  software GFIFO and never raises FIFO-full, and still runs the IRIX GUI *(not run here)*. A model with a deep
  queue that never overflows can omit it.

## 4. Pixel DMA (the `ng1dmaintr` hang)

Large image transfers do **not** use PIO; they go through MC graphics DMA via a private ioctl.

### Which calls use it, and when

- **Private gfx ioctl command 21002** ("NG1_PIXELDMA" in Xsgi's error string). In the kernel, `newportPrivate`
  copies in a 32-byte argument and calls `Ng1PixelDma`.
- **GetImage** (`rex3ReadImage`, `rex3ReadImage12`, `rex3ReadImage24`): DMA when `width*height ≥ 7000` pixels
  (`mult w,h; sltiu ...,7000`); PIO below.
- **PutImage** (`rex3DrawImage`, `rex3DrawImage12`, `rex3DrawImage24`): DMA when `width*height ≥ 16384` pixels.
- **CopyArea and text never use DMA.**
- Large requests are split into chunks of `0x180000 / width` rows per ioctl; a 1280×1024 `xwd -root` is **one** ioctl.
- **On ioctl failure Xsgi prints an error and gives up**; there is no PIO fallback.
- Before the ioctl, Xsgi programs REX3 itself from user space:
  - read: DRAWMODE1, DRAWMODE0=`0x145`, XYSTARTI, XYENDI, then 0 to offset `0x30`
  - draw: DRAWMODE0=`0x46`, WRMASK, 0 to offset `0x120`
- **Argument struct** (filled on Xsgi's stack):

  | Offset | Field |
  |---|---|
  | +0 | width |
  | +4 | rows |
  | +8 | flags: bit0 = 1 draw, 0 read |
  | +12 | 0 |
  | +16 | `0xa30` (register offset of HOSTRW0+GO) |
  | +20 | user buffer pointer |

- **GL:** `libGLcore` (n32) has four 21002 call sites in its read/draw/copypixels code near `__glNptPickCopyPixels`
  (nearby compares 12289, 20480, 2048, 1025 rows; which one is the cutoff was not pinned down). IRIS GL `libgl` calls
  it from `gl_pixeldma_read` / `gl_pixeldma_write` (strings "pixel dma read/write failed"), *(inferred)* reached
  from `lrectread` / `lrectwrite`.

### What the kernel does (`Ng1PixelDma` in `newport_dma.o`, then `MCdma` at `0x880cb7b4` in `unix.clean`)

1. **Validate:** EINVAL if `width > 0xffff`, `rows > 1024`, or `width*rows > 0x180000`.
2. **Pin and map the user buffer:** `userdma`, `vdma_set_tlb`, `kvpalloc`, `ng1stridemkudmada`. DMA_MEMADR gets
   the **user virtual address**: the MC's DMA TLB does the translation.
3. **GIO target** = `kvtophys(rex3 + (arg[+16] & 0xfff))` = `0x1f0f0a30` (HOSTRW0+GO).
4. **Spin on REX3 STATUS GFXBUSY.**
5. **`MCdma` programs the MC** (KSEG1 `0xbfa0xxxx`, big-endian low word):

   | MC offset | Register (reading) | Value written |
   |---|---|---|
   | `0x164` | DMA_CAUSE | 0 (clear) |
   | `0x16c` | DMA_CTL | `|= 0x110` (interrupt on), or set `0x100` and clear `0x10` when polling |
   | `0x2004` | DMA_MEMADR | user virtual address |
   | `0x2034` | DMA_MODE | `0x50` draw (memory→GIO), `0x52` read (GIO→memory); bit 1 = to-host, see the bit table below |
   | `0x2014` | DMA_SIZE | `rows << 16 \| bytes per line` |
   | `0x201c` | DMA_STRIDE | `zoom << 16 \| stride` |
   | `0x202c` | DMA_GIO_ADRS | GIO address; **this write starts the transfer** |

6. **Wait for completion:**
   - with **`ng1intrena` = 1** (the default; the variable is at `0x882f6ba0`): `setlclvector(4, ng1_dma_intr)`,
     arm `ng1dmatimer`, and `sv_wait` on **`ng1dmaintr`** (`0x882f7e08`)
   - with `ng1intrena` = 0: `MCdma` clears the interrupt enable and waits synchronously (polls the DMA run bit)
7. Strides `≥ 0x8000` take a separate `fakePICdma` path.

### The MC graphics DMA engine (behavioral spec for a model)

Sources, in order of authority:
- **`mc.pdf`** (MC Chip Specification, `~/Desktop/indy_docs/`): the register map, and the statement that the
  master does virtual DMA "using a TLB in MC and the UNIX page tables". It gives **no bit fields**: it defers to a
  separate *Virtual DMA Programmer's Guide*, which we do not have.
- **`ioc.pdf`**: interrupt wiring.
- **IRIX `vdma_set_tlb`** (`kern/io/vdma.c`, `0x880dab5c` in `unix.clean`): the TLB entry format, from
  disassembly.
- **IRIX `VdmaInit`, `vdma_wait`, `vdma_fault`** (`0x880da5ac`..) and **`ng1_dma_intr`** (`newport.o`):
  CTL bits, the fault/restart protocol, and the meaning of the DMA_RUN status bits.
- **MAME** `src/mame/sgi/mc.cpp` (`~/code/mame`, last touched 2023-07, `adc3349c1ce`): transfer semantics
  (`perform_dma`, `dma_translate`). It models no faults.
- **iris** `src/mc.rs` (`~/code/iris`, the Rust IRIX emulator): bit names (`DMA_CTL_XLATE`, `DMA_MODE_LONG`,
  the `DMA_CAUSE_*` fault bits) and a fault model. These came in with its initial commit, with no cited source,
  but they agree with the IRIX code everywhere the two can be compared.

**Registers** (physical `0x1fa0xxxx`; the 32-bit value is the low word, at `+4` from the doubleword address
given in `mc.pdf`):

| Register | Address | Meaning |
|---|---|---|
| DMA_GIO_MASK / DMA_GIO_SUB | `0x150` / `0x158` | GIO address translation; `VdmaInit` zeroes them, and MAME ignores them |
| DMA_CAUSE | `0x160` | iris: bit 0 FAULT, bit 1 TLB_MISS, bit 2 CLEAN, bit 3 COMPLETE. IRIX only ever writes 0 to it, which drops the interrupt, and reads the status from DMA_RUN instead |
| DMA_CTL | `0x168` | bit 4 = interrupt enable; **bit 8 = XLATE** (MEMADR is virtual and goes through the DMA TLB; when clear it is physical). iris: bit 1 = 16 KB pages, bit 0 = 8-byte PTEs (both 0 for IRIX: 4 KB pages, 4-byte PTEs, matching `vdma_set_tlb`'s `VA[21:12]*4` indexing). `VdmaInit` writes `0x2000410c`; MCdma ORs in `0x110` (interrupt) or sets `0x100` and clears `0x10` (poll). Bits 2, 3, 14, 29 are unidentified |
| DMA_TLB_HI_n / DMA_TLB_LO_n, n = 0..3 | `0x180 + 0x10*n` / `0x188 + 0x10*n` | 4-entry DMA TLB, below |
| DMA_MEMADR | `0x2000` | memory **virtual** address; `0x2008` also loads default parameters |
| DMA_SIZE | `0x2010` | `[31:16]` line count, `[15:0]` line width in bytes; also loads COUNT's byte count |
| DMA_STRIDE | `0x2018` | `[25:16]` line zoom, `[15:0]` **signed** stride, added to the address after each line |
| DMA_GIO_ADR | `0x2020` | GIO address, no start |
| DMA_GIO_ADRS | `0x2028` | GIO address **and start** (IRIX's path) |
| DMA_MODE | `0x2030` | bit 1 TO_HOST (GIO→memory), bit 2 SYNC (wait for vsync to start), bit 3 FILL, bit 4 DIR (1 = increment), bit 5 SNOOP, **bit 6 LONG** (iris's name; see below) |
| DMA_COUNT | `0x2038` | `[25:16]` zoom count, `[15:0]` byte count (working counters) |
| DMA_STDMA | `0x2040` | write bit 0 = start |
| DMA_RUN | `0x2048` | read-only: bit 6 = running, bit 3 = done; when stopped without done, bits [5:0] give the reason (see *Graphics MMU faults*) |
| DMA_MEMADRDS | `0x2070` | GIO address + default parameters + start |

**Address translation (the "MMU"):** two levels, reusing the process's own MIPS page table.
- The "DMA TLB" is misnamed: its 4 software-loaded entries cache **pointers to pages of PTEs** (the first
  level of the walk), never translations. The second level is a **hardware page-table walk** on every page touched.
  The CPU, by contrast, refills its own TLB in software from the same page table, using the same EntryLo-format PTEs.
- Each TLB entry maps one **4 MB** VA region, so 4 entries cover 16 MB of buffer.
- `TLB_HI` = VA & `0xffc00000`.
- `TLB_LO` = (PA of a 4 KB page of PTEs >> 12) << 6 | 2. Bit 1 is valid. That page holds the 1024 PTEs for the
  region; IRIX points it at its own page table for the user VA.
- To translate:
  1. Match VA[31:22] against `TLB_HI`.
  2. Read the PTE (32 bits) from `((TLB_LO & 0x003fffc0) << 6) + VA[21:12]*4`.
  3. PA = ((PTE & `0x03ffffc0`) << 6) | VA[11:0]. This is the EntryLo PFN layout.
- So **the engine does one memory read per page crossed**. A model has to do that read from memory as well.
- **Before loading the TLB, the kernel writes the PTE page back from its cache** (`cache_operation`), because the
  walk reads memory directly.
- The 4 TLB entries hold only PTE-page pointers; whether real hardware caches the last PTE is unknown.

**Graphics MMU faults and restart (from IRIX's handlers; MAME models none, and iris raises the cause bit but does not
resume):**
- A translation failure **stops** the engine:
  - DMA_RUN bit 6 (running) and bit 3 (done) are both clear, and the low bits give the reason;
  - **MEMADR holds the faulting VA**, and the counters stay where they stopped;
  - the DMA interrupt (Local0 bit 4) is raised, the same as on completion.
- `ng1_dma_intr` and the polling loop `vdma_wait` both read DMA_RUN:
  1. bit 3 set: done; clear DMA_CAUSE and wake the sleeper;
  2. otherwise, if MEMADR equals the VA of the previous fault, no progress was made: `cmn_err`, fail;
  3. otherwise call `vdma_fault(run)`. If it returns 0, write 0 to DMA_CAUSE and **1 to DMA_STDMA, which resumes
     the transfer from where it stopped**.
- `vdma_fault(run)` decides:
  - run bit 3 set: nothing to do;
  - **any of run bits 1, 2, 4, 5 (`0x36`) set: fatal**. Bit 1 is a "TLB miss": no first-level entry covers the 4 MB
    region, so the walker has nowhere to start. IRIX loads every entry it needs up front, so this is a bug; bit 2 is a clean fault. Bits 4 and 5 are unidentified;
  - otherwise (bit 0, a **graphics MMU page fault**: the hardware walker found V=0 in the PTE): find the valid TLB entry for VA[31:22], read the PTE.
    - If the IRIX software-valid bit (PTE bit 30) is clear, fail.
    - For a to-host transfer, fail if the D bit (2) is clear.
    - Otherwise set **V (bit 1)** in the PTE, write it back with a cache writeback, and return 0 to restart.
- This exists because of IRIX's reference-bit emulation: pages can be software-valid but hardware-invalid (V=0).
  DMA_RUN's low bits use the same encoding as iris's DMA_CAUSE bits (0 fault, 1 TLB miss, 2 clean, 3 done),
  which is the cross-check that iris's names are right.
- **For a model:** a fault means stop, set the reason bit, leave MEMADR = VA, and interrupt; STDMA resumes. On a
  stock IRIX boot the fault path should be rare (Xsgi buffers are touched before the ioctl), so a first model can
  treat any fault as fatal and still run.

**MODE bit 6 (LONG):**
- IRIX always sets it (`0x50`/`0x52`), and iris names it LONG but gives it no behaviour.
- `mc.pdf` calls the graphics DMA master a "long burst" device for GIO arbitration, so it most likely selects
  long-burst / 64-bit GIO transfers *(inferred)*.
- MAME ignores it and always does 64-bit GIO accesses, which is what IRIX's setting needs, so a model can treat
  LONG as the only mode.
- MAME's `DMA_MEMADRDS` default mode `0x28` (FILL + SNOOP, no LONG) is the one place it is clear.

**Transfer:** for each line, `zoom` times, for `width` bytes:
- **Memory→GIO** (IRIX draw, mode `0x50`): pack up to 8 bytes **big-endian** and do one 64-bit GIO write to
  `GIO_ADR`. The address does not advance: `0x1f0f0a30` is REX3 HOSTRW0+GO, so one write is two 32-bit pixels.
- **GIO→memory** (IRIX read, mode `0x52`): one 64-bit GIO read per 8 bytes, scattered big-endian into memory.
- **FILL** writes the GIO address value itself into memory.
- Address steps:
  - between zoom passes over the same line, rewind by `width`;
  - after each line, add the signed `stride`.

**Completion:**
- set DMA_RUN bit 3 and clear bit 6;
- if DMA_CTL bit 4 is set, set DMA_CAUSE bit 3 and raise the MC `int_dma_done` pin;
- `int_dma_done` → IOC/INT3 **Local0 status bit 4, "MC DMA Done"** (`0x1fbd9880`, mask `0x1fbd9884` bit 4,
  masked by default). That is IRIX's `setlclvector(4, ng1_dma_intr)`;
- IRIX then clears DMA_CAUSE, which drops the line.

For comparison, the other Newport interrupts on the IOC:
- FIFO full = Local0 bit 0;
- graphics (REX3) = Local0 bit 6;
- vertical retrace = **Local1 bit 7**.

### Why `xwd` hung under QEMU

QEMU's IP22 model never raises the MC DMA-complete interrupt (Local0 bit 4), so Xsgi sleeps forever on
`ng1dmaintr` the first time a GetImage reaches 7000 pixels. To fix it at the source, implement the engine above.
Raising the interrupt alone only turns the hang into empty images. The pieces are the two-level TLB walk, a
64-bit big-endian GIO access per 8 bytes to HOSTRW0+GO, and on completion DMA_RUN/DMA_CAUSE plus Local0 bit 4.
MAME's `perform_dma` is a working reference (about 100 lines).

### Ways around it

- There is **no** environment variable, Xsgi option, or mtune tunable.
- **`ng1intrena = 0`** (patch `.sdata` in the kernel or poke kmem) removes the sleep only. The MC DMA engine
  must still really move the data.
- **Force PIO in Xsgi:** change the immediate of these six `sltiu` instructions to `0xffff`. `sltiu` sign-extends
  it to `0xffffffff`, so the compare is always true and the PIO branch is always taken. File offset = VA − `0x10000000`.

  | Function | VA of the `sltiu` |
  |---|---|
  | `rex3ReadImage` | `0x103f86e4` |
  | `rex3ReadImage24` | `0x103114d0` |
  | `rex3ReadImage12` | `0x1030fad8` |
  | `rex3DrawImage` | `0x100b0910` |
  | `rex3DrawImage24` | `0x102dd52c` |
  | `rex3DrawImage12` | `0x102ddef4` |

  The branch sense was checked for the ReadImage routines; for DrawImage it is *(inferred)*, so confirm the
  `bnez` target is the PIO path before patching. GL's DMA paths are separate and would need their own patch.
- **Making `Ng1PixelDma` return EINVAL** avoids the hang, but the image contents come back empty.

## 5. Graphics context switch

- **Lazy.** `newportPcxSwitch`, `Suspend` and `Resume` are stubs returning 0. When a different graphics process
  touches the mapping it takes a page fault (`gfx_fault`; `newportInvalTLB` is the invalidate hook) and the kernel
  runs **`newportPcxSwap`**:
  1. spin GFXBUSY
  2. **read back ~48 REX3 registers**: `0x0–0x2c`, `0x100–0x134`, `0x200–0x220`, `0x230/0x234` (HOSTRW),
     `0x1300–0x131c`, `0x1324`, `0x1328`, CONFIG `0x1330`, and DCBMODE after a BACKBUSY spin
  3. write the new context's ~48 registers
  4. spin again
- So a model must return **coherent readback for all of those registers**, not just status.

## 6. What a henry implementation must provide

| Requirement | Why |
|---|---|
| Accept `sw`, `sd`, `sh`, `sb`/`lbu`, `swc1` to the REX3 window | n32 GL uses `sd` and `swc1`; DCB is byte/halfword |
| Deep posted-write path | ~99.9% of traffic is stores, 2–15 per primitive, no reads |
| STATUS read-to-clear on every read; USTATUS non-destructive | kernel polls STATUS outside the ISR |
| GFXBUSY / BACKBUSY that really reflect pending work | finish, ReadImage, DCB and init spin on them |
| HOSTRW readback (PIO GetImage) | one read per word, round-trip bound |
| Readback of ~48 registers | lazy context switch |
| **MC graphics DMA** (registers + TLB walk above) **and its completion interrupt** (IOC Local0 bit 4), or the Xsgi PIO patch | Xsgi/GL GetImage ≥ 7000 px and PutImage ≥ 16384 px; no fallback |
| Vertical-retrace interrupt (~60 Hz: IOC Local1 bit 7; the handler also checks REX3 STATUS VRINT `0x20`) | buffer swaps, cursor, gamma run from `newportRetraceHandler` |
| FIFO-full interrupt | optional if the queue never overflows |

The measured access rates (QEMU, icount-stamped) and the ARM-hybrid recommendation are in
`NEWPORT_FEASIBILITY.md` and the project memory note on Newport feasibility.
