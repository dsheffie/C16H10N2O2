---
title: Cache, coherence & TLB
status: draft (MAME-validated; silicon-refined 2026-07; RTL state re-checked 2026-10-27 against henry eea6ecb / r9999 788c412)
---

# Cache, coherence & TLB

> Henry's caches are incoherent: r9999's L1i is **not** kept in sync with D-side stores, and the L2,
> while transparent, is hidden from software (`Config.SC=1` → kernel sees "R4000PC").
> DMA masters — HPC3 (SCSI/Ethernet) and the MC's VDMA graphics engine — are **NON-coherent in
> hardware** on a uniprocessor R4000 (HW snoop is R4000MP-only). So the `cache` instruction is
> load-bearing: software coherence is mandatory, and r9999 must **honor specific cache ops, not NOP
> them**. The IRIX-behavior facts below (op histograms, routing obligations) were measured by booting
> real IRIX 6.5.22 in MAME (`indy_4610`, `-nodrc` interpreter). On henry **silicon**, the guest's own
> cache ops are not enough because of the hidden L2. That was first closed by **ARM-requested page
> flushes** (XPG, 2026-07 to 10-14 — see [DMA coherence on silicon](#dma-coherence-on-silicon-arm-requested-flushes-xpg)).
> Today all device DMA goes through henry's `dma_engine`, whose guest-memory accesses **snoop the
> inclusive L2** through `dma_snoop_shim` (see [Inclusive L2](#inclusive-l2-and-alias-tracking-proven-in-murphi-first)
> and [ARM device protocol](arm-device-protocol.md)).

## The r9999 memory hierarchy today (r9999 `788c412`)

What the core in the `r9999` submodule actually builds (defaults in `machine.vh`; henry's
`gen_mipscore.sh` adds only `ENABLE_DEBUG_WATCHPOINT`):

| Structure | Current RTL | Where |
|---|---|---|
| L1I | 32 KB, 2-way (2 × 1024 sets, 1-bit LRU), 16 B lines (`LG_L1I_NUM_SETS=10`); I-side CACHE ops invalidate one set | `l1i.sv`, `machine.vh` |
| L1D | 16 KB direct-mapped, 16 B lines (`LG_L1D_NUM_SETS=10`, `LG_L1D_CL_LEN=4`), **VA-indexed** (2 colour bits); **non-blocking** misses through an 8-entry memory/retry queue (`LG_MRQ_ENTRIES=3`); holds the payload half of the LSU store buffer | `l1d.sv` |
| LSU | age-ordered memory scheduler (`LG_MEM_SCHED_ENTRIES=3`): simple loads held until answered, stores held until retired and written; store→load forwarding from the store buffer | `exec.sv`, `l1d.sv` (`lsu_sb`) |
| L2 | **128 KB** write-back, 16 B lines, direct-mapped (`LG_L2_NUM_SETS=13`); **inclusive** of the L1D: per-line presence (`pd`) and colour (`pidx`), a back-invalidate probe of the L1D before evicting a `pd` line, synonym probes, and a write-back-and-invalidate snoop for DMA (`INCLUSIVE_L2_PROTOCOL.md`); `l2_nocache` (AXI control reg bit 20, set before `go`) turns it into a pass-through | `l2.sv` |
| JTLB | 48 dual entries (`N_TLB_ENTRIES=48`, architecturally fixed for IRIX), full Sail `R`+`va[39:13]` match with **variable PageMask**; stores only `TLB_PA_WIDTH=30` PA bits, zero-filled to `PA_WIDTH=36` (r9999 `c24d139`, `50d753c`); one copy as the D-side `dtlb`, one inside `itlb.sv` | `tlb.sv:158-181`, `itlb.sv` |
| micro-ITLB | 2 entries (`N_UITLB_ENTRIES=2`) in front of the I-side JTLB; honors PageMask; flushed on TLBWR/TLBWI and ASID change | `itlb.sv` |
| Config / PRId | `Config = 0x0002e483` (SC=1, IB=0, DB=0 → 16 B I and D lines), `PRId = 0x00000440` (R4400) | `exec.sv` CP0 r16, `machine.vh` `PRID_VALUE` |

Uncached-by-TLB user loads (a kuseg page whose EntryLo C bit says uncached) only issue at the ROB
head (r9999 `f8dabd4`), and CP0 writes commit at retire with all CP0 ops totally ordered (r9999
`94e5e97`) — both matter for the TLB-refill and device paths below.

## The coherence contract

Two independent coherence axes, both software-managed:

1. **I-cache vs D-side stores (code writes).** The kernel writes instructions through L1d/L2 and the
   L1i then holds a stale copy. Sources of code writes on the boot path:
   - **Runtime CPU patching** at boot — `R4000_jump_war`, `mtext_fixup_inst`, the UTLB-vector patches
     (`need_utlbmiss_patch`/`utlbmiss_patched`).
   - **Loadable kernel modules** — `doelfrelocs` relocating module text after load.
   - Re-patch of already-executed code (the case early boot can't get lucky on).
   r9999's L1D is write-back, so the patched line first has to leave the L1D (the D-side writeback op
   in the kernel's I-sync sequence). After that, a *cold* L1i fetch pulls the patched line from L2 or
   DRAM correctly; the failure mode is a line that was already resident in L1i before the patch.
   **⇒ I-cache `cache` ops MUST flush L1i.**

2. **D-cache vs DMA.** HPC3 and VDMA master directly to/from physical DRAM with no snoop. The driver
   issues the coherence ops by hand:
   - **DMA-in** (device → memory): `cache Hit-Invalidate-D` *after* the transfer — invalidate the stale
     cached copy **without** writeback.
   - **DMA-out** (memory → device): `cache Hit-Writeback-Invalidate-D` *before* the transfer — push
     dirty lines to DRAM so the device reads current data.
   This split is **architecturally mandated** (vdma.pdf p.1–2,7; hpc3.pdf has zero coherence language),
   not an IRIX quirk. r9999 still executes these ops as specified (see routing table). On henry the
   device data is written by `dma_engine`, and each of its guest-memory accesses is also bracketed by
   a write-back-and-invalidate snoop of the core's L2 and L1D (`rtl/dma_snoop_shim.sv`), so henry's
   DMA is coherent in hardware as well. Before the snooped engine (to 2026-10-14) the ARM deposited
   the data behind the caches and the invalidate-vs-writeback distinction was correctness-critical.

!!! note "External corroboration (independent R4000SC implementation)"

    **haterMIPS** — Project CYAN's clean-room R4000SC core for the SGI Indigo **IP20** (see
    [methodology → related work](methodology.md#related-work)) — reaches the **same** conclusion from the
    CPU side: self-modifying code only works when software issues the full `CACHE` sequence —
    **D-cache Hit-Writeback-Invalidate + I-cache Hit-Invalidate** — exactly axes 1 and 2 above. Its `Config`
    reports `SC=0/SB=11` (a 1 MB / 128 B-line secondary cache) and it implements I$/D$ coherency *only* via
    those `CACHE` ops, no snoop. Two independent implementations agreeing the `cache` op is **load-bearing,
    not NOP-able** is strong evidence the model is right.

!!! question "FAQ: Do we need snoops (hardware cache coherence) in r9999? — **Not for IRIX** (henry added a DMA snoop anyway; see below)"

    Snooping is a **multiprocessor / coherent-DMA** feature: it exists to keep one cache coherent with another
    bus agent (a second CPU or a snooping DMA engine). The real IP22 is a **uniprocessor** with
    **non-coherent DMA**, so there is no other agent to snoop and nothing to build. The whole platform does
    **software** cache coherence instead — which is exactly the contract above.

    The evidence is unanimous:

    - **HPC3** (the real SCSI/Ethernet DMA path) has **zero snoop hardware** — it just masters the bus to/from
      physical DRAM; coherence is the driver's job (hpc3.pdf has no coherence language).
    - **VDMA**'s snoop is **R4000MP-only** — a per-transfer `GIO_MODE[5]` bit that exists only on the
      multiprocessor part; on a uniprocessor R4000PC/SC (what r9999 presents as) it is never used, and the
      kernel software-flushes instead (vdma.pdf p.1–2). The MC's `CPUCTRL0.SNOOP_EN` bit is for that same
      MP graphics-DMA path → Henry treats it as a no-op storage bit.
    - **IRIX confirms it dynamically:** the ~5.2M `cache` ops/boot we measured *are* the software coherence —
      the kernel would not issue them if hardware snooped.

    **What r9999 needs *instead* of snoops** is just to **execute the software cache-management ops correctly
    (not NOP them)** — drive the L1i flush on I-cache invalidate (code coherence), and invalidate-*without*-
    writeback on `Hit-Invalidate-D` (DMA-in). See the routing table below. Not building snoop logic is a
    genuine **simplification**, not a shortcut.

    > ⚠️ **Refined by silicon: there IS a second obligation.** Because
    > r9999 has a **hidden L2** (unlike the real Indy), executing the guest's *primary* cache ops isn't
    > enough — a speculatively filled stale line can survive for a buffer IRIX never issued a CACHE op
    > for. The 2026-07 plan was `Config.SC=0` so IRIX would issue its secondary invalidates; that was
    > **never built** (Config still reports SC=1). The first fix kept the "no snoops" model and
    > moved the extra obligation to the **ARM host**, which owned the disk/network deposits: before and
    > after each transfer it asked the core to write back / drop the affected pages (XPG). See
    > [DMA coherence on silicon](#dma-coherence-on-silicon-arm-requested-flushes-xpg). Since
    > 2026-10-14 henry does have a **DMA snoop**: the L2 became inclusive of the L1D, and every device
    > access is write-back-and-invalidate snooped through it (`dma_snoop_shim`), so the ARM flushes
    > are gone.

    Snoops would only ever be needed if Henry went **multiprocessor** (multiple r9999 cores sharing memory) or
    chose to model **coherent DMA hardware**. Henry took the second route in 2026-10 to cover the hidden
    L2 (above). It diverges from the real IP22, but IRIX cannot tell: its own cache ops still run as
    specified.

## The `cache` instruction — decode & routing

r9999 must **fully decode `cache`** (opcode `0x2f`) and route by the op field — a blanket NOP is a
latent bug. Field decode of the op register field `op = instr[20:16]`:
`cache_sel = op[1:0]` (0=I-primary, 1=D-primary, 2=SD secondary-data, 3=SI secondary-instr);
`operation = op[4:2]`. **Implemented** in `decode_mips.sv` (opcode `6'd47`), in two paths:

- **Primary-D Hit ops** (`0x11` Hit-Invalidate, `0x15` Hit-WB-Invalidate, `0x19` Hit-WB) are
  **memory uops** `CHINV` / `CHWBINV` / `CHWB`: AGU → LSU → `l1d`, where the **dtlb translates the
  EA** (IRIX invalidates *mapped* K2SEG buffer-cache lines; the older funnel masked `VA & 0x1fffffff`,
  wrong for mapped EAs). The L1D admits one only when it is non-speculative (ROB head).
  - `CHINV`: drop the L1D line **without** writeback, then send `MEM_INVL` to the L2.
  - `CHWBINV` / `CHWB` (CHWB is treated as WB-invalidate): a dirty L1D hit goes to DRAM via
    `MEM_WB` (the L2 copy is dropped); otherwise drop any L1D copy and send `MEM_INVL`.
  - In `l2.sv`, `MEM_INVL` **writes a dirty L2 line back to DRAM, then drops it** (an L1D eviction
    may have left the only valid copy there). `machine.vh`'s enum comment still says "no writeback";
    the handler is authoritative.
- **Every other kernel-mode CACHE op** is a serializing `CACHE_OP` executed at the ROB head
  (`core.sv` `WAIT_FOR_SERIALIZE_AND_RESTART` → `CACHE_FLUSH`): any **I-side** op invalidates the one
  L1I set its EA indexes, both ways (r9999 `93b1514`; it was a whole-L1I flush); any **D-side** op
  (incl. the Index ops and, because `insn[16]=1`, the SD/SI ops) does a per-line `flush_cl` at
  `EA & 0x1fffffff`. Every D op acts on exactly the one 16 B line containing its EA (r9999
  `76a77a2` removed the old 32 B "double beat").
- **User mode:** CACHE decodes to Coprocessor Unusable.

**Boot histogram** — C++ instrumentation on MAME's mips3 `case 0x2f`, **5,208,585 cache ops over a
120 s boot**:

| op   | cache / operation                  | boot count  | %      |
|------|------------------------------------|-------------|--------|
| 0x01 | D Index-Writeback-Invalidate       | 1,483,598   | 28.5%  |
| 0x00 | I Index-Invalidate                 | 1,481,976   | 28.5%  |
| 0x15 | D Hit-Writeback-Invalidate         | 1,400,427   | 26.9%  |
| 0x10 | I Hit-Invalidate                   | 839,506     | 16.1%  |
| 0x08 / 0x09 | I/D Index-Store-Tag (cache init) | 1,025 / 1,025 | —    |
| 0x14 | I Fill                             | 512         | —      |
| 0x11 | **D Hit-Invalidate (NO writeback)**| 489         | —      |
| 0x19 | D Hit-Writeback                    | 21          | —      |
| 0x0b | secondary Index-Store-Tag (L2 probe) | 6         | —      |

**Four primary-cache ops = 99.94%.** Secondary/L2 ops are ~0 (just a 6-hit probe). This Indy has no
L2 visible to software (`Config.SC=1`), so the ~30 static `cache_sel=2/3` code sites never execute —
**no L2 modeling needed** *on the real Indy*.

> ⚠️ **True for the real Indy, NOT for r9999.** r9999 *has* a hidden L2 but still reports `Config.SC=1`,
> so IRIX skips those secondary (`cache_sel=2/3`) ops. r9999 compensates by carrying every primary
> D-side op through to the L2 (above), and henry snoops the L2 on every device DMA access (earlier,
> the ARM-requested XPG page flushes did this job). See
> [r9999's hidden L2 and the DMA-coherence gap](#r9999s-hidden-l2-and-the-dma-coherence-gap-silicon-2026-07).

**Routing table — MAME-derived obligation vs what r9999 does today:**

| op | name | cache_sel | obligation (from MAME) | r9999 today |
|----|------|-----------|------------------------|-------------|
| 0x10 | I Hit-Invalidate | I | **MUST flush L1i** (code coherence) | invalidate the indexed L1I set (both ways) |
| 0x00 | I Index-Invalidate | I | **MUST flush L1i** | invalidate the indexed L1I set (both ways) |
| any I-side op | — | I | L1i is never dirty → invalidating the indexed set correctly over-approximates every I-cache op | indexed-set invalidate (`0x08` Index-Store-Tag and `0x14` Fill included) |
| 0x11 | **D Hit-Invalidate (NO writeback)** | D | invalidate WITHOUT writeback (DMA-in). **Do NOT promote to writeback** or a stale line overwrites fresh DMA data | `CHINV`: L1D drop, no WB; L2 `MEM_INVL` |
| 0x15 | D Hit-Writeback-Invalidate | D | writeback + invalidate (DMA-out) | `CHWBINV` |
| 0x19 | D Hit-Writeback | D | writeback | `CHWB` (as WB-invalidate) |
| 0x01 | D Index-Writeback-Invalidate | D | writeback + invalidate | serializing per-line `flush_cl` |
| 0x09 | D Index-Store-Tag | D | no-op is enough: caches reset clean, size comes from `Config` | per-line `flush_cl` (writeback; harmless) |
| 0x0b | SI Index-Store-Tag | SI (L2) | no-op is enough: no software-visible L2 | decoded as a D-side `flush_cl` (`insn[16]=1`; harmless) |

> ⚠️ The MAME-era conclusion that the D-side ops were "NOP-safe while I/O stays backdoored" is
> **obsolete**: it held only for the real Indy (no L2) with no DMA behind the caches. On henry the
> L2 is real and the SCSI/ENET deposits land behind it, so every D op above is load-bearing.

## r9999's hidden L2 and the DMA-coherence gap (silicon, 2026-07)

> **⚠️ UPDATE (2026-10-27): the gap is closed by CACHE-op forwarding plus a DMA snoop of the
> inclusive L2; `SC=0` was never built.**
>
> 1. **CACHE-op forwarding (2026-07).** `l1d.sv` forwards a D-side Hit-Invalidate to the **L2 even on
>    an L1D miss** (`MEM_INVL`, the "scrub the L2 copy" arm near `l1d.sv:3098`) and pushes a dirty
>    line through to DRAM with `MEM_WB`. So the primary-only `dma_cache_inv` that IRIX issues under
>    `Config.SC=1` *does* reach the hidden L2.
> 2. **DMA snoop (2026-10).** Forwarding only helps for buffers IRIX issues a CACHE op for; the kernel
>    cannot drop a stale L2 line for an address it never touched (`henry_soc.sv:314-319`). The L2 is
>    now inclusive of the L1D (r9999 `1079cf5`..`ff34709`), and every guest-memory access of henry's
>    `dma_engine` (SCSI, ENET TX/RX, MC VDMA) goes through `dma_snoop_shim`: a write-back-and-invalidate
>    snoop before the access and, for writes, again after it (`rtl/dma_snoop_shim.sv`,
>    `henry_soc.sv:1141-1175`). The one unsnooped writer is the MC's FILL engine, used only for the
>    PROM's uncached power-on memory clear (`mc.sv:64-69`). See [Inclusive L2](#inclusive-l2-and-alias-tracking-proven-in-murphi-first).
> 3. **ARM-requested page flushes (XPG)** did this job from 2026-07 until the staging rings
>    (henry `a0d5e1e`, 2026-10-14). The RTL is still there, but the ARM no longer touches guest memory
>    and no longer flushes — see [DMA coherence on silicon](#dma-coherence-on-silicon-arm-requested-flushes-xpg).
>
> The `SC=0` / snoop-FIFO / head-of-ROB-fence / NOCACHE forensics below are kept as history. The old
> DMA→L2 snoop FIFO (`snoop_fifo.sv`) is no longer instantiated in `henry_soc.sv`. The NOCACHE bypass
> is now a run-time bit (`l2_nocache`, AXI control bit 20), not a `define`.

> **The single most important divergence from the real IP22.** r9999 has a **transparent write-back
> L2** (128 KB, **16-byte lines**, `LG_L2_NUM_SETS=13`) between L1 and DRAM. The real Indy has **no L2**
> and says so (`Config.SC=1`). r9999 **also** reports `Config.SC=1` (`exec.sv` returns `Config=0x0002e483`),
> so IRIX believes there is no secondary cache — but the L2 is physically there, caching lines the
> kernel doesn't know it must invalidate. On silicon with the real SCSI DMA path, this is a genuine
> **non-coherent-DMA bug** the MAME/real-Indy analysis above could never see (real Indy: no L2 → nothing
> to go stale).

### The bug it causes

IRIX 6.5 boots on henry silicon to the kernel banner, "coming up", and reconfigure — then **every
`/etc/rc2` o32 process dies with `Memory fault(coredump)`** (and `cc`'s backend bus-errors during the
kernel reconfigure). Root cause: **R10000-class speculative non-coherent DMA**. The OOO core
speculatively pulls a DMA read-buffer line into cache; the SCSI DMA overwrites DRAM behind it; IRIX
never invalidates the **hidden L2** copy (see below); a later read gets the stale line → bad pointer →
fault. **Proven in `interp_mips`:** a spec-fill cache model reproduces it (16 stale reads → boot dies);
adding a coherent-DMA invalidate → 0 stale reads, clean. The on-disk image is **not** corrupted
(rsync `--checksum` identical to pristine) — the corruption is purely *live* in-memory stale reads.

### Why IRIX never invalidates the L2 — confirmed in IRIX's own binary (Ghidra)

Decompiling the extracted IRIX kernel objects (`~/code/iris/IP22boot/*.o`, unstripped N32/DWARF) settled
this definitively. `kernel.o :: __dcache_inval`:

```c
scache_size = *(uint *)(zero + -0x5d50);        // the detected secondary-cache size
if (scache_size != 0 && flag == 0) {            // ONLY if a secondary cache exists:
    cacheOp(0x03, addr);   // Index_WB_Invalidate_SD   (cache_sel=11 = Secondary Data)
    cacheOp(0x17, addr);   // Hit_WB_Invalidate_SD
    cacheOp(0x13, addr);   // Hit_Invalidate_SD    <-- THE L2 INVALIDATE
    // stride 0x80 (128-byte secondary line)
}
// else -> primary-cache ops only  (r9999's case, because scache_size == 0)
```

So **IRIX has a complete, correct secondary-cache invalidate path** — it just gates it on
`scache_size != 0`. Because r9999 reports `Config.SC=1`, `config_cache`/`size_2nd_cache` set
`scache_size = 0`, so `__dcache_inval` runs **primary-only** and the L2 is **never** invalidated.

**And IRIX genuinely tries to sync its DMA buffers** — `dksc.o` (the SCSI disk driver) does the
textbook, even R10000-*speculation-safe* pattern:

```c
if (read)  dki_dcache_inval(buf, len);   // PRE-DMA invalidate
else       dki_dcache_wb(buf, len);      // PRE-DMA writeback (DMA-out)
dk_sendcmd(...);  dk_chkcond(...);        // issue DMA + wait for completion
if (read)  dki_dcache_inval(buf, len);   // POST-DMA invalidate (the speculation-safe flush!)
```

Every one of those calls flows into `__dcache_inval` → primary-only → **misses the L2**. IRIX is doing
the *right* software; r9999 just hid the cache it needs to reach.

### The secondary-cache probe (what `SC=0` must satisfy)

`config_cache` → `size_2nd_cache` is **PRId-dispatched** and reads `Config`/`PRId`:
- **R4600** (`imp 0x2000`): reads an IP22 system register `0xbfa00034` for the secondary size.
- **R4600 `0x2300` variant**: `Config`-based (SC bit + size field) **plus** a cache-aliasing probe
  (`cache 0x08/0x09/0x0b` = `Index_Store/Load_Tag_SD` + tag reads).
- **R4000/R4400**: `Config`-based secondary detect (simpler — no IP22-register / aliasing probe).

Then `_r4600sc_enable_scache` writes `Config`/`TagLo` (`mtc0`) to turn it on. **Line size is hard-coded
128 B** (`config_cache` does `li 127 -> scache_linemask`; the op loops use immediate `128`/`0x7f`
strides) — **not** detected, so it can't be reconfigured to r9999's 16 B; the RTL must bridge it.

### ⚠️ PRId mismatch (RTL vs ISS)

- **RTL / silicon: `PRID_R4400` = 0x00000440** (`machine.vh:354`, selected by `PRID_VALUE` at `:364`).
- **Standalone `interp_mips`: now also R4400** by default (`interp_mips/interpret.hh:411`), with a
  `PRID=<val>` env override (`interpret.cc:299`) and `--cpu r5000`.
- **The ISS embedded in the r9999 submodule** (the one `henry_tb --checker` and `ooo_core -c` co-sim
  against) **now also says R4400** (`r9999/interpret.hh:391`, r9999 `5ac82f0`; it was `PRID_R4600`
  = 0x2020).

**Silicon presents R4400**, so it takes the **simpler `Config`-based** secondary-detect path (not the
R4600 `0xbfa00034`/aliasing probe). The mismatch is resolved: all three agree on R4400.

### Fix options + silicon results (2026-07 session; status updated 2026-10)

| approach | idea | silicon result / status today |
|---|---|---|
| **`SC=0`** | Advertise the L2 as an R4x00 secondary cache (flip `Config.SC=0`, satisfy the R4400 probe) + an **8-beat SD-op handler** (128 B / 16 B → drop/WB 8 lines). Lets IRIX's *own* invalidates reach the L2. | **Never built.** Config still reports SC=1. |
| DMA→L2 snoop | Arbiter emits a snoop on each DMA store → L2 invalidates the line. | **Corrupted** silicon in 2026-07 (over-invalidated live/dirty lines). That FIFO (`snoop_fifo.sv`) is no longer instantiated. Its successor ships: a write-back-and-invalidate snoop of the now-inclusive L2, issued by `dma_snoop_shim` around every DMA access. |
| Head-of-ROB fence | Serialize every cached load/store to ROB head (no speculative fill). `l1d.sv ENABLE_MEM_HEAD_SERIALIZE`. | **Partial** at the time; the `define` still exists, off. |
| Tiny L2 (`LG_L2_NUM_SETS=2`) | 4-line L2, ~no retention. | `cc` bus-error at reconfigure — confounded; not it. (`ENABLE_L2_TINY` still exists, off.) |
| NOCACHE bypass | Route data ops (opcode < 24) straight to DRAM so the L2 holds **nothing**; CACHE-management ops (≥ 24) keep their handlers. | Now the run-time `l2_nocache` input (AXI control bit 20, `l2.sv:80-86`), off by default. |
| **ARM-requested flush (XPG)** | The ARM host, which performs every disk/network deposit, asks the core to write back + invalidate (before) or drop (after) the buffer pages. | Shipped 2026-07 to 2026-10-14 and was required for IRIX on silicon then. The RTL remains; the rings-only driver no longer uses it. See the next section. |

The 2026-07 conclusion was that the first five *substitute* for a coherence mechanism IRIX already
has (its SD ops). XPG took a different route: it put the obligation on the agent that knew exactly
which pages a device wrote. The inclusive-L2 snoop that replaced it puts the obligation on the DMA
engine, which knows each line it touches.

### Artifacts

- **Ghidra decompiles** (Java `DecompDump` script — Ghidra 12.1 needs Java, not PyGhidra):
  `~/code/iris/{kernel,dksc,wd93,scsi,scsiha,hpc3plp}_decomp.c`.
- IRIX kernel objects: `~/code/iris/IP22boot/*.o` (unstripped, DWARF). Disassemble with
  `mips-linux-gnu-objdump -d -EB`.

## DMA coherence on silicon: ARM-requested flushes (XPG)

!!! note "History (2026-07 to 2026-10-14)"

    This was henry's DMA-coherence mechanism until the staging rings (henry `a0d5e1e`, rings-only
    `4bc57b4`). Since then the ARM never touches guest memory after boot, device DMA is snooped through
    the inclusive L2, and the driver no longer issues these flushes
    ([ARM device protocol](arm-device-protocol.md)). The RTL below is still in `henry_soc.sv` and the
    core.

On the FPGA, the Zynq ARM served the SCSI disk and the Ethernet tap. It wrote guest DRAM behind the
caches, so it was the agent that knew exactly which pages a transfer touched. It asked the core to
clean those pages around each transfer. **IRIX boots on silicon had to run the board driver in this
mode** (the `axilite-mips-xpg` driver with `EXTFLUSH=1 XFPAGES=1`; that driver lives on the board,
not in this repo).

**SoC/AXI interface** (`rtl/henry_soc.sv:214-224, 327-480`, `ip_hdl/axi_is_the_worst_v1_0_S00_AXI.v`):

| what | AXI | henry_soc port |
|---|---|---|
| whole-cache flush (a 0→1 edge starts one) | control reg (`slv_reg4`) bit 2 | `ext_flush_ctl` |
| append a physical page number to the list | write reg `0x3C` | `ext_pg_push` / `ext_pg_ppn` |
| walk the list; bit 0 of reg `0x3D` = drop | write reg `0x3D` | `ext_pg_go` / `ext_pg_drop` |
| status: flushes completed, page-drop dirty lines, busy | read `0x25` | `ext_flush_stat` |
| cycles the last flush / list took | read `0x24` | `ext_flush_cycles` |

The list holds 16 pages (`N_XF_PAGES`). A longer list sets overflow, and `go` then does the whole
flush instead, which is always correct. `go` issues one `ext_flush_req` per page and reports a single
completion at the end.

**How the core runs it** (`core.sv` `ext_flush_*` / `r_xflush_*`, `uop.vh` `XFLUSH`/`XPG_*`):

1. `ext_flush_req` latches the page, the whole-cache flag and the drop flag (`r_xflush_ppn/_whole/_drop`).
2. Like an IRQ, decode replaces the next **non-delay-slot** instruction with a serializing injected
   uop: `XFLUSH` (whole), `XPG_WBINV` (page, before a transfer) or `XPG_INV` (page, after a deposit).
   These are not architectural instructions and never count as retired.
3. At the ROB head (`WAIT_FOR_SERIALIZE_AND_RESTART`, core drained):
   - `XFLUSH`: whole-L1D flush; the sequencer then chains the L2 flush.
   - `XPG_*`: `flush_pg_req` makes the L1D walk the page's 256 lines (`FLUSH_PG` / `FLUSH_PG_WAIT`):
     - **WBINV:** a dirty L1D hit → `MEM_WB` (to DRAM, L2 copy dropped); otherwise invalidate any
       L1D hit and send `MEM_INVL` (the L2 writes back if dirty, then drops).
     - **INV:** invalidate any L1D hit and send `MEM_PGDROP` (the L2 drops the line *without*
       writeback). A dirty line found here is counted in `pg_drop_dirty_cnt` (AXI `0x25`); a correctly
       pre-cleaned page has none, so a nonzero count means a coherence bug.
4. The flush completes, the core restarts at the injected uop's own PC, and `ext_flush_done` pulses.

!!! warning "Every L1D flush starts only from a fully drained L1D (r9999 `5c89b70`, 2026-10-04)"

    `l1d.sv` defines `w_l1d_drained` = memory queue empty, nothing owed (`r_n_inflight == 0`),
    both pipe stages empty, and **no retired store still waiting to be written**. All four flush
    arms (CACHE flush, CACHE line op, XPG page op, DMA invalidate) wait for it (`l1d.sv:2490,
    3382-3415`). Before this fix, an XPG page flush that armed in the same cycle as a port-1 miss or a
    port-2 direct fill overwrote `n_state`. The fill's response was consumed as a flush beat, so the
    load was never answered and its `{color,rob}` inflight bit leaked. The next `(EXCEPTION_)DRAIN`
    then waited on that color forever: this was the IRIX `EXCEPTION_DRAIN` hang on silicon. The XPG
    and DMA-invalidate arms also skipped the retired-store drain, so a retired store to the page could
    land after the page flush.

**In simulation**, `sim/henry_tb.cpp` injects the same traffic: `--extflush N` raises the whole-cache
flush every N cycles, and `--xfpages base,n,drop` turns each period into an `n`-page list walk with
`go` (drop=1 → `XPG_INV`, 0 → `XPG_WBINV`).

(`l1d.sv` also has a separate per-line `dma_inval_req` port into the same invalidate machinery.
`henry_soc.sv` does not connect it. Device DMA coherence today comes from the L2 snoop port,
described next.)

## Inclusive L2 and alias tracking — proven in Murphi first

Since r9999 `1079cf5`..`d2baf87` the L2 is **inclusive of the L1D**, and the L1D is **VA-indexed**. Together they close the two gaps described above: a device snoop only needs to ask the L2, and the L2 always knows where in the L1D a line can be.

**What the RTL does** (spec: `r9999/INCLUSIVE_L2_PROTOCOL.md`):
- **Presence and colour per L2 line.** `pd` = "the L1D may hold this line"; `pidx` = the L1D colour it was filled at (the index bits above the 4 KB page offset, 2 bits for the 16 KB L1D). Every L1D→L2 request carries its colour.
- **Back-invalidate before eviction.** Before the L2 evicts a `pd` line, whichever cache caused the miss, it probes the L1D at `pidx`. The L1D invalidates its copy and returns it if dirty, and that data becomes the victim writeback.
- **Synonyms are pushed out, not pulled.** An L1D request that hits a `pd` line held under a different colour probes the old colour first, so the L1D never holds two copies of one physical line. This is the R10000's PIdx scheme (user's manual §5.5).
- **Probes have their own reply channel.** The probe ack never depends on the L1D's own pending request. A request that would make it wait, the "blocked handshake", deadlocked the August 2026 design.
- **DMA snoop.** The external snoop port's write-back-and-invalidate mode probes the L1D the same way, then writes back whichever copy is dirty. A same-line writeback already latched in the arbiter is absorbed rather than lost.

**Proven before it was built.** Each step was modelled and exhaustively checked in Murphi (CMurphi 5.4.9, cross-checked with Rumur) before the RTL changed. The models are in `r9999/formal/murphi/`:

| model | covers |
|---|---|
| `r9999_main.m` | the pre-inclusion hierarchy (main `3b78e9b`), extracted from the RTL; shows inclusion breaks only *across* caches (L1I misses evicting L1D lines) |
| `r9999_incl.m` | inclusive L2 with back-invalidate probes, presence bits and DMA snoop. Generated from `r9999_main.m` by `gen/make_incl.py` and its passes (`presence.py`, `dmasnoop.py`, …) |
| `r9999_va.m` | VA-indexed L1D with one line per colour; every access picks a colour nondeterministically, synonyms included; push (`ALIAS_PULL=0`, the RTL) and pull variants |
| `r9999_nb.m`, `r9999_dma.m`, `r9999_pagewalk.m` | the probe protocol with a non-blocking L2; DMA coherence options; the ARM-injected page-flush (XPG) ordering |

Results, all with no error found:
- **Pairs of agents at 2 values per location:**
  - data side: 14.2M states
  - data + DMA: 569M states
  - data + L1I: 447M states
- **Full model at 1 value:** L1I + DMA + speculative fill, 549M states.
- **With presence bits:** L1I + DMA, 3.77B states, and L1I alone, 4.38B states (bit-state hashing, 32 GB).
- **DMA snoop with presence bits:** 938M states.
- **VA alias tracking:** push 436M states, pull 980M states.

The 2-value runs are needed because the 1-value full model can't see two-write bugs.

**Negative controls make the checks trustworthy.** Every model carries `BUG_*` knobs that re-introduce a real or historical bug, and each must **fail**; a passing negative control means the check is blind. Among them:
- the August blocking probe handshake (`BUG_PROBE_BLOCKED`, deadlocks);
- the fill-vs-probe race;
- dropping a dirty victim;
- skipping the alias check (two copies);
- dropping a dirty alias (stale load);
- not updating `pidx`;
- a snoop that doesn't absorb a latched writeback (stale DMA-out). That race, D3, was **found by the model** and fixed in the RTL (`ff34709`).

**Then the RTL, in stages, each checked in simulation:**

| stage | commit | what |
|---|---|---|
| A | `1079cf5` | `pd` + `pidx` tracking only |
| B | `a8d5757` | back-invalidate probe |
| C1/C2a | `2ebb342`, `f767051` | line PA from the full tag; the request carries its set |
| C2b | `3913756` | VA-indexed L1D, push alias probes |
| snoop | `d2baf87` | write-back-and-invalidate snoop |
| D3 | `ff34709` | in-transit writeback capture |

Simulation checks after each stage:
- A periodic sim-only walk counts L1D lines missing from the L2, and lines with the wrong `pd`/`pidx`. Over Linux 100M instructions both counts were 0, against 1.5M missing lines before stage B.
- A `--snoop-delay` injector snoops every DRAM-read line N cycles later. CoreMark and mmap-alias checkpoints ran clean under the co-sim checker with up to 3.5M snoops.

On silicon, the VA-indexed inclusive design (C2b) passed a 24-round IRIX network + disk soak on 2026-10-11, at that point still with ARM-requested page flushes covering DMA. The first build with the snoop alone covering DMA (no flushes) was the staging-ring bitstream `0e7de40d`, which passed its own 24-round IRIX soak on 2026-10-14.

## TLB

!!! info "Full TLB datapath write-up"

    The detailed r9999 translation datapath — two-stage match/validity, the `r_tlb_written`
    (= Sail `entry.valid`) slot bit and the demand-paging refill→invalid→page-fault flow it
    enables, the `BadVAddr`/`Context`/`XContext` the refill handler reads, vector selection, and
    `mipsseg` segment decode — now lives in
    [r9999 microarchitecture → The TLB](r9999-microarchitecture.md#the-tlb-translation-datapath).
    **Two things below are superseded by it:** (1) the match is the full Sail-conformant
    `va[39:13]+R` compare, *not* the 19-bit `va[31:13]` workaround in "suspect #2"; (2) a slot is
    matched on the per-slot *written* bit, not `(v0|v1)` — the old `(v0|v1)` guard caused an
    infinite-refill livelock on the first userspace page (it excluded the demand-paging `v0=v1=0`
    entry, so the retry re-refilled instead of taking TLB-Invalid → `do_page_fault`).

- **Size:** 48 dual-entry JTLB — identical on R4000/R4400/R4600/R4700/R5000/RM (only R10000/R12000 go
  to 64). r9999's 48-entry CAM matches (`N_TLB_ENTRIES=48`; IRIX accepts no other value). `start` sets
  **`Wired=8`** (slots 0–7 reserved). The CAM is duplicated (D-side `dtlb` in `l1d.sv`, I-side copy
  inside `itlb.sv`), and a 2-entry **micro-ITLB** sits in front of the I-side copy to close timing.
- **Boot is 4 KB-only** (MAME): 3000 explicit TLB writes during boot → **100% `PageMask=0` (4 KB), zero
  large pages.** Large-page machinery (`large_pages_enable`, `lpage_*`) is on-demand/under-load, never
  triggered by a vanilla boot. r9999 now implements **variable-page-size matching anyway**: the JTLB
  masks VPN2 bits by `PageMask` (`tlb.sv:174`), and the micro-ITLB honors PageMask too (r9999
  `3b4a50e`; it was hardwired to 4 KB pages). **`PageMask` is NOT RAZ/WI** — the kernel writes
  `PageMask=0` before each `tlbw` and reads it back; it must hold its value.
- **R4000 vs R5000 refill (Henry = R4000 path):** R4000/R4600 fast refill is a **blind `tlbwr`** (load
  2 PTEs → `mtc0 entrylo0/1` → `tlbwr` → `eret`). R5000 does **`tlbp` first, `tlbwr` only if absent** (a
  guard against a duplicate TLB entry the R5000 mishandles). Henry presents **PRId imp `0x04`
  (R4400, `0x440`)**, so it gets the blind-`tlbwr` refill. The CAM must **tolerate a duplicate write**
  rather than raise a machine check; r9999 models no TLB-shutdown machine check.

## The wirepda / wired-entry finding

**MAME-confirmed (Q1, 2026-06-13): real HW takes NO miss at `wirepda`'s `jr $ra`; r9999 faulted
spuriously.** This was the VM-init bug that stranded r9999 ~805K cycles into boot.

!!! success "Resolved in RTL (r9999 `tlb.sv`, commit `e451d50`)"

    The root cause was **suspect #2** (high-VA match), now fixed; **suspect #1** (Random clamp) was
    refuted by RTL inspection. IRIX has since booted well past this point on henry silicon. Unit
    coverage exists (`tests/cheri/tlb/test_tlb_xkseg.s`, `test_tlb_wired.s`).

`wirepda` (@`0x881689b0`) `jal`s `tlbwired` (@`0x88004ba0`) to wire the per-CPU PDA. The golden wired
entry captured at the `tlbwi` inside `tlbwired` (0x88004c28):

```
EntryHi  = 0x00000000_FFFFA000   ; VPN2 for VA 0xFFFFFFFF_FFFFA000, ASID=0x00
EntryLo0 = 0x00000000_0020E39F   ; PFN=0x838E -> PA 0x0838E000; C=3 (cached), D=1, V=1, G=1 (GLOBAL)
EntryLo1 = 0x00000000_00000001   ; V=0 -> odd page INVALID; G=1
PageMask = 0                     ; 4 KB
Index    = 0     Wired = 8
```

So the **PDA is wired in slot 0**: VA `0xFFFFFFFF_FFFFA000` → PA `0x0838E000`, valid, dirty, cached,
**GLOBAL** (matches any ASID).

At the `jr $ra` (0x88168aec), single-stepped on real HW:
- The delay slot (`sw at,0xFFFFA240(zero)`) stores to **PDA+0x240** — hits the global wired entry,
  **no store miss**.
- Returns to **`0x8814a184`** (= `mlsetup+0xb4`, **kseg0 / UNMAPPED**) — clean, **no exception vector,
  Cause=0, no BadVAddr**.

**⇒ r9999 *was* faulting spuriously** — the fix was in r9999's TLB high-VA matching, NOT a missing
mapping (see the resolution box above). Generic xkseg/wired unit tests now exist
(`tests/cheri/tlb/test_tlb_xkseg.s`, `test_tlb_wired.s`), but a **directed regression test for the exact
wirepda scenario** — a *global wired high-kseg3* entry resolving an access *across ASID changes and `tlbwr`
churn* — is still worth adding, since the imported CHERI tests don't combine all three.

**Root cause & fix (the two original suspects, resolved):**

1. **Suspect #1 — `tlbwr` not clamping Random to `[Wired..47]`: REFUTED.** exec.sv resets
   `Random → N_TLB_ENTRIES-1` (47) on a `Wired` write, decrements it per retirement with wrap at `Wired`
   (`r_random==r_wired ? N_TLB_ENTRIES-1 : r_random-1`, exec.sv:4743-4756), and `TLBWR` writes index
   `r_random`. So `Random ∈ [Wired..47]` always and `tlbwr` can never overwrite the wired slots 0–7.
   *(CYAN's independent haterMIPS implements the same clamp.)*
2. **Suspect #2 — high kseg3 VA `0xFFFFFFFF_FFFFA000` never matched: ROOT CAUSE, FIXED.** The
   real asymmetry: `mtc0 EntryHi` stored `VPN2` **zero-extended**, while kseg VAs **sign-extend**
   (`va[63:62]=11`, `va[39:32]=ff`), so the wired high-VA entry never hit → spurious refill, EXL=1 spin.
   The first fix (`e451d50`) was a compare-side workaround that matched only the low 19-bit VPN2. It was
   **later replaced**: exec.sv now writes `EntryHi.R`/`VPN2` from the full GPR (per Sail MTC0), and
   `tlb.sv` does the full Sail `R` + `va[39:13]` match (`tlb.sv:158-181`). The low-19 arm had aliased
   the kptbl walk (which runs at KX=0) and caused an intermittent tlbmiss panic.

**Suggested directed test (golden values above):** set `Wired=8`; write the PDA entry
(EntryHi=0xFFFFA000, EntryLo0=0x20E39F, EntryLo1=0x00000001, PageMask=0) at Index 0; churn the TLB with
many `tlbwr` and change ASID; then **store to `0xFFFFFFFF_FFFFA240` and load it back** — must hit
PA `0x0838E240` with no miss. With the full Sail match in place this should **pass**; it guards against a
regression in the high-VA match (and would catch a re-introduction of the zero-extend asymmetry).

## CP0 timekeeping & misc

- **Steady-state timekeeping = on-chip `Count`/`Compare`** (not ARCS). The handler re-arms
  `Compare = Count + ~0x25000` per tick — confirmed live in MAME.
- **Status.FR (bit 26) IS used.** FR=0 for kernel/idle, **FR=1 once N32/N64 userland runs** (first seen
  mid-boot, ~19% of samples by multiuser). r9999's FP regfile must implement FR=1 (32 independent 64-bit
  registers), not just FR=0 even/odd 32-bit pairs; the FR bit must switch regfile aliasing. (Still no FP
  *arithmetic* in the kernel — this is the regfile mode for context save/restore + userland.) r9999
  implements `Status.FR` (`exec.sv` `r_sr_fr`, **reset value 1**); see [FPU (COP1)](fpu-cop1.md).
- **Watch registers (WatchLo/WatchHi, r18/r19): unused.** The only references are two `mtc0 zero` clears
  in `start`; nothing ever programs a watch address, so ExcCode 23 never fires. IRIX's watchpoint facility
  is pure software. r9999 keeps them as plain storage registers (`exec.sv` CP0 r18/r19, "functional
  register only; no watch hardware"); no Watch-match HW.

## Physical address width

- **29 bits observed; 30 bits architectural.** The test Indy measured a max PA of `0x1fffffff` (29 bits)
  only because it had ~16 MB RAM. The MC map (mc.pdf p.22) has a **second 256 MB "High System Memory"
  window at `0x20000000–0x2fffffff`** (kseg-mapped) → a maxed Indy needs **30-bit PA**.
- Low RAM window `0x08000000–0x17ffffff` (256 MB max); kernel/device region up to `0x1fffffff`.
  TLB-mapped PFNs observed only `0x0800_0000`–~`0x0900_0000` (max `0x0881a000`); EntryLo PFN is
  arch-24-bit but only ~17 significant bits are ever used on this platform.
- **The bottom 512 KB `0x0–0x7ffff` ALIASES RAM** (for exception vectors at `0x0`/`0x80`). Henry
  implements it in `henry_soc.sv:568-630` (`w_sysmem_alias` sets PA bit 27 on the CPU's external memory
  request). The remap applies to **CPU accesses only** (DMA masters are not remapped), and it happens
**below the caches**, on the DRAM-bound request.
- ⇒ cache/TLB **physical tags need 30 bits** to be safe (29 observed). r9999 carries **36-bit** physical
  addresses (`PA_WIDTH=36`, the R4000 width, `machine.vh`) in the caches, L2 and SoC; the TLBs store
  only **`TLB_PA_WIDTH=30`** PA bits, zero-filled to 36 (r9999 `c24d139`; raised from 29 to 30 in
  `50d753c` so the PROM's memory-bank probe at PA `0x20000000` works), so this is covered.
- **The PROM's bank probe** makes one bank valid at base `0x20000000` and probes it uncached. Henry
  routes banks 0/1 in that window to their DRAM (offset mod 128 MB) and treats banks 2/3 as empty
  memory: loads read 0, stores vanish, no bus error (`henry_soc.sv:268-279`, henry `ae2b7ab`). The
  PROM then reports 256 MB.

## Detailed working notes

- `/home/dsheffie/code/r9999/IRIX_KERNEL_GAPS.md` — the `cache`-instruction decode requirement + boot
  histogram; the TLB/CP0/physical-address section; Watch-register and Status.FR findings.
- `/home/dsheffie/code/r9999/MAME_QUESTIONS.md` — the Q1 `wirepda` answer (golden wired PDA entry,
  single-step trace, the two suspects, the directed test).
- `/home/dsheffie/code/r9999/IP22_CHIP_REGISTERS.md` — HPC3/VDMA non-coherence (the cache-op split is
  architecturally mandated), MC/IOC2 register maps, physical-address-width correction.
