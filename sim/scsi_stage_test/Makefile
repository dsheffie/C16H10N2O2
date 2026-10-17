# tb_scsi_stage.cpp against the SCSI DMA path:
#   make engine   -- dma_engine (the unified DMA engine's SCSI channel; henry_soc's)
#   make old      -- scsi_dma + scsi_stage (the previous implementation)
#   make run      -- build and run both
VERILATOR ?= verilator
R9999     ?= $(abspath ../../r9999)
RTL       := $(abspath ../../rtl)
VFLAGS    := --cc --exe --build -j 8 -O2 -Wno-fatal -Wno-WIDTH -Wno-UNUSED \
             -MAKEFLAGS "OPT_FAST=-O2 OPT_GLOBAL=-O2" -I$(R9999) -y $(RTL) --top-module scsi_stage_top

.PHONY: engine old run clean
engine: obj_dir_engine/Vscsi_stage_top
old: obj_dir/Vscsi_stage_top

obj_dir_engine/Vscsi_stage_top: scsi_stage_top_engine.sv tb_scsi_stage.cpp $(RTL)/dma_engine.sv
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir_engine scsi_stage_top_engine.sv tb_scsi_stage.cpp -o Vscsi_stage_top

obj_dir/Vscsi_stage_top: scsi_stage_top.sv tb_scsi_stage.cpp $(RTL)/scsi_dma.sv $(RTL)/scsi_stage.sv
	$(VERILATOR) $(VFLAGS) --Mdir obj_dir scsi_stage_top.sv tb_scsi_stage.cpp -o Vscsi_stage_top

run: engine old
	./obj_dir_engine/Vscsi_stage_top | tail -2
	./obj_dir/Vscsi_stage_top | tail -2

clean:
	rm -rf obj_dir obj_dir_engine
