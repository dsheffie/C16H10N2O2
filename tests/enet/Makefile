# bare-metal ENET staging-ring test (run in henry_tb built with ENET_RINGS=1)
CC = mips-linux-gnu-gcc
CFLAGS = -march=mips3 -mabi=32 -EB -mno-abicalls -fno-pic -ffreestanding -nostdlib -nostartfiles -O1
enet_ring.elf: start.S enet_ring.c
	$(CC) $(CFLAGS) -Wl,-Ttext=0x80010000 -Wl,-e,_start start.S enet_ring.c -o $@
enet_order.elf: start.S enet_order.c
	$(CC) $(CFLAGS) -Wl,-Ttext=0x80010000 -Wl,-e,_start start.S enet_order.c -o $@
clean:
	rm -f enet_ring.elf enet_order.elf
