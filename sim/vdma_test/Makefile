# tb_vdma.cpp: dma_engine's VDMA channel (MC memory -> GIO) against indysim's dma_perform.
#   make run
VERILATOR ?= verilator
R9999     ?= $(abspath ../../r9999)
RTL       := $(abspath ../../rtl)
VFLAGS    := --cc --exe --build -j 8 -O2 -Wno-fatal -Wno-WIDTH -Wno-UNUSED \
             -MAKEFLAGS "OPT_FAST=-O2 OPT_GLOBAL=-O2" -I$(R9999) -y $(RTL) --top-module dma_engine

.PHONY: run clean
obj_dir/Vdma_engine: tb_vdma.cpp $(RTL)/dma_engine.sv
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir $(RTL)/dma_engine.sv tb_vdma.cpp -o Vdma_engine

run: obj_dir/Vdma_engine
	./obj_dir/Vdma_engine | tail -3

clean:
	rm -rf obj_dir
