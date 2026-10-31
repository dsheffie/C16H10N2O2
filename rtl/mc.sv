// -----------------------------------------------------------------------------
// mc.sv -- SGI Indy MC (memory controller) @ phys 0x1fa00000.
// Translated from the r9999 sgi_mc.cc functional model.  Big-endian IRIX uses
// the +4/+c register aliases, so register select ignores bit 2: index=(offs>>3)&1.
//
// Register-slave interface (driven by henry_soc's mem-bus FSM): on `sel` the
// 16-byte-aligned line at `offs` (mask = per-byte enables) is read (combinational
// `rdata`, per full word) and, when `is_store`, written (clocked).
// -----------------------------------------------------------------------------
`include "machine.vh"
`ifndef CORE_MHZ
`define CORE_MHZ 100   /* the PL clock in MHz; the IP28 build (50 MHz, clk50.xdc) passes CORE_MHZ=50 */
`endif
module mc
  #(parameter [31:0] MEMCFG0 = 32'h0000_203f)  // bank0 cfg as STORED (BE lw -> 0x3f200000: BVALID|RMASK=0x1f00|base0x20 -> (0x1f00+0x100)<<14 = 128 MB @ 0x08000000)
   (input  logic         clk,
    input  logic         reset,
    input  logic         sel,        // MC selected + a request this cycle
    input  logic         is_store,
    input  logic [16:0]  offs,       // line base, byte offset within MC (addr & 0x1ffff)
    input  logic [15:0]  mask,
    input  logic [127:0] wdata,
    output logic [127:0] rdata,
    // ---- bus errors (docs/bus-errors.md): the SoC reports a GIO access nothing
    //      answered; the MC latches GIO_ERROR_ADDR/STAT and raises its bus-error line ----
    input  logic         gio_err,       // 1-cycle: a GIO access timed out
    input  logic [31:0]  gio_err_addr,  // its physical address
    input  logic         cpu_err,       // 1-cycle: a CPU access hit a reserved PA (no bank, no device)
    input  logic [31:0]  cpu_err_addr,  // its physical address
    output logic         abort_en,      // CPUCTRL1.ABORT_EN: GIO time-outs enabled
    output logic         buserr,        // any error status bit set -> INT3 bus error (MC)
    // ---- MEMCFG0/1 in CPU byte order (banks 0/1 and 2/3, 16 bits each, even bank high):
    //      the SoC decodes the PROM's bank-probe window from them ----
    output logic [31:0]  memcfg0,
    output logic [31:0]  memcfg1,
    // ---- "virtual DMA" fill engine: one DRAM write port (shared arbiter master) ----
    output logic                  dma_req_valid,
    output logic [`PA_WIDTH-1:0]  dma_req_addr,
    output logic [127:0]          dma_req_store_data,
    input  logic                  dma_rsp_valid,
    // ---- VDMA (memory -> GIO): dma_engine's VDMA channel moves the data ----
    output logic                  v_go,          // 1-cycle: start (values below are CPU-order)
    output logic [31:0]           v_memadr,
    output logic [31:0]           v_size,
    output logic [31:0]           v_stride,
    output logic [31:0]           v_count,
    output logic [31:0]           v_gio,
    output logic [3:0][31:0]      v_tlb_hi,
    output logic [3:0][31:0]      v_tlb_lo,
    input  logic                  v_done,        // 1-cycle: the transfer is complete
    input  logic [31:0]           v_memadr_end,
    output logic                  v_begin,       // 1-cycle, the start store's cycle: GIO window BEGIN marker
    output logic                  dma_irq,       // INT3 local0 MC DMA: DMA_CAUSE bit 3, DMA_CTL bit 4
    // ---- VDMA usage counters for the ARM (AXI 0x22/0x23): does IRIX use the engine? ----
    output logic [31:0]           vdma_stat0,     // {non-fill starts[23:0], mode of the last one[7:0]}
    output logic [31:0]           vdma_stat1);    // {fill starts[15:0], other DMA register writes[15:0]}

   // MC sysid/rev @0x1c: store 0x13000000 so the BE lw -> 0x00000013 (MAME golden);
   // low nibble = MC rev (3), rev<5 keeps the 22/14 mconfig shifts.
`ifdef ENABLE_IP28
   // IP28: 0x15 (rev 5, EISA present), as IRIS reports: once the HPC3 says Full House
   // the IP28 PROM rejects an MC rev < 5 (r9999 sgi_mc.cc)
   localparam [31:0] MC_SYSID = 32'h15000000;
`else
   localparam [31:0] MC_SYSID = 32'h13000000;
`endif

   logic [31:0] r_cpu_control [0:1];
   logic [31:0] r_memcfg      [0:1];
   logic [31:0] r_cpu_mem_acc, r_gio_mem_acc, r_rpss_div, r_gio64_arb, r_rpss, r_eeprom_ctrl;
   /* error registers, held as the CPU sees them (MC spec 5.14-5.17); swapped on read
    * like every other register here */
   logic [31:0] r_cpu_err_addr, r_cpu_err_stat, r_gio_err_addr, r_gio_err_stat;
   localparam [31:0] GSTAT_TIME = 32'h0000_0400;   // GIO transaction timed out
   localparam [31:0] CSTAT_ADDR = 32'h0000_0400;   // CPU_ERROR_STAT.ADDR: address maps to no memory
   /* DMA ("virtual DMA", MC spec p.24) registers, stored like the rest (swapped).
    * Two modes move data:
    *   FILL|TO_HOST, to physical addresses (no DMA TLB, zoom 1, upward): the SGI
    *     PROM's power-on memory clear, by the fill engine below.  Its writes are not
    *     snooped: valid while the caches hold no DRAM lines (the PROM clears memory
    *     uncached, right after reset).
    *   memory -> GIO, upward (IRIX ng1 Ng1PixelDma: the desktop background): the
    *     VDMA channel of dma_engine (coherent reads, DMA TLB, zoom, stride) stores
    *     each doubleword into the GIO window.
    * Any other mode completes at once without moving data.  DMA_COUNT is held in CPU
    * order: SIZE sets its low half, STRIDE its zoom (MAME). */
   logic [31:0] r_dma_memadr, r_dma_size, r_dma_stride, r_dma_gio_adr, r_dma_mode;
   logic [31:0] r_dma_ctl, r_dma_cause;
   logic [31:0] r_dma_count;                   // CPU order
   logic [31:0] r_dma_tlb_hi [0:3];
   logic [31:0] r_dma_tlb_lo [0:3];
   logic        r_dma_irq;
   localparam [31:0] DMA_MODE_TO_HOST = 32'h0000_0002;
   localparam [31:0] DMA_MODE_FILL    = 32'h0000_0008;
   localparam [31:0] DMA_MODE_DIR     = 32'h0000_0010;   // 1 = upward
   /* fill engine state (below) */
   logic        r_f_busy, n_f_busy;
   logic        r_f_done, n_f_done;
   logic [31:0] r_f_addr, n_f_addr;       // next line store (CPU view, physical)
   logic [15:0] r_f_left, n_f_left;       // bytes left in this line
   logic [15:0] r_f_lines, n_f_lines;     // lines left, including this one
   logic [31:0] r_f_pat, n_f_pat;         // fill word as stored (memory order)
   logic        r_v_busy, n_v_busy;       // a VDMA transfer is in dma_engine
   logic        r_v_go, n_v_go;
   logic        t_fin;                    // a transfer completes this cycle (any mode)
   logic        t_start;
   logic [31:0] t_start_pat;
   logic [31:0] t_size, t_stride, t_mode, t_start_word, t_memadr;

   function automatic logic [31:0] bswap32(input logic [31:0] v);
      bswap32 = {v[7:0], v[15:8], v[23:16], v[31:24]};
   endfunction

   /* stored registers are byte-swapped relative to the CPU's BE view: CPUCTRL1 bit 4
    * (ABORT_EN) is bit 28 of the stored word */
   assign abort_en = r_cpu_control[1][28];
   assign memcfg0  = bswap32(r_memcfg[0]);
   assign memcfg1  = bswap32(r_memcfg[1]);
   assign buserr   = (r_gio_err_stat != 32'd0) | (r_cpu_err_stat != 32'd0);

   function automatic logic [31:0] mc_rd(input logic [16:0] o);
      logic [31:0] x;
      begin
         x = 32'd0;
         case(o)
           17'h0000,17'h0004,17'h0008,17'h000c: x = r_cpu_control[(o>>3)&1];
           17'h0018,17'h001c:                   x = MC_SYSID;
           17'h00c4,17'h00cc:                   x = r_memcfg[(o>>3)&1];
           17'h00d4:                            x = r_cpu_mem_acc;
`ifdef ENABLE_IP28
           17'h0080,17'h0084:                   x = r_gio64_arb;     // GIO64_ARB: the IP28 PROM reads its write back
`endif
           17'h00dc:                            x = r_gio_mem_acc;
           17'h0030:                            x = 32'h00000010;    // EEPROM: SDATAI high
           17'h1004:                            x = r_rpss / 32'(`CORE_MHZ / 10);  // RPSS: one tick per 100 ns
           17'h00e0,17'h00e4:                   x = bswap32(r_cpu_err_addr);   // CPU_ERROR_ADDR
           17'h00e8,17'h00ec:                   x = bswap32(r_cpu_err_stat);   // CPU_ERROR_STAT
           17'h00f0,17'h00f4:                   x = bswap32(r_gio_err_addr);   // GIO_ERROR_ADDR
           17'h00f8,17'h00fc:                   x = bswap32(r_gio_err_stat);   // GIO_ERROR_STAT
           17'h2000,17'h2004,17'h2008,17'h200c: x = r_dma_memadr;
           17'h2010,17'h2014:                   x = r_dma_size;
           17'h2018,17'h201c:                   x = r_dma_stride;
           17'h2020,17'h2024,17'h2028,17'h202c: x = r_dma_gio_adr;
           17'h2030,17'h2034:                   x = r_dma_mode;
           17'h2038,17'h203c:                   x = bswap32(r_dma_count);
           17'h0160,17'h0164:                   x = r_dma_cause;
           17'h0168,17'h016c:                   x = r_dma_ctl;
           17'h0180,17'h0184:                   x = r_dma_tlb_hi[0];
           17'h0188,17'h018c:                   x = r_dma_tlb_lo[0];
           17'h0190,17'h0194:                   x = r_dma_tlb_hi[1];
           17'h0198,17'h019c:                   x = r_dma_tlb_lo[1];
           17'h01a0,17'h01a4:                   x = r_dma_tlb_hi[2];
           17'h01a8,17'h01ac:                   x = r_dma_tlb_lo[2];
           17'h01b0,17'h01b4:                   x = r_dma_tlb_hi[3];
           17'h01b8,17'h01bc:                   x = r_dma_tlb_lo[3];
           17'h2048,17'h204c:                   x = bswap32({25'd0, r_f_busy | r_v_busy, 2'd0, r_f_done, 3'd0}); // DMA_RUN: RUNNING bit 6, done bit 3
           default:                             x = 32'd0;
         endcase
         mc_rd = x;
      end
   endfunction

   integer i;

   always_comb begin
      rdata = '0;
      for(i = 0; i < 4; i = i + 1)
        if(mask[4*i +: 4] == 4'hf)
          rdata[32*i +: 32] = mc_rd(offs + 17'(4*i));
   end

   always_ff @(posedge clk) begin
      r_rpss <= reset ? 32'd0 : (r_rpss + 32'd1);
      if(reset) begin
         r_cpu_control[0] <= 32'd0; r_cpu_control[1] <= 32'd0;
         r_memcfg[0] <= MEMCFG0;    r_memcfg[1] <= 32'd0;
         r_cpu_mem_acc <= 32'd0; r_gio_mem_acc <= 32'd0;
         r_rpss_div <= 32'd0; r_gio64_arb <= 32'd0; r_eeprom_ctrl <= 32'd0;
         r_cpu_err_addr <= 32'd0; r_cpu_err_stat <= 32'd0;
         r_gio_err_addr <= 32'd0; r_gio_err_stat <= 32'd0;
         r_dma_memadr <= 32'd0; r_dma_size <= 32'd0; r_dma_stride <= 32'd0;
         r_dma_gio_adr <= 32'd0; r_dma_mode <= 32'd0;
         r_dma_ctl <= 32'd0; r_dma_cause <= 32'd0; r_dma_count <= 32'd0; r_dma_irq <= 1'b0;
         for(i = 0; i < 4; i = i + 1)
           begin
              r_dma_tlb_hi[i] <= 32'd0;
              r_dma_tlb_lo[i] <= 32'd0;
           end
      end
      else if(sel & is_store) begin
         for(i = 0; i < 4; i = i + 1)
           if(mask[4*i +: 4] == 4'hf)
             case(offs + 17'(4*i))
               17'h0000,17'h0004,17'h0008,17'h000c: r_cpu_control[((offs + 17'(4*i))>>3)&1] <= wdata[32*i +: 32];
               17'h002c:                            r_rpss_div    <= wdata[32*i +: 32];
               17'h0084:                            r_gio64_arb   <= wdata[32*i +: 32];
               17'h00c4,17'h00cc:                   r_memcfg[((offs + 17'(4*i))>>3)&1] <= wdata[32*i +: 32];
               17'h00d4:                            r_cpu_mem_acc <= wdata[32*i +: 32];
               17'h00dc:                            r_gio_mem_acc <= wdata[32*i +: 32];
               17'h0030:                            r_eeprom_ctrl <= wdata[32*i +: 32];
               17'h00e8,17'h00ec:                   r_cpu_err_stat <= 32'd0;       // CLR_ERROR_STAT (CPU)
               17'h00f8,17'h00fc:                   r_gio_err_stat <= 32'd0;       // CLR_ERROR_STAT (GIO)
               17'h2000,17'h2004,17'h2008,17'h200c: r_dma_memadr  <= wdata[32*i +: 32];
               17'h2010,17'h2014:
                 begin
                    r_dma_size  <= wdata[32*i +: 32];
                    r_dma_count[15:0] <= bswap32(wdata[32*i +: 32]) & 32'h0000ffff;
                 end
               17'h2018,17'h201c:
                 begin
                    r_dma_stride <= wdata[32*i +: 32];
                    r_dma_count[31:16] <= (bswap32(wdata[32*i +: 32]) >> 16) & 32'h000003ff;
                 end
               17'h2038,17'h203c:                   r_dma_count   <= bswap32(wdata[32*i +: 32]);
               17'h0160,17'h0164:                   r_dma_cause   <= wdata[32*i +: 32];
               17'h0168,17'h016c:                   r_dma_ctl     <= wdata[32*i +: 32];
               17'h0180,17'h0184:                   r_dma_tlb_hi[0] <= wdata[32*i +: 32];
               17'h0188,17'h018c:                   r_dma_tlb_lo[0] <= wdata[32*i +: 32];
               17'h0190,17'h0194:                   r_dma_tlb_hi[1] <= wdata[32*i +: 32];
               17'h0198,17'h019c:                   r_dma_tlb_lo[1] <= wdata[32*i +: 32];
               17'h01a0,17'h01a4:                   r_dma_tlb_hi[2] <= wdata[32*i +: 32];
               17'h01a8,17'h01ac:                   r_dma_tlb_lo[2] <= wdata[32*i +: 32];
               17'h01b0,17'h01b4:                   r_dma_tlb_hi[3] <= wdata[32*i +: 32];
               17'h01b8,17'h01bc:                   r_dma_tlb_lo[3] <= wdata[32*i +: 32];
               17'h2020,17'h2024,17'h2028,17'h202c: r_dma_gio_adr <= wdata[32*i +: 32];
               17'h2030,17'h2034:                   r_dma_mode    <= wdata[32*i +: 32];
               default: /* unhandled: ignore */ ;
             endcase
      end
      /* a time-out reported this cycle wins over a clear in the same cycle */
      if(!reset & gio_err) begin
         r_gio_err_addr <= gio_err_addr;
         r_gio_err_stat <= r_gio_err_stat | GSTAT_TIME;
      end
      /* MC spec 5.15: a CPU access that maps to no memory latches CPU_ERROR_ADDR and
       * sets CPU_ERROR_STAT.ADDR (bus-error response on a read, interrupt on a write);
       * unlike a GIO time-out it is not gated by ABORT_EN */
      if(!reset & cpu_err) begin
         r_cpu_err_addr <= cpu_err_addr;
         r_cpu_err_stat <= r_cpu_err_stat | CSTAT_ADDR;
      end
      /* DMA_CAUSE: a CPU write of 0 clears the interrupt */
      if(!reset & sel & is_store)
        begin
           for(i = 0; i < 4; i = i + 1)
             begin
                if((mask[4*i +: 4] == 4'hf) && (((offs + 17'(4*i)) & ~17'h4) == 17'h0160) &&
                   (wdata[32*i +: 32] == 32'd0))
                  begin
                     r_dma_irq <= 1'b0;
                  end
             end
        end
      /* a VDMA transfer's end: DMA_MEMADR moves past it, SIZE keeps only the width
       * and COUNT reads 0 (MAME); any completion interrupts if DMA_CTL bit 4 */
      if(!reset & v_done)
        begin
           r_dma_memadr      <= bswap32(v_memadr_end);
           r_dma_size[15:0]  <= 16'd0;
           r_dma_count       <= 32'd0;
        end
      if(!reset & t_fin & r_dma_ctl[28])
        begin
           r_dma_cause <= r_dma_cause | 32'h0800_0000;   /* CPU bit 3 */
           r_dma_irq   <= 1'b1;
        end
   end
   // ---- fill engine ----
   /* A start is a write to DMA_GIO_ADRS (0x2028, "GIO address + start") or a 1 to
    * DMA_START (0x2040).  The start uses the registers as already written: the
    * register file and the engine both take this cycle's store at the edge, so the
    * engine reads the new GIO address straight from wdata when the start carries it. */

   always_comb
     begin
        t_start      = 1'b0;
        t_start_pat  = r_dma_gio_adr;
        t_start_word = 32'd0;
        if(sel & is_store)
          begin
             for(i = 0; i < 4; i = i + 1)
               begin
                  if(mask[4*i +: 4] == 4'hf)
                    begin
                       if(((offs + 17'(4*i)) == 17'h2028) || ((offs + 17'(4*i)) == 17'h202c))
                         begin
                            t_start     = 1'b1;
                            t_start_pat = wdata[32*i +: 32];
                         end
                       else if(((offs + 17'(4*i)) == 17'h2040) || ((offs + 17'(4*i)) == 17'h2044))
                         begin
                            t_start_word = bswap32(wdata[32*i +: 32]);
                            if(t_start_word[0])
                              begin
                                 t_start = 1'b1;
                              end
                         end
                    end
               end
          end
        t_size   = bswap32(r_dma_size);
        t_stride = bswap32(r_dma_stride);
        t_mode   = bswap32(r_dma_mode);
        t_memadr = bswap32(r_dma_memadr);

        n_f_busy  = r_f_busy;
        n_f_done  = r_f_done;
        n_f_addr  = r_f_addr;
        n_f_left  = r_f_left;
        n_f_lines = r_f_lines;
        n_f_pat   = r_f_pat;
        n_v_busy  = r_v_busy;
        n_v_go    = 1'b0;
        t_fin     = 1'b0;
        if(t_start && !r_f_busy && !r_v_busy)
          begin
             n_f_addr  = t_memadr;
             n_f_left  = t_size[15:0];
             n_f_lines = t_size[31:16];
             n_f_pat   = t_start_pat;
             n_f_done  = 1'b0;
             if(((t_mode & DMA_MODE_FILL) != 32'd0) && ((t_mode & DMA_MODE_TO_HOST) != 32'd0) &&
                (t_size[31:16] != 16'd0) && (t_size[15:0] != 16'd0))
               begin
                  n_f_busy = 1'b1;
               end
`ifndef DISABLE_NEWPORT
             /* (DISABLE_NEWPORT: no VDMA channel -- memory -> GIO falls through to
              * "complete at once" below, as before VDMA existed) */
             else if(((t_mode & (DMA_MODE_FILL | DMA_MODE_TO_HOST)) == 32'd0) && ((t_mode & DMA_MODE_DIR) != 32'd0))
               begin
                  /* memory -> GIO: the channel starts next cycle, when this store's
                   * register writes (the GIO address) have landed */
                  n_v_busy = 1'b1;
                  n_v_go   = 1'b1;
               end
`endif
             else
               begin
                  n_f_done = 1'b1;    /* unsupported mode or empty: complete at once */
                  t_fin    = 1'b1;
               end
          end
        else if(r_v_busy && v_done)
          begin
             n_v_busy = 1'b0;
             n_f_done = 1'b1;
             t_fin    = 1'b1;
          end
        else if(r_f_busy && dma_rsp_valid)
          begin
             /* one 16-byte line store done */
             if(r_f_left <= 16'd16)
               begin
                  if(r_f_lines == 16'd1)
                    begin
                       n_f_busy = 1'b0;
                       n_f_done = 1'b1;
                       t_fin    = 1'b1;
                    end
                  else
                    begin
                       n_f_lines = r_f_lines - 16'd1;
                       n_f_left  = t_size[15:0];
                       /* next line: the end of this one + the signed stride */
                       n_f_addr  = r_f_addr + 32'd16 + {{16{t_stride[15]}}, t_stride[15:0]};
                    end
               end
             else
               begin
                  n_f_left = r_f_left - 16'd16;
                  n_f_addr = r_f_addr + 32'd16;
               end
          end
     end // always_comb

   assign dma_req_valid      = r_f_busy;
   assign v_go               = r_v_go;
   assign v_begin            = n_v_go;
   assign v_memadr           = bswap32(r_dma_memadr);
   assign v_size             = bswap32(r_dma_size);
   assign v_stride           = bswap32(r_dma_stride);
   assign v_count            = r_dma_count;
   assign v_gio              = bswap32(r_dma_gio_adr);
   assign dma_irq            = r_dma_irq;
   always_comb
     begin
        for(int e = 0; e < 4; e++)
          begin
             v_tlb_hi[e] = bswap32(r_dma_tlb_hi[e]);
             v_tlb_lo[e] = bswap32(r_dma_tlb_lo[e]);
          end
     end // always_comb
   assign dma_req_addr       = `PA_WIDTH'({r_f_addr[31:4], 4'd0});
   assign dma_req_store_data = {r_f_pat, r_f_pat, r_f_pat, r_f_pat};

   /* VDMA usage counters.  A start is any of the engine's starts or the 0x2070 alias
    * ("GIO address + default parameters + start", mode 0x28), which the fill engine
    * does not act on but IRIX might use.  Fill = mode FILL|TO_HOST (the PROM's clear). */
   logic [23:0] r_vdma_nfill, n_vdma_nfill;
   logic [7:0]  r_vdma_mode, n_vdma_mode;
   logic [15:0] r_vdma_fill, n_vdma_fill;
   logic [15:0] r_vdma_regw, n_vdma_regw;
   logic        t_vdma_alias, t_vdma_regw;
   logic [7:0]  t_vdma_mode;

   always_comb
     begin
        t_vdma_alias = sel & is_store & (offs == 17'h2070) & (mask != 16'd0);
        t_vdma_regw  = sel & is_store & ((offs[16:8] == 9'h020) ||
                                         ((offs >= 17'h0150) && (offs < 17'h01c0)));
        t_vdma_mode  = t_vdma_alias ? 8'h28 : t_mode[7:0];
        n_vdma_nfill = r_vdma_nfill;
        n_vdma_mode  = r_vdma_mode;
        n_vdma_fill  = r_vdma_fill;
        n_vdma_regw  = r_vdma_regw;
        if(t_start || t_vdma_alias)
          begin
             if((t_vdma_mode & 8'h0a) == 8'h0a)
               begin
                  n_vdma_fill = r_vdma_fill + 16'd1;
               end
             else
               begin
                  n_vdma_nfill = r_vdma_nfill + 24'd1;
                  n_vdma_mode  = t_vdma_mode;
               end
          end
        else if(t_vdma_regw)
          begin
             n_vdma_regw = r_vdma_regw + 16'd1;
          end
     end // always_comb

   always_ff @(posedge clk)
     begin
        if(reset)
          begin
             r_vdma_nfill <= 24'd0;
             r_vdma_mode  <= 8'd0;
             r_vdma_fill  <= 16'd0;
             r_vdma_regw  <= 16'd0;
          end
        else
          begin
             r_vdma_nfill <= n_vdma_nfill;
             r_vdma_mode  <= n_vdma_mode;
             r_vdma_fill  <= n_vdma_fill;
             r_vdma_regw  <= n_vdma_regw;
          end
     end // always_ff

   assign vdma_stat0 = {r_vdma_nfill, r_vdma_mode};
   assign vdma_stat1 = {r_vdma_fill, r_vdma_regw};

   always_ff @(posedge clk)
     begin
        if(reset)
          begin
             r_f_busy  <= 1'b0;
             r_f_done  <= 1'b0;
             r_f_addr  <= 32'd0;
             r_f_left  <= 16'd0;
             r_f_lines <= 16'd0;
             r_f_pat   <= 32'd0;
             r_v_busy  <= 1'b0;
             r_v_go    <= 1'b0;
          end
        else
          begin
             r_f_busy  <= n_f_busy;
             r_f_done  <= n_f_done;
             r_f_addr  <= n_f_addr;
             r_f_left  <= n_f_left;
             r_f_lines <= n_f_lines;
             r_f_pat   <= n_f_pat;
             r_v_busy  <= n_v_busy;
             r_v_go    <= n_v_go;
          end
     end // always_ff

`ifdef VERILATOR
   always_ff @(posedge clk)
     begin
        if(t_start && !r_f_busy)
          begin
             $display("[mc-dma] start memadr=%08x size=%08x stride=%08x mode=%08x pat=%08x",
                      t_memadr, t_size, t_stride, t_mode, bswap32(t_start_pat));
             if((t_memadr[3:0] != 4'd0) || (t_size[3:0] != 4'd0))
               begin
                  $display("[mc-dma] WARNING: fill not 16-byte aligned; the engine writes whole lines");
               end
          end
        if(r_f_busy && !n_f_busy)
          begin
             $display("[mc-dma] fill done, last line %08x", r_f_addr);
          end
     end // always_ff
`endif
endmodule // mc
