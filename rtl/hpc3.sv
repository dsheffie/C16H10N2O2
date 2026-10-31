// -----------------------------------------------------------------------------
// hpc3.sv -- SGI Indy HPC3 peripheral controller @ phys 0x1fb80000 .. 0x1fbfffff
// (the IOC2 sub-window @0x1fbd98xx is carved out and handled by ioc.sv).
// Translated from the r9999 sgi_hpc.cc functional model.
//
// Word-granular register slave (same interface as mc.sv).  Models the few regs
// the kernel reads (intstat/misc) plus the ds1386 RTC clock @0x60000 (fixed BCD
// time -- required so IRIX rtodc() doesn't spin); the SCSI/enet/PBUS DMA/PIO
// windows are write-absorbed.  Reads not yet modeled return 0 (a documented gap
// -- see tests/devregs: HPC 0x11004/0x58010/0x58020 etc. MAME returns nonzero).
//
// The mem-to-mem DMA copy engine (datapath bring-up / arbiter exercise) lives in
// dma_memcpy.sv and is gated by `ENABLE_HPC3_DMA below: it is NOT the real HPC3
// SCSI channel and conflicts with scsi_shim's use of the HPC3 DMA window, so the
// SoC build compiles it out (the DMA master then ties off).  Default OFF; define it
// only for the dma_memcpy isolation test.
// -----------------------------------------------------------------------------
`include "machine.vh"
`ifndef CORE_MHZ
`define CORE_MHZ 100   /* the PL clock in MHz; the IP28 build (50 MHz, clk50.xdc) passes CORE_MHZ=50 */
`endif
//`define ENABLE_HPC3_DMA 1

