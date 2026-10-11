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
   | `0x2034` | DMA_MODE | `0x50` draw (memory→GIO), `0x52` read (GIO→memory); bit 1 = direction |
   | `0x2014` | DMA_SIZE | `rows << 16 \| bytes per line` |
   | `0x201c` | DMA_STRIDE | `zoom << 16 \| stride` |
   | `0x202c` | DMA_GIO_ADRS | GIO address; **this write starts the transfer** |

6. **Wait for completion:**
   - with **`ng1intrena` = 1** (the default; the variable is at `0x882f6ba0`): `setlclvector(4, ng1_dma_intr)`,
     arm `ng1dmatimer`, and `sv_wait` on **`ng1dmaintr`** (`0x882f7e08`)
   - with `ng1intrena` = 0: `MCdma` clears the interrupt enable and waits synchronously (polls the DMA run bit)
7. Strides `≥ 0x8000` take a separate `fakePICdma` path.

### Why `xwd` hung under QEMU

QEMU's IP22 model never raises the MC DMA-complete interrupt (local vector 4), so Xsgi sleeps forever on
`ng1dmaintr` the first time a GetImage reaches 7000 pixels.

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
| **MC graphics DMA** (registers above) **and its completion interrupt** (local vector 4), or the Xsgi PIO patch | Xsgi/GL GetImage ≥ 7000 px and PutImage ≥ 16384 px; no fallback |
| Vertical-retrace interrupt (~60 Hz, STATUS VRINT `0x20`) | buffer swaps, cursor, gamma run from `newportRetraceHandler` |
| FIFO-full interrupt | optional if the queue never overflows |

The measured access rates (QEMU, icount-stamped) and the ARM-hybrid recommendation are in
`NEWPORT_FEASIBILITY.md` and the project memory note on Newport feasibility.
