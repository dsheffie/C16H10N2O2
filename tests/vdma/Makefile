# Henry SoC MC VDMA (memory -> GIO) test: see vdma_test.c.
# Builds a bare-metal MIPS ELF (reusing the r9999 bare-metal runtime) and runs it
# on henry_tb, which has the full SoC (core + ioc + int3).
R9999    := /home/dsheffie/code/r9999
HELLO    := $(R9999)/hello
CSMITH   := $(R9999)/tests/csmith
HENRY_TB := ../../sim/obj_dir/henry_tb

CC := mips-linux-gnu-gcc
BM_FLAGS := -mxgot -ffreestanding -O1 -mips3 -mno-branch-likely -mabi=n32 -mno-abicalls

SRCS := vdma_test.c \
        $(CSMITH)/start_csmith.S \
        $(CSMITH)/baremetal_support.c \
        $(HELLO)/printf.c \
        $(HELLO)/arith64.c

vdma_test.elf: $(SRCS) $(HELLO)/baremetal.ld
	$(CC) $(BM_FLAGS) -I$(HELLO) -w -nostdlib \
	    $(CSMITH)/start_csmith.S \
	    $(CSMITH)/baremetal_support.c \
	    $(HELLO)/printf.c \
	    $(HELLO)/arith64.c \
	    vdma_test.c \
	    -T $(HELLO)/baremetal.ld -Wl,-melf32btsmipn32 -o $@

# Build henry_tb (picks up ioc.sv/int3.sv changes) then run the test.
run: vdma_test.elf
	$(MAKE) -C ../../sim
	$(HENRY_TB) --kernel $< --maxcyc 20000000 2>&1

dis: vdma_test.elf
	mips-linux-gnu-objdump -d $< > vdma_test.dis

clean:
	rm -f vdma_test.elf vdma_test.dis
