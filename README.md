# C₁₆H₁₀N₂O₂ — Henry, dyed indigo

**C₁₆H₁₀N₂O₂** is indigo dye, and this is the **Indigo2** (board code **IP28**, R10000) fork of Henry
([henry-the-wannabe-ip22-soc](https://github.com/dsheffie/henry-the-wannabe-ip22-soc), the `upstream`
remote).  It differs from Henry in what it builds:

- the r9999 core is built with **`ENABLE_R10000`** (`gen_mipscore.sh`'s default `SV2V_DEFINES`, and
  `sim/Makefile`): 44-bit virtual addresses, a 64-entry JTLB, 31-bit TLB physical addresses and all of
  MIPS IV.  r9999 itself is unchanged; its `machine.vh` defaults to the R4400.
- the IP28 board model (INT2 remapped onto INT3, the cascaded 8254 on IP4/IP5, the 93CS56 EEPROM, the
  second WD33C93, MC rev D, memory at 0x20000000) is still to come; indysim's `--ip28` is the reference.

Everything below is Henry's README.

# Henry — the wannabe IP22 SoC

A from-scratch FPGA/RTL **System-on-Chip** that impersonates the SGI **Indy** (board code **IP22**) closely
enough to boot **IRIX 6.5.22**, built around the **r9999** MIPS R4000-class core.

> **Why "Henry"?** The Indy is named for **Indiana Jones**, whose real name is **Henry** (Walton Jones Jr.;
> "Indiana" was the dog). Henry answers to a name that isn't quite its own — a *wannabe* IP22.

This repo is **documentation-first**: the [`docs/`](docs/) tree is the platform specification (address map,
per-block register interfaces + "minimum to boot," the ARCS firmware shim, the boot/console contract, the
cache/coherence/TLB rules). The RTL (`rtl/`) and co-simulation harness (`sim/`) are built *against* that spec,
and validated against **MAME** booting the real Indy IRIX image (Henry's golden reference model).

## Layout

```
henry-the-wannabe-ip22-soc/
├── docs/            # the platform spec (see docs/index.md) — mkdocs site
│   ├── peripherals/ #   one spec per block: mc, ioc2, hpc3, gio64, vdma
│   └── ...          #   architecture, cpu-integration, firmware-arcs, boot-and-console,
│                    #   coherence-cache-tlb, methodology
├── r9999/           # git submodule — the CPU core (tracks clean origin/main)
├── rtl/             # peripheral RTL (MC, HPC3, IOC2/SCC, RTC, ...) + the SoC top instantiating r9999
├── sim/             # Verilator co-sim (henry_tb, ISS diff-checker) + mipsmon console client
├── driver/          # on-board mips-axi driver (AXI-Lite control + shared-DRAM)
└── mkdocs.yml
```

## Getting it

```sh
git clone --recurse-submodules <this-repo>
# or, after a plain clone:
git submodule update --init --recursive
```

## Reading / building the docs

The docs are plain Markdown — read them directly starting at [`docs/index.md`](docs/index.md), or build the
website:

```sh
pip install mkdocs            # (theme: built-in readthedocs; or `pip install mkdocs-material` and set theme.name: material)
mkdocs serve                 # live preview at http://127.0.0.1:8000
mkdocs build                 # static site → site/
```

## Status

Henry **boots IRIX 6.5.22 on real FPGA silicon** (Ultra96-v2, Zynq UltraScale+): PROM/ARCS → IRIX kernel →
SCSI DMA → the miniroot → IRIX userspace. The peripheral RTL (MC, HPC3, IOC2/SCC serial console, ds1386 RTC)
plus an ARM/PS-serviced SCSI disk bridge (the driver walks the HPC3 descriptor chain in shared DRAM) are implemented, together with the Verilator co-sim harness
(`sim/henry_tb`, with an in-sim ISS diff-checker). The [`docs/`](docs/) tree remains the platform spec,
cross-validated against MAME. Still doc-only (not in the serial-console boot path): the Newport graphics set
and audio (HAL2). The r9999-side detailed working notes (`IRIX_CPU_REQUIREMENTS.md`, `IRIX_KERNEL_GAPS.md`,
`IP22_CHIP_REGISTERS.md`, `MAME_QUESTIONS.md`) live in the
[`r9999/`](https://github.com/dsheffie/r9999) submodule (which now tracks a clean `origin/main`).
