# C16H10N2O2: the PL runs at 50 MHz (the R10000 build, ENABLE_R10000, closes there, not at
# 100 MHz).  The PS IP's own xdc creates clk_pl_0 at 10 ns; re-define it at 20 ns.
# The bitstream does not carry the PS clock.  On the board, after fpgautil succeeds:
#   devmem 0xFF5E00C0 32 0x01011E00     # CRL_APB PL0_REF_CTRL: IOPLL / 30 = 50 MHz
create_clock -name clk_pl_0 -period 20.000 [get_pins -hierarchical -filter {NAME =~ */PS8_i/PLCLK[0]}]