module hpc3
   (input  logic         clk,
    input  logic         reset,
    input  logic         sel,
    input  logic         is_store,
    input  logic [18:0]  offs,       // line base, byte offset within HPC3 (addr & 0x7ffff)
    input  logic [15:0]  mask,
    input  logic [127:0] wdata,
    output logic [127:0] rdata,
    /* SCSI0 DMA channel status from scsi_dma (hpc3.pdf 'HD control register'): the
     * processor sets ch_active to start; HPC3 CLEARS it when the chain completes, and
     * the xie interrupt is cleared when the control register is READ.  These were never
     * decoded -- hd0.bc/hd0.cntl read as 0, so the guest polled forever. */
    input  logic         scsi0_dma_busy,   // engine active -> reflects ch_active
    input  logic         scsi0_dma_irq,    // 1-cycle pulse: final descriptor had XIE
    input  logic [13:0]  scsi0_dma_bc,     // residual byte count
    output logic         scsi0_hpc_intr,   // level: XIE latched, cleared on cntl read
    // ---- DMA master (mem-to-mem copy engine) -> henry_soc DRAM arbiter ----
    output logic                  dma_req_valid,
    output logic [`PA_WIDTH-1:0]  dma_req_addr,
    output logic [4:0]            dma_req_opcode,     // 4 = line load, 7 = line store
    output logic [127:0]          dma_req_store_data,
    output logic [15:0]           dma_req_mask,
    input  logic                  dma_rsp_valid,
    input  logic [127:0]          dma_rsp_load_data);

   logic [31:0] r_intstat, r_misc;
   wire  [31:0] w_dma_status;       // CTRL (0x1000c) read value from the DMA engine (0 if gated off)

   // PBUS DMA/PIO channel config + SCSI0 channel config.  IRIX's pbus init writes
   // these and READS THEM BACK to validate (else "pbus configuration failed for
   // channel N"); the values don't affect the host-served disk path, so we just
   // store and return them to satisfy the probe.  (Matches interp_mips sgi_hpc.cc.)
   logic [31:0] r_pbus_dma [0:7];   // 0x5c000 block: 8 PBUS DMA channels (stride 0x200)
   logic [31:0] r_pbus_pio [0:15];  // 0x5d000 block: PBUS PIO channels (stride 0x100)
   logic [31:0] r_scsi_dmacfg, r_scsi_piocfg;  // 0x11010 / 0x11014 SCSI0 channel cfg
   logic        r_hd0_xie;        /* latched XIE interrupt; cleared when cntl is read */
   logic        r_hd0_dir, r_hd0_flush;

   // NMC93CS56 serial EEPROM @ reg 0x30008 (hpc3c0->eeprom). IRIX if_ec (get_nvreg,
   // ml/IP22.c) reads the station MAC from it via a bit-banged Microwire protocol:
   //   0x01 EPROT  0x02 CSEL  0x04 ECLK  0x08 DATO(->EE)  0x10 DATI(<-EE)
   // READ = start(1)+opcode(10)+8b addr clocked in on ECLK rising (11 bits, MSB first),
   // then 16 data bits clocked out on DATI (MSB first). (Guiness bbRAM path unused here;
   // this IRIX takes the FullHouse/serial branch.)  See linux ip22-nvram.c.
   logic        r_ee_eprot, r_ee_csel, r_ee_eclk, r_ee_dato, r_ee_dati;
`ifdef ENABLE_IP28
   /* the IP28 93CS56 (below the ds1386 section) */
   typedef enum logic [2:0] {
      EE_STANDBY = 3'd0,
      EE_IDLE = 3'd1,
      EE_OPCODE = 3'd2,
      EE_ADDRESS = 3'd3,
      EE_DATA_IN = 3'd4,
      EE_DATA_OUT = 3'd5
   } ee_st_t;
   logic [15:0] r_ee_mem [0:127];
   ee_st_t      r_ee_st, n_ee_st;
   logic        r_ee_cs, n_ee_cs, r_ee_sk, n_ee_sk, r_ee_do, n_ee_do, r_ee_wen, n_ee_wen;
   logic [3:0]  r_ee_reg, n_ee_reg;
`endif
   logic [4:0]  r_ee_bitcnt;        // 0..10 command bits, 11..26 data bits
   logic [10:0] r_ee_shin;          // command shift register (start+opcode+addr)
   logic [15:0] r_ee_shout;         // data word being clocked out, MSB first
   // EEPROM contents: MAC 08:00:69:12:34:56 at words 125/126/127 (if_ec reads these,
   // storing v0>>8 then v0 as consecutive MAC bytes).
   function automatic logic [15:0] ee_word(input logic [7:0] a);
      begin
         case(a)
           8'd125:  ee_word = 16'h0800;   // MAC bytes 0,1
           8'd126:  ee_word = 16'h6912;   // MAC bytes 2,3
           8'd127:  ee_word = 16'h3456;   // MAC bytes 4,5
           default: ee_word = 16'h0000;
         endcase
      end
   endfunction

   // ds1386 RTC @0x60000 (byte-per-word x4: internal reg i at offset 0x60000 + i*4,
   // value in the low byte = [31:24] after the BE swap, same lane convention as the
   // IOC2 SYSID).  Regs 0x00-0x0f live here: a running BCD clock (the SGI PROM
   // calibrates the CPU against the seconds tick and polls hundredths to check the
   // oscillator), settable by byte or word stores.  It resets to 2030-01-01 00:00:00:
   // IRIX rtodc() decodes year=1940+bcd (bcd<45 adds 30), so bcd 90 -> 2030, AFTER
   // the ~2026-06 /var/sysgen mtimes -- IRIX reconfigures ONCE and skips it on every
   // later boot.  The battery-backed RAM above reg 0x0f (the Indy NVRAM: environment
   // + station MAC) is NOT here: henry_soc leaves 0x1fbe0040..0x1fbe7fff undecoded,
   // so it is DRAM the ARM populates (see henry_soc.sv).
   localparam int RTC_DIV = `CORE_MHZ * 10000;   // core clocks per 1/100 s
   logic [7:0]  r_rtc [0:15];
   logic [7:0]  n_rtc [0:15];
   logic [19:0] r_rtc_div, n_rtc_div;
   logic [7:0]  t_rtc_last_date, t_rtc_inc;
   logic        t_rtc_leap;
   integer      j;

   function automatic logic [7:0] bcd_inc(input logic [7:0] v);
      begin
         if(v[3:0] == 4'd9)
           begin
              bcd_inc = {v[7:4] + 4'd1, 4'd0};
           end
         else
           begin
              bcd_inc = {v[7:4], v[3:0] + 4'd1};
           end
      end
   endfunction

   function automatic logic [31:0] hpc_rd(input logic [18:0] o);
      logic [31:0] x;
      begin
         x = 32'd0;
         if(o[18:12] == 7'h5c)       x = r_pbus_dma[o[11:9]];   // PBUS DMA cfg readback
         else if(o[18:12] == 7'h5d)  x = r_pbus_pio[o[11:8]];   // PBUS PIO cfg readback
         /* hd0.bc (R): residual byte count.  hd0.cntl (R/W): bit0 ch_active reads back from
          * the ENGINE's busy so HPC3 'clears' it exactly when the chain ends (hpc3.pdf);
          * bit1 dir, bit4 flush, bit5 latched XIE.  Neither was decoded before -> both read
          * 0 and the guest polled hd0.cntl forever. */
         else if(o == 19'h11000)     x = {18'd0, scsi0_dma_bc};
         else if(o == 19'h11004)     x = {26'd0, r_hd0_xie, r_hd0_flush, 2'd0, r_hd0_dir, scsi0_dma_busy};
         else if(o == 19'h11010)     x = r_scsi_dmacfg;         // SCSI0 DMA cfg readback
         else if(o == 19'h11014)     x = r_scsi_piocfg;         // SCSI0 PIO cfg readback
         else if(o[18:6] == 13'h1800) x = {r_rtc[o[5:2]], 24'd0}; // ds1386 regs 0x00-0x0f
         else case(o)
           19'h30000: x = r_intstat;
           19'h30004: x = r_misc;
           // NMC93CS56 eeprom register: IRIX readl()s it and tests bit4 (DATI). The
           // core bswaps device word loads, so the 5 control bits sit in byte3 [28:24]
           // -> post-bswap they land in the CPU word's [4:0] {EPROT,CSEL,ECLK,DATO,DATI}.
`ifdef ENABLE_IP28
           19'h30008: x = {3'b0, r_ee_do, r_ee_reg, 24'd0};
`else
           19'h30008: x = {3'b0, r_ee_dati, r_ee_dato, r_ee_eclk, r_ee_csel, r_ee_eprot, 24'd0};
`endif
           19'h1000c: x = w_dma_status; // mem-to-mem DMA status: bit0=BUSY bit1=DONE
           default:   x = 32'd0;     // unmodeled HPC3 read regs -> 0 (gap)
         endcase
         hpc_rd = x;
      end
   endfunction

   integer i;

   always_comb begin
      rdata = '0;
      // Drive the full word whenever ANY byte of the lane is accessed, so byte/half
      // loads (e.g. IRIX's lbu of the ds1386 bbRAM MAC) get the register value; the
      // core extracts the addressed byte.  Word reads (mask nibble = 0xf) unaffected.
      for(i = 0; i < 4; i = i + 1)
        if(mask[4*i +: 4] != 4'h0)
          rdata[32*i +: 32] = hpc_rd(offs + 19'(4*i));
   end

   always_ff @(posedge clk) begin
      if(reset) begin
         r_intstat <= 32'd0;
         r_misc    <= 32'd0;
         for(i = 0; i < 8;  i = i + 1) r_pbus_dma[i] <= 32'd0;
         for(i = 0; i < 16; i = i + 1) r_pbus_pio[i] <= 32'd0;
         r_scsi_dmacfg <= 32'd0;
         r_hd0_xie <= 1'b0; r_hd0_dir <= 1'b0; r_hd0_flush <= 1'b0;
         r_scsi_piocfg <= 32'd0;
         r_ee_eprot <= 1'b0; r_ee_csel <= 1'b0; r_ee_eclk <= 1'b0;
         r_ee_dato  <= 1'b0; r_ee_dati <= 1'b0;
         r_ee_bitcnt <= 5'd0; r_ee_shin <= 11'd0; r_ee_shout <= 16'd0;
      end
      else if(sel & is_store) begin
         // PBUS DMA/PIO config + SCSI0 cfg: store so the readback validates.
         if((offs[18:12] == 7'h5c) & (mask[3:0] == 4'hf)) r_pbus_dma[offs[11:9]] <= wdata[31:0];
         if((offs[18:12] == 7'h5d) & (mask[3:0] == 4'hf)) r_pbus_pio[offs[11:8]] <= wdata[31:0];
         /* hd0.cntl write: latch dir/flush only.  ch_active is deliberately NOT stored --
          * it reflects the engine, so completion clears it in hardware as the spec requires. */
         /* XIE: engine pulses irq at end-of-chain -> latch a LEVEL for the interrupt tree;
          * reading hd0.cntl clears it, exactly as hpc3.pdf specifies. */
         if(scsi0_dma_irq)                                r_hd0_xie <= 1'b1;
         else if(~is_store & sel & (offs == 19'h11000) & (mask[7:4] == 4'hf)) r_hd0_xie <= 1'b0;
         if((offs == 19'h11000) & (mask[7:4] == 4'hf))
           begin
              r_hd0_dir   <= wdata[33];
              r_hd0_flush <= wdata[36];
           end
         if((offs == 19'h11010)    & (mask[3:0] == 4'hf)) r_scsi_dmacfg <= wdata[31:0];
         if((offs == 19'h11010)    & (mask[7:4] == 4'hf)) r_scsi_piocfg <= wdata[63:32];
         // intstat/misc + remaining windows (write-absorb)
         for(i = 0; i < 4; i = i + 1)
           if(mask[4*i +: 4] == 4'hf)
             case(offs + 19'(4*i))
               19'h30004: r_misc <= wdata[32*i +: 32] & 32'h3;
               // NMC93CS56 eeprom register write. IRIX writel()s the control byte;
               // the core bswaps device word stores, so the CPU value's low byte
               // (EPROT/CSEL/ECLK/DATO in [3:0]) lands in this lane's high byte [31:24].
`ifndef ENABLE_IP28
               19'h30008: begin
                  r_ee_eprot <= wdata[32*i + 24];             // bit0 EPROT
                  r_ee_csel  <= wdata[32*i + 25];             // bit1 CSEL
                  r_ee_eclk  <= wdata[32*i + 26];             // bit2 ECLK
                  r_ee_dato  <= wdata[32*i + 27];             // bit3 DATO(->EE)
                  if(~wdata[32*i + 25]) begin                 // CSEL deasserted -> idle
                     r_ee_bitcnt <= 5'd0;
                  end
                  else if(wdata[32*i + 26] & ~r_ee_eclk) begin  // ECLK rising edge, CSEL on
                     if(r_ee_bitcnt == 5'd0 & ~wdata[32*i + 27]) begin
                        // leading zero(s) before the start bit (e.g. the cs_on ECLK
                        // pulse with DATO=0) -> ignore until the start bit (DATO=1)
                     end
                     else if(r_ee_bitcnt < 5'd11) begin       // command phase: shift in DATO
                        r_ee_shin   <= {r_ee_shin[9:0], wdata[32*i + 27]};
                        r_ee_bitcnt <= r_ee_bitcnt + 5'd1;
                        if(r_ee_bitcnt == 5'd10)              // 11th bit -> latch addr, load word
                          r_ee_shout <= ee_word({r_ee_shin[6:0], wdata[32*i + 27]});
                     end
                     else begin                               // data phase: shift out MSB first
                        r_ee_dati   <= r_ee_shout[15];
                        r_ee_shout  <= {r_ee_shout[14:0], 1'b0};
                        r_ee_bitcnt <= r_ee_bitcnt + 5'd1;
                     end
                  end
               end
`endif
               default:   /* enet/scsi/pio data windows: write-absorb */ ;
             endcase
      end
   end

`ifdef ENABLE_IP28
   /* ---- IP28: the 93CS56 (128 x 16) the PROM keeps its environment and the MAC in ----
    * Full House keeps the environment here, where the Indy uses the ds1386's RAM.  Same
    * register and bits as above (bit 1 CS, bit 2 SK, bit 3 DI, bit 4 DO), byte lane
    * 0x3000b as well as the word.  Commands: a start bit, 2 opcode bits, 8 address bits
    * (the top one don't-care); READ shifts out a dummy 0 then D15..D0; WRITE/ERASE/ERAL/
    * WRAL need EWEN.  Reset to the erased-part image the PROM's defaults leave (layout
    * revision 9, a few env defaults, the MAC in words 0x7d..0x7f, the checksum in byte
    * 0); not persisted.  Reference: r9999 sgi_hpc.cc ip28_eeprom_t (after IRIS
    * src/dev/eeprom_93c56.rs). */
   function automatic logic [15:0] ee_default(input logic [6:0] a);
      begin
         case(a)
           7'd0: ee_default = 16'h4109;
           7'd1: ee_default = 16'h6700;
           7'd58: ee_default = 16'h3936;
           7'd59: ee_default = 16'h3030;
           7'd60: ee_default = 16'h0030;
           7'd61: ee_default = 16'h5053;
           7'd62: ee_default = 16'h5438;
           7'd63: ee_default = 16'h5044;
           7'd64: ee_default = 16'h5400;
           7'd89: ee_default = 16'h5900;
           7'd116: ee_default = 16'h3830;
           7'd117: ee_default = 16'h0030;
           7'd118: ee_default = 16'h7900;
           7'd119: ee_default = 16'h0079;
           7'd121: ee_default = 16'h3100;
           7'd125: ee_default = 16'h0800;
           7'd126: ee_default = 16'h6912;
           7'd127: ee_default = 16'h3456;
           default: ee_default = 16'h0000;
         endcase
      end
   endfunction
   logic [15:0] r_ee_sh, n_ee_sh;
   logic [4:0]  r_ee_n, n_ee_n;
   logic [1:0]  r_ee_op, n_ee_op;
   logic [6:0]  r_ee_addr, n_ee_addr;
   /* ERAL/WRAL: a background fill, one word per cycle */
   logic        r_ee_fill, n_ee_fill;
   logic [6:0]  r_ee_fidx, n_ee_fidx;
   logic [15:0] r_ee_fval, n_ee_fval;
   logic        t_ee_we;
   logic [6:0]  t_ee_waddr;
   logic [15:0] t_ee_wdata;
   logic        t_ee_ncs, t_ee_nsk, t_ee_di;
   logic [15:0] t_ee_shift;
   initial
     begin
        for(integer k = 0; k < 128; k = k + 1)
          begin
             r_ee_mem[k] = ee_default(7'(k));
          end
     end
   wire w_ee_wr = sel & is_store & (offs == 19'h30000) & mask[11];

   always_comb
     begin
        n_ee_st = r_ee_st;
        n_ee_cs = r_ee_cs;
        n_ee_sk = r_ee_sk;
        n_ee_do = r_ee_do;
        n_ee_wen = r_ee_wen;
        n_ee_reg = r_ee_reg;
        n_ee_sh = r_ee_sh;
        n_ee_n = r_ee_n;
        n_ee_op = r_ee_op;
        n_ee_addr = r_ee_addr;
        n_ee_fill = r_ee_fill;
        n_ee_fidx = r_ee_fidx;
        n_ee_fval = r_ee_fval;
        t_ee_we = 1'b0;
        t_ee_waddr = r_ee_fidx;
        t_ee_wdata = r_ee_fval;
        t_ee_ncs = wdata[89];
        t_ee_nsk = wdata[90];
        t_ee_di = wdata[91];
        t_ee_shift = {r_ee_sh[14:0], t_ee_di};
        if(r_ee_fill)
          begin
             t_ee_we = 1'b1;
             n_ee_fidx = r_ee_fidx + 7'd1;
             n_ee_fill = (r_ee_fidx != 7'd127);
          end
        if(w_ee_wr)
          begin
             n_ee_reg = wdata[91:88];
             if(t_ee_ncs != r_ee_cs)
               begin
                  n_ee_cs = t_ee_ncs;
                  n_ee_st = t_ee_ncs ? EE_IDLE : EE_STANDBY;
                  if(!t_ee_ncs)
                    begin
                       n_ee_do = 1'b1;
                    end
               end
             n_ee_sk = t_ee_nsk;
             if(t_ee_ncs && t_ee_nsk && !r_ee_sk)
               begin
                  /* an SK rising edge with CS up: clock one bit (from the state the CS
                   * edge above may just have set) */
                  case(n_ee_st)
                    EE_IDLE:
                      begin
                         if(t_ee_di)
                           begin
                              n_ee_st = EE_OPCODE;
                              n_ee_n = 5'd0;
                              n_ee_sh = 16'd0;
                           end
                      end
                    EE_OPCODE:
                      begin
                         n_ee_sh = t_ee_shift;
                         n_ee_n = r_ee_n + 5'd1;
                         if(r_ee_n == 5'd1)
                           begin
                              n_ee_op = t_ee_shift[1:0];
                              n_ee_st = EE_ADDRESS;
                              n_ee_n = 5'd0;
                              n_ee_sh = 16'd0;
                           end
                      end
                    EE_ADDRESS:
                      begin
                         n_ee_sh = t_ee_shift;
                         n_ee_n = r_ee_n + 5'd1;
                         if(r_ee_n == 5'd7)
                           begin
                              /* t_ee_shift[7:0] = the address; [7:6] select the opcode-0 forms */
                              n_ee_addr = t_ee_shift[6:0];
                              n_ee_n = 5'd0;
                              n_ee_sh = 16'd0;
                              n_ee_st = EE_IDLE;
                              if(r_ee_op == 2'd2)
                                begin
                                   /* READ: the dummy 0, then D15..D0 */
                                   n_ee_sh = r_ee_mem[t_ee_shift[6:0]];
                                   n_ee_do = 1'b0;
                                   n_ee_st = EE_DATA_OUT;
                                end
                              else if((r_ee_op == 2'd1) || ((r_ee_op == 2'd0) && (t_ee_shift[7:6] == 2'd1)))
                                begin
                                   /* WRITE, WRAL */
                                   if(r_ee_wen)
                                     begin
                                        n_ee_st = EE_DATA_IN;
                                     end
                                end
                              else if(r_ee_op == 2'd3)
                                begin
                                   /* ERASE */
                                   if(r_ee_wen)
                                     begin
                                        t_ee_we = 1'b1;
                                        t_ee_waddr = t_ee_shift[6:0];
                                        t_ee_wdata = 16'hffff;
                                     end
                                end
                              else if(t_ee_shift[7:6] == 2'd2)
                                begin
                                   /* ERAL */
                                   if(r_ee_wen)
                                     begin
                                        n_ee_fill = 1'b1;
                                        n_ee_fidx = 7'd0;
                                        n_ee_fval = 16'hffff;
                                     end
                                end
                              else
                                begin
                                   /* EWEN (11) / EWDS (00) */
                                   n_ee_wen = (t_ee_shift[7:6] == 2'd3);
                                end
                           end
                      end
                    EE_DATA_IN:
                      begin
                         n_ee_sh = t_ee_shift;
                         n_ee_n = r_ee_n + 5'd1;
                         if(r_ee_n == 5'd15)
                           begin
                              if(r_ee_op == 2'd1)
                                begin
                                   t_ee_we = 1'b1;
                                   t_ee_waddr = r_ee_addr;
                                   t_ee_wdata = t_ee_shift;
                                end
                              else
                                begin
                                   n_ee_fill = 1'b1;
                                   n_ee_fidx = 7'd0;
                                   n_ee_fval = t_ee_shift;
                                end
                              n_ee_st = EE_IDLE;
                           end
                      end
                    EE_DATA_OUT:
                      begin
                         if(r_ee_n < 5'd16)
                           begin
                              n_ee_do = r_ee_sh[4'd15 - r_ee_n[3:0]];
                              n_ee_n = r_ee_n + 5'd1;
                           end
                         else
                           begin
                              n_ee_do = 1'b1;
                              n_ee_st = EE_IDLE;
                           end
                      end
                    default:
                      begin
                      end
                  endcase
               end
          end
     end // always_comb

   always_ff @(posedge clk)
     begin
        if(t_ee_we)
          begin
             r_ee_mem[t_ee_waddr] <= t_ee_wdata;
          end
        if(reset)
          begin
             r_ee_st <= EE_STANDBY;
             r_ee_cs <= 1'b0;
             r_ee_sk <= 1'b0;
             r_ee_do <= 1'b1;
             r_ee_wen <= 1'b0;
             r_ee_reg <= 4'd0;
             r_ee_sh <= 16'd0;
             r_ee_n <= 5'd0;
             r_ee_op <= 2'd0;
             r_ee_addr <= 7'd0;
             r_ee_fill <= 1'b0;
             r_ee_fidx <= 7'd0;
             r_ee_fval <= 16'd0;
          end
        else
          begin
             r_ee_st <= n_ee_st;
             r_ee_cs <= n_ee_cs;
             r_ee_sk <= n_ee_sk;
             r_ee_do <= n_ee_do;
             r_ee_wen <= n_ee_wen;
             r_ee_reg <= n_ee_reg;
             r_ee_sh <= n_ee_sh;
             r_ee_n <= n_ee_n;
             r_ee_op <= n_ee_op;
             r_ee_addr <= n_ee_addr;
             r_ee_fill <= n_ee_fill;
             r_ee_fidx <= n_ee_fidx;
             r_ee_fval <= n_ee_fval;
          end
     end // always_ff
`endif

   // ---- ds1386 clock: 100 Hz tick, BCD carry chain, then this cycle's stores ----
   always_comb
     begin
        for(j = 0; j < 16; j = j + 1)
          begin
             n_rtc[j] = r_rtc[j];
          end
        n_rtc_div = r_rtc_div + 20'd1;
        /* (2*tens + ones) mod 4 == year mod 4 */
        t_rtc_leap = ((2'({r_rtc[10][4], 1'b0}) + r_rtc[10][1:0]) == 2'd0);
        t_rtc_last_date = (r_rtc[9][4:0] == 5'h02) ? (t_rtc_leap ? 8'h29 : 8'h28) :
                          ((r_rtc[9][4:0] == 5'h04) || (r_rtc[9][4:0] == 5'h06) ||
                           (r_rtc[9][4:0] == 5'h09) || (r_rtc[9][4:0] == 5'h11)) ? 8'h30 : 8'h31;
        t_rtc_inc = 8'd0;
        if(r_rtc_div == 20'(RTC_DIV - 1))
          begin
             n_rtc_div = 20'd0;
             if(r_rtc[0] != 8'h99)
               begin
                  n_rtc[0] = bcd_inc(r_rtc[0]);                 // hundredths
               end
             else
               begin
                  n_rtc[0] = 8'h00;
                  if(r_rtc[1] != 8'h59)
                    begin
                       n_rtc[1] = bcd_inc(r_rtc[1]);            // seconds
                    end
                  else
                    begin
                       n_rtc[1] = 8'h00;
                       if(r_rtc[2] != 8'h59)
                         begin
                            n_rtc[2] = bcd_inc(r_rtc[2]);       // minutes
                         end
                       else
                         begin
                            n_rtc[2] = 8'h00;
                            if(r_rtc[4][5:0] != 6'h23)
                              begin
                                 t_rtc_inc = bcd_inc({2'd0, r_rtc[4][5:0]});
                                 n_rtc[4] = {r_rtc[4][7:6], t_rtc_inc[5:0]};   // hours (24 h)
                              end
                            else
                              begin
                                 n_rtc[4] = {r_rtc[4][7:6], 6'h00};
                                 n_rtc[6] = (r_rtc[6] == 8'h07) ? 8'h01 : bcd_inc(r_rtc[6]);  // day of week
                                 if(r_rtc[8] != t_rtc_last_date)
                                   begin
                                      n_rtc[8] = bcd_inc(r_rtc[8]);            // date
                                   end
                                 else
                                   begin
                                      n_rtc[8] = 8'h01;
                                      if(r_rtc[9][4:0] != 5'h12)
                                        begin
                                           t_rtc_inc = bcd_inc({3'd0, r_rtc[9][4:0]});
                                           n_rtc[9] = {r_rtc[9][7:5], t_rtc_inc[4:0]};  // month (EOSC/ESQW kept)
                                        end
                                      else
                                        begin
                                           n_rtc[9] = {r_rtc[9][7:5], 5'h01};
                                           n_rtc[10] = (r_rtc[10] == 8'h99) ? 8'h00 : bcd_inc(r_rtc[10]);  // year
                                        end
                                   end
                              end
                         end
                    end
               end
          end
        /* a store wins over the tick: byte (lbu/sb at reg*4+3) or word stores */
        if(sel & is_store & (offs[18:6] == 13'h1800))
          begin
             for(j = 0; j < 4; j = j + 1)
               begin
                  if(mask[4*j + 3])
                    begin
                       n_rtc[{offs[5:4], 2'(j)}] = wdata[32*j + 24 +: 8];
                    end
               end
          end
     end // always_comb

   always_ff @(posedge clk)
     begin
        if(reset)
          begin
             for(j = 0; j < 16; j = j + 1)
               begin
                  r_rtc[j] <= 8'h00;
               end
             r_rtc[6]  <= 8'h01;   // day of week 1
             r_rtc[8]  <= 8'h01;   // date 1
             r_rtc[9]  <= 8'h01;   // January
             r_rtc[10] <= 8'h90;   // 2030 (see above)
             r_rtc_div <= 20'd0;
          end
        else
          begin
             for(j = 0; j < 16; j = j + 1)
               begin
                  r_rtc[j] <= n_rtc[j];
               end
             r_rtc_div <= n_rtc_div;
          end
     end // always_ff

`ifdef VERILATOR
   // TEMP: trace HPC3-window accesses in the PBUS config regions to see what IRIX's
   // pbus-config probe reads/writes (0x00000-0x0ffff dma chan, 0x10000-0x13fff scsi
   // chan+cfg, 0x58000-0x5dfff pio data + dma/pio config).
   always_ff @(posedge clk)
     if(sel & (offs[18:12] != 7'h30) & (offs[18:12] != 7'h40) & (offs[18:12] != 7'h60))
       $display("[hpc3acc] offs=%05x st=%b mask=%04x w0=%08x w1=%08x",
                offs, is_store, mask, wdata[31:0], wdata[63:32]);
   // TEMP: trace ALL HPC3 reads except the istat0 (0x30000) flood + SCSI/DMA blocks,
   // to find where IRIX actually reads the station MAC.
   always_ff @(posedge clk)
     if(sel & ~is_store & (offs != 19'h30000)
        & ~(offs[18:15] == 4'h1)                 // 0x08000-0x0ffff / 0x10000-0x17fff DMA
        & ~((offs & 19'h78000) == 19'h40000)     // 0x40000 WD33C93
        & ~(offs[18:6] == 13'h1800))             // ds1386 clock (the PROM polls it)
       $display("[rd] offs=%05x mask=%04x rd=%08x_%08x_%08x_%08x",
                offs, mask, rdata[127:96], rdata[95:64], rdata[63:32], rdata[31:0]);
`endif

   // ---- mem-to-mem DMA copy engine (gated; see dma_memcpy.sv) ----------------
`ifdef ENABLE_HPC3_DMA
   dma_memcpy u_dma
     (.clk(clk), .reset(reset),
      .sel(sel), .is_store(is_store), .offs(offs), .mask(mask), .wdata(wdata),
      .status(w_dma_status),
      .dma_req_valid(dma_req_valid), .dma_req_addr(dma_req_addr),
      .dma_req_opcode(dma_req_opcode), .dma_req_store_data(dma_req_store_data),
      .dma_req_mask(dma_req_mask),
      .dma_rsp_valid(dma_rsp_valid), .dma_rsp_load_data(dma_rsp_load_data));
`else
   // DMA engine compiled out: tie off the master (arbiter sees a lone CPU master).
   assign w_dma_status       = 32'd0;
   assign dma_req_valid      = 1'b0;
   assign dma_req_addr       = '0;
   assign dma_req_opcode     = '0;
   assign dma_req_store_data = '0;
   assign dma_req_mask       = '0;
`endif
   /* level out to the interrupt tree (int3 local0 SCSI0); cleared by a cntl read */
   assign scsi0_hpc_intr = r_hd0_xie;

endmodule // hpc3

