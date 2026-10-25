# store to line A then a missing store to line B (same L1D index), bare metal
CC = mips-linux-gnu-gcc
CFLAGS = -march=mips3 -mabi=32 -EB -mno-abicalls -fno-pic -ffreestanding -nostdlib -nostartfiles -O1
l1dconflict.elf: start.S l1dconflict.c
	$(CC) $(CFLAGS) -Wl,-Ttext=0x88010000 -Wl,-e,_start start.S l1dconflict.c -o $@
clean:
	rm -f l1dconflict.elf
