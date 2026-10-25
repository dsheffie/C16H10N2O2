# bare-metal bus-error test (docs/bus-errors.md), run in henry_tb
CC = mips-linux-gnu-gcc
CFLAGS = -march=mips3 -mabi=32 -EB -mno-abicalls -fno-pic -ffreestanding -nostdlib -nostartfiles -O1
memprobe.elf: start.S memprobe.c
	$(CC) $(CFLAGS) -Wl,-Ttext=0x80010000 -Wl,-e,_start start.S memprobe.c -o $@
clean:
	rm -f memprobe.elf
