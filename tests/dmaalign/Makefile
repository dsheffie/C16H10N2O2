# bare-metal SCSI DMA alignment/coherence test, run in henry_tb with --disk dmaalign.img
CC = mips-linux-gnu-gcc
CFLAGS = -march=mips3 -mabi=32 -EB -mno-abicalls -fno-pic -ffreestanding -nostdlib -nostartfiles -O1
all: dmaalign.elf dmaalign.img
dmaalign.elf: start.S dmaalign.c
	$(CC) $(CFLAGS) -Wl,-Ttext=0x88010000 -Wl,-e,_start start.S dmaalign.c -o $@
dmaalign.img: gen_disk.py
	python3 gen_disk.py $@
clean:
	rm -f dmaalign.elf dmaalign.img
