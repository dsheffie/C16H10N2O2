# IRIX 5.3's own bcopy/blkclr (extracted from the 5.3 kernel at build time, so SGI's
# code is not in this repo) against reference models, bare metal (henry_tb / silicon).
#   bcopy53.elf  : overlapping/unaligned bcopy vs memmove
#   blkclr53.elf : sdl/sd/sdr blkclr vs a byte clear (warm, store-buffer junk, evicted)
#   dirsim*.elf  : the 5.3 /tmp directory compaction replayed (kseg0 / TLB-mapped)
UNIX53 ?= $(HOME)/unix53.elf
CC = mips-linux-gnu-gcc
CFLAGS = -march=mips3 -mabi=32 -EB -mno-abicalls -fno-pic -ffreestanding -nostdlib -nostartfiles -O1
LDFLAGS = -Wl,-Ttext=0x88010000 -Wl,-e,_start
all: bcopy53.elf blkclr53.elf dirsim.elf dirsim_tlb.elf
bcopy53.S: extract.py
	python3 extract.py $(UNIX53) bcopy53 0x88015700 0x88015b48 $@
blkclr53.S: extract.py
	python3 extract.py $(UNIX53) blkclr53 0x88015110 0x880151bc $@
bcopy53.elf: start.S bcopy53.S bcopy53_test.c
	$(CC) $(CFLAGS) $(LDFLAGS) start.S bcopy53.S bcopy53_test.c -o $@
blkclr53.elf: start.S blkclr53.S blkclr53_test.c
	$(CC) $(CFLAGS) $(LDFLAGS) start.S blkclr53.S blkclr53_test.c -o $@
dirsim.elf: start.S bcopy53.S blkclr53.S dirsim.c
	$(CC) $(CFLAGS) $(LDFLAGS) start.S bcopy53.S blkclr53.S dirsim.c -o $@
dirsim_tlb.elf: start.S bcopy53.S blkclr53.S dirsim_tlb.c
	$(CC) $(CFLAGS) $(LDFLAGS) start.S bcopy53.S blkclr53.S dirsim_tlb.c -o $@
clean:
	rm -f *.elf bcopy53.S blkclr53.S
