# gio_window unit test: 16-record ring so ring-full back-pressure is exercised
VERILATOR ?= /home/dsheffie/local/bin/verilator
R9999     ?= ../../r9999
obj_dir/Vgio_window: ../../rtl/gio_window.sv tb_gio_window.cpp
	$(VERILATOR) --cc --exe --build -O2 -Wno-fatal +incdir+$(R9999) -GLG_RING_N=4 -GPROD_EVERY=3 \
	  -MAKEFLAGS "OPT_FAST=-O2 OPT_GLOBAL=-O2" \
	  --top-module gio_window ../../rtl/gio_window.sv tb_gio_window.cpp -o Vgio_window
clean:
	rm -rf obj_dir
