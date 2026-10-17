# tb_enet_ring_dma.cpp against the ENET DMA path:
#   make engine   -- dma_engine (the unified DMA engine's ENET channels; henry_soc's)
#   make old      -- enet_ring_dma (the previous implementation)
#   make run      -- build and run both
VERILATOR ?= verilator
R9999     ?= $(abspath ../../r9999)
RTL       := $(abspath ../../rtl)
VFLAGS    := --cc --exe --build -j 8 -O2 -Wno-fatal -Wno-WIDTH -Wno-UNUSED \
             -MAKEFLAGS "OPT_FAST=-O2 OPT_GLOBAL=-O2" -I$(R9999) -y $(RTL) --top-module enet_ring_dma

.PHONY: engine old run clean
engine: obj_dir_engine/Venet_ring_dma
old: obj_dir_old/Venet_ring_dma

obj_dir_engine/Venet_ring_dma: enet_ring_dma_engine.sv tb_enet_ring_dma.cpp $(RTL)/dma_engine.sv
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_engine enet_ring_dma_engine.sv tb_enet_ring_dma.cpp -o Venet_ring_dma

obj_dir_old/Venet_ring_dma: tb_enet_ring_dma.cpp $(RTL)/enet_ring_dma.sv
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_old $(RTL)/enet_ring_dma.sv tb_enet_ring_dma.cpp -o Venet_ring_dma

run: engine old
	./obj_dir_engine/Venet_ring_dma | tail -2
	./obj_dir_old/Venet_ring_dma | tail -2

clean:
	rm -rf obj_dir_engine obj_dir_old
