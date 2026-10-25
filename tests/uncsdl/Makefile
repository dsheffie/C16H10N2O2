# uncached sdl/sdr/swl/swr with an unrelated line cached at the same L1D index
CC = mips-linux-gnu-gcc
CFLAGS = -march=mips3 -mabi=32 -EB -mno-abicalls -fno-pic -ffreestanding -nostdlib -nostartfiles -O1
uncsdl.elf: start.S uncsdl.c
	$(CC) $(CFLAGS) -Wl,-Ttext=0x88010000 -Wl,-e,_start start.S uncsdl.c -o $@
clean:
	rm -f uncsdl.elf
