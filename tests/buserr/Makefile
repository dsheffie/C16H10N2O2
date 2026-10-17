# bare-metal bus-error test (docs/bus-errors.md), run in henry_tb
CC = mips-linux-gnu-gcc
CFLAGS = -march=mips3 -mabi=32 -EB -mno-abicalls -fno-pic -ffreestanding -nostdlib -nostartfiles -O1
buserr.elf: start.S buserr.c
	$(CC) $(CFLAGS) -Wl,-Ttext=0x80010000 -Wl,-e,_start start.S buserr.c -o $@
clean:
	rm -f buserr.elf
