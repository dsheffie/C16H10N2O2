#!/bin/sh
# ip28_fpga.sh -- program a C16H10N2O2 bitstream and set the PL fabric clock.
# Runs as root on the Ultra96v2 board (fpga.local).
#
# The IP28 (R10000) build closes timing at 50 MHz only, and the bitstream does not
# carry the PS clock: pl_clk0 comes from CRL_APB PL0_REF_CTRL @ 0xFF5E00C0.
#   [13:8] DIVISOR0, [21:16] DIVISOR1, SRCSEL 0 = IOPLL (1500 MHz on this board)
#   0x01011E00 = 50 MHz, 0x01010F00 = 100 MHz (stock)
# The PS keeps the register across reprogramming.  It is written BEFORE fpgautil
# (as plclk.sh does) so the new design comes out of configuration on the clock it
# was timed for, instead of starting overclocked at 100 MHz and having the divider
# change under it.  PL0_REF_CTRL is a PS (CRL_APB) register, not a PL address, so
# writing it is safe whatever the PL holds.
#
# Refuses to run while a driver (ip28-axi or henry's mips-axi) is live: changing
# the fabric clock or the PL under an AXI session wedges the board.
#
# usage: ./ip28_fpga.sh <bitstream.bit> [MHz]     (MHz default 50)
#        ./ip28_fpga.sh                           (report the current clock)
set -u
REG=0xFF5E00C0
PLL=1500
KMOD=${KMOD:-/home/dsheffie/ultra96v2-rv64core-kmd/ultra96v2_riscv.ko}

report() {
	cur=$(devmem $REG 32)
	d0=$(( (cur >> 8) & 0x3F ))
	d1=$(( (cur >> 16) & 0x3F ))
	[ "$d0" -eq 0 ] && d0=1
	[ "$d1" -eq 0 ] && d1=1
	echo "PL0_REF_CTRL = $cur  -> $((PLL / d0 / d1)) MHz"
}

if [ $# -eq 0 ]; then
	report
	exit 0
fi

bit=$1
mhz=${2:-50}
[ -f "$bit" ] || { echo "FATAL: no bitstream $bit"; exit 1; }

div=$(( PLL / mhz ))
if [ "$div" -lt 1 ] || [ "$div" -gt 63 ] || [ $(( PLL / div )) -ne "$mhz" ]; then
	echo "FATAL: $mhz MHz is not $PLL / an integer divisor in [1,63]"
	exit 1
fi

for exe in ip28-axi mips-axi; do
	if pgrep -x $exe > /dev/null; then
		echo "FATAL: $exe is running (pid $(pgrep -x $exe | tr '\n' ' ')); stop it first"
		exit 1
	fi
done

used=$(df / | awk 'NR==2 {print int($5)}')
[ "$used" -lt 98 ] || { echo "FATAL: root fs ${used}% full (fpgautil fails on a full SD)"; exit 1; }

# the driver's kernel module (ip28-axi maps the PL and the shared DRAM through it)
lsmod | grep -q ultra96v2_riscv || insmod "$KMOD" || { echo "FATAL: insmod $KMOD failed"; exit 1; }

cur=$(devmem $REG 32)
# one divisor stage: DIVISOR0 = div, DIVISOR1 = 1
new=$(printf "0x%08x" $(( (cur & ~0x3F3F00) | (div << 8) | (1 << 16) )))
devmem $REG 32 "$new"
report

echo "programming $bit ($(md5sum "$bit" | cut -c1-8))"
fpgautil -b "$bit" > /dev/null 2>&1 || { echo "FATAL: fpgautil failed"; exit 1; }
echo "PL programmed"
