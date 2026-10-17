# Newport on henry: ARM-served GIO devices

Status: APPROVED (2026-10-16): all reads ARM-served, X11 window presentation, model copied into the project. Builds on the staging rings
(`arm-device-protocol.md`) and the feasibility study (`NEWPORT_FEASIBILITY.md`).

## Goal

IRIX sees an Indy XL graphics board (REX3 and its DCB devices: VC2, XMAP9, CMAP,
RAMDAC) at GIO slot address `0x1f0f0000`, and gets Xsgi to the 4Dwm desktop on
silicon. The board itself is software on an ARM core: the same `sgi_newport` model
indysim uses (condensed MAME `newport.cpp` + span kernels, bit-exact on x86 and A53).

The PL part is deliberately generic -- **an ARM-served GIO window** -- so the same
infrastructure carries later devices. IMPACT's HQ3 command FIFO is the same pattern
at higher volume (`IMPACT_FEASIBILITY.md`).

## Split

| | PL (`gio_window.sv`, new) | ARM (`gio_service` in the driver) |
|---|---|---|
| Stores to the window | append a record to a capture ring in the staging region; posted | apply in order to the device model |
| Loads from the window | hold the CPU load; append a read-request record behind all earlier stores; wait for the ARM's answer | process the ring up to the request, run the read (side effects included: STATUS read acks retrace), post the 64-bit answer |
| Interrupts | drive `local1_src` / `local0_src` bits from an ARM-written level register | decide when lines rise and fall (vblank timer, DMA done) |
| Flow control | ring full: hold the CPU store until the ARM frees space (consumer-index doorbell, as the ENET/SCSI rings) | doorbell its consumer index |
| Presentation | -- | framebuffer → X11 window on the board's Xtightvnc (VNC), later DisplayPort |

```
 CPU store 0x1f0f0xxx ─► gio_window ─► capture ring (staging, uncached) ─► ARM: sgi_newport ─► framebuffer ─► VNC
 CPU load  0x1f0f0xxx ─► gio_window ─► read-request record ───────────────► ARM: answer ─► AXI-Lite ─► CPU
 vblank / DMA-done    ◄─ local1_src[7] ◄─ ARM-written IRQ level register ◄── ARM timers
```

Ordering is the only subtle part: a read must observe every earlier write, so read
requests go through the same ring, and the ARM answers only after draining it. The
CPU is blocked on the load meanwhile (device loads already block in henry).

## Why all reads go to the ARM (for now)

The feasibility traces: ~99.9% of accesses are posted writes, drawing paths do not
read, and the reads that remain (probe, DCB readback, STATUS, pixel readback) have
side effects or need the framebuffer. Serving every read on the ARM is the simplest
correct design. A PL fast path (a shadow of side-effect-free registers the ARM keeps
current) is an optimization to add only if profiling shows read latency matters.

## Records and placement

- Capture ring in the free staging range `0x1E200000–0x1E3FFFFF` (2 MB): 16-byte
  records `{type/size/byte-mask, offset, data[63:0]}`, about 128K records.
- Types: STORE, READ_REQ (with a sequence number the answer echoes).
- PL-owned producer index next to the existing ring indices (`+0x40` block);
  ARM consumer index and read answer through new AXI-Lite doorbells.
- At the measured ivview rate (~1.8K GOs and ~4.8K register writes per million
  instructions) this is a few MB/s into DDR -- small next to the core's own traffic,
  but it shares the single memory port, so records are coalesced to 16-byte lines.

## Cost and fit

- PL: address decode, a record builder, the request hold, an IRQ level register.
  Estimated 1–2K LUTs; development on the TINY_CORE build (55.7K LUT, timing met).
- ARM: one core for the model. Measured on the A53 replay: ~5.85 µs per GO for the
  ivview workload, i.e. about one core at that rate today; the pixel-kernel fixes
  (masked-span early out, vectorized CI-clamped shading) are expected to cut that a lot.

## Milestones

1. **N1 (sim):** `gio_window` in henry_tb, serviced by the same servicer source the
   driver uses, linked against indysim's `sgi_newport`. IRIX probe passes: hinv
   "Graphics board: Indy 8-bit".
2. **N2 (sim):** Xsgi reaches the xdm login in henry_tb (PPM evidence), TINY_CORE.
3. **N3 (silicon):** the same on the board, presented over VNC. PS/2 keyboard and
   mouse need the same treatment (IOC2 8042) to log in -- same window pattern.
4. **N4:** MC graphics DMA (through the coherent device path), performance work on
   the ARM model, then IMPACT reuses `gio_window` for HQ3.

## Interface (v1)

**Window.** `0x1f0f0000–0x1f0f1fff` (8 KB, REX3 incl. its GO alias at `+0x800`).
Everything else in the GIO slot space keeps today's behaviour.

**Capture ring.** Staging `0x1E200000`, 65536 records × 16 B (1 MB). Little-endian
record (byte i of the record = bits `[8i+7:8i]` of the PL's 128-bit write):

| bytes | field |
|---|---|
| 0–3 | `w0 = {type[31:30], mask[29:22], dwoff[21:0]}`; type 0 = STORE, 1 = READ; `dwoff` = window byte offset >> 3; `mask` bit i = lane i valid |
| 4–7 | `recno`: running record number, **starting at 1** (the answer-sequence register resets to 0, so 0-based numbering could falsely complete a first-record READ) |
| 8–15 | `lane[0..7]`: lane i = the byte at window offset `dwoff*8 + i` (big-endian values span lanes in address order) |

- **Producer index:** `prod` (u32, records written = recno of the last record written) at staging `+0x60`. Record `n` lives in slot `(n−1) mod 65536`. The PL
  writes it after every READ record and whenever its write FIFO drains, so it can
  lag behind the records; the ARM reads records `[cons, prod)`.
- **Ring full** (`prod − cons == 65536`): the PL holds the CPU's access.

**AXI-Lite (S00), ARM writes:**

| reg | meaning |
|---|---|
| `0x20` | read answer lanes 0–3 (lane 0 in bits 7:0) |
| `0x21` | read answer lanes 4–7 |
| `0x22` | read answer sequence = the READ record's `recno`; writing it completes the held load (write `0x20`/`0x21` first) |
| `0x23` | `cons`: records consumed so far |
| `0x2A` | IRQ levels: bits 7:0 → INT3 `local1_src` (bit 7 = VRETRACE); 15:8 reserved |

**AXI-Lite reads (debug):** `0x20` = `prod`; `0x21` = `{pending, pending_recno[30:0]}`.
RTL revision `0x20261016`.

**henry_soc ports (Verilator / IP):** in `gio_cons[31:0]`, `gio_ans_lo[31:0]`,
`gio_ans_hi[31:0]`, `gio_ans_seq[31:0]`, `gio_irq[15:0]`; out `gio_prod[31:0]`,
`gio_pend`, `gio_pend_seq[31:0]`.

**Memory master.** Arbiter master 2 (the retired DRAM deep trace's slot, idle unless
`ENABLE_DRAM_TRACE`). Staging addresses are not snooped.

## Decisions (dsheffie, 2026-10-16)

1. All reads ARM-served to start.
2. Presentation: an X11 window on the board's Xtightvnc.
3. The model is copied into the project (as `ring_service.h` is shared today).
