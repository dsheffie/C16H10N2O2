`include "machine.vh"
// -----------------------------------------------------------------------------
// enet_dma.sv -- HPC3 ENET RX/TX DMA channels: walk the descriptor ring/chain in
// DRAM through the henry arbiter (a REAL ordered DRAM master) and move frame
// bytes between memory and the host-side tap.
//
// Counterpart to scsi_dma.sv, and for the same reason: previously ENET was
// "host-served" -- henry_tb / the ARM PS wrote the guest's RX buffers DIRECTLY
// via a memory callback, completely bypassing the RTL.  That makes the frame
// data invisible to the L2, so the L2 can serve a stale line for a buffer the
// NIC just filled, and NOTHING in software can fix it (Config.SC hides the L2
// from IRIX, so the kernel issues zero secondary-cache ops).  Routing the writes
// through the arbiter makes ENET coherent BY CONSTRUCTION -- the same ordered
// port the CPU uses -- and lets the snoop FIFO see every line.
//
// SPLIT OF WORK (same as the disk): the MEDIA stays in the host.  The host owns
// the tap, decides which frames arrive, and supplies/consumes frame bytes as
// 16-byte beats.  Only the MEMORY MOVEMENT is RTL.
//
// Descriptor (12 bytes, BIG-ENDIAN, one per 16-byte line at NBDP):
//   +0  BP  buffer pointer (physical)
//   +4  BC  COUNT[13:0] | ROWN(14) | ETXD(15) | XIE(29) | EOX(31)
//   +8  DP  next descriptor
//
// RX: a descriptor is usable only if ROWN=1 (HPC owns it).  The host presents the
// frame ALREADY FORMATTED as the driver expects -- [2 pad][frame][1 status] --
// so the engine just streams `rx_len` bytes to BP and does the beat/mask
// arithmetic.  On completion BC is written back with ROWN CLEARED and COUNT set
// to the residual, which is the handshake that gives the buffer to the CPU.
// TX: gather COUNT bytes from each BP, set ETXD in BC, stop at EOX.
//
// NBDP must be 16-byte aligned; BP may start at any byte in both directions (IRIX
// RX buffers sit at BP mod 16 = 8).  Lengths need not be multiples of 16.
// -----------------------------------------------------------------------------
module enet_dma
   (input  logic         clk,
    input  logic         reset,
    // ---- RX control ----
    input  logic         rx_go,          // 1-cycle pulse: deposit one frame
    input  logic [31:0]  rx_nbdp,        // ring position to try
    input  logic [13:0]  rx_len,         // bytes to write (= 2 + frame + 1, host-formatted)
    output logic         rx_busy,
    output logic         rx_done,        // 1-cycle: frame delivered, descriptor released
    output logic         rx_dropped,     // 1-cycle: ring full (ROWN=0) or buffer too small
    output logic [31:0]  rx_crbdp,       // descriptor just filled (guest reads @HPC3 0x18000)
    output logic [31:0]  rx_next_nbdp,   // ring position after this frame
    // ---- TX control ----
    input  logic         tx_go,          // 1-cycle pulse: transmit the chain at tx_nbdp
    input  logic [31:0]  tx_nbdp,
    output logic         tx_busy,
    output logic         tx_done,        // 1-cycle when the chain completes
    output logic [13:0]  tx_len,         // exact frame bytes of the last chain (valid at tx_done)
    output logic         irq,            // 1-cycle if the finishing descriptor had XIE
    // ---- DMA master -> henry DRAM arbiter ----
    output logic                  dma_req_valid,
    output logic [`PA_WIDTH-1:0]  dma_req_addr,
    output logic [4:0]            dma_req_opcode,     // 4 = line load, 7 = line store
    output logic [127:0]          dma_req_store_data,
    output logic [15:0]           dma_req_mask,
    input  logic                  dma_rsp_valid,
    input  logic [127:0]          dma_rsp_load_data,
    // ---- host side: 16-byte beat stream (the tap is the media) ----
    output logic         rx_rd_en,       // RX: pulse, consume rx_rd_data this cycle
    input  logic [127:0] rx_rd_data,     // RX: host -> mem beat
    input  logic         rx_rd_valid,    // RX: a beat is available; else stall
    output logic         tx_wr_en,       // TX: pulse, tx_wr_data valid this cycle
    output logic [127:0] tx_wr_data,     // TX: mem -> host beat
    input  logic         tx_wr_full);    // TX: host FIFO full -> hold the beat

   typedef enum logic [3:0] {
      S_IDLE     = 4'd0,
      S_RX_DESC  = 4'd1,   // read the RX descriptor @ r_nbdp, check ROWN
      S_RX_BEAT  = 4'd2,   // pull a host beat
      S_RX_MEM   = 4'd3,   // store the beat to mem[bp]
      S_RX_WB    = 4'd4,   // write BC back: clear ROWN, set residual
      S_TX_DESC  = 4'd5,   // read the TX descriptor @ r_nbdp
      S_TX_MEM   = 4'd6,   // load mem[bp]
      S_TX_HOST  = 4'd7,   // push the beat to the host
      S_TX_WB    = 4'd8,   // write BC back: set ETXD
      S_NEXT     = 4'd9,   // advance to dp or finish
      S_DONE     = 4'd10,
      S_DROP     = 4'd11,  // RX: ring full / buffer unusable
      S_TX_FLUSH = 4'd12,  // TX: push the final partial beat, then done
      S_RX_DRAIN = 4'd13   // RX: pop the frame's unused host beats (drop/clamp)
   } state_t;

   state_t        r_state, n_state;
   logic [31:0]   r_nbdp,  n_nbdp;      // current descriptor address
   logic [31:0]   r_bp,    n_bp;        // current buffer cursor
   logic [13:0]   r_cnt,   n_cnt;       // bytes remaining in this descriptor
   logic [31:0]   r_dp,    n_dp;        // next descriptor
   logic [31:0]   r_bc,    n_bc;        // the descriptor's BC word (for read-modify-write)
   logic [13:0]   r_bufsz, n_bufsz;     // RX: buffer residual (size - frame bytes)
   logic          r_eox,   n_eox;
   logic          r_xie,   n_xie;
   logic          r_done,  n_done;
   logic          r_txdone,n_txdone;
   logic          r_drop,  n_drop;
   logic          r_irq,   n_irq;
   logic [31:0]   r_crbdp, n_crbdp;
   logic [7:0]    r_desc_cnt, n_desc_cnt;   // runaway-chain guard
   /* TX byte packer.  A TX buffer can start at any byte (Linux maps skb->data, which
    * the stack places 2 bytes into a line for IP alignment; IRIX mbuf chains split a
    * frame at arbitrary bytes), but the DRAM port returns whole aligned 16B lines.
    * Each load contributes min(16 - bp[3:0], cnt) bytes, packed into a 32B
    * accumulator (memory byte b in bits [8b+7:8b]) across descriptor boundaries; a
    * full 16B beat goes to the host, and the chain's tail goes out as a final
    * partial beat.  tx_len is the exact frame length. */
   logic [255:0]  r_acc,   n_acc;
   logic [5:0]    r_acc_n, n_acc_n;     // valid bytes in r_acc (< 16 between loads)
   logic [13:0]   r_txlen, n_txlen;
   logic [3:0]    t_tx_off;
   logic [4:0]    t_tx_take;
   logic [127:0]  t_tx_bytes;
   /* RX unpacker: the mirror image.  Host beats land in the same accumulator; each
    * store writes min(16 - bp[3:0], cnt) bytes into the aligned line holding bp,
    * shifted up to bp[3:0] and byte-masked, so nothing outside [BP, BP+len) is
    * touched.  r_rx_left counts the host beats of this frame still in the FIFO:
    * all of them are popped even when the frame is dropped or clamped, or they
    * would become the head of the next frame. */
   logic [10:0]   r_rx_left, n_rx_left;
   logic          r_rx_drop, n_rx_drop;
   logic [3:0]    t_rx_off;
   logic [4:0]    t_rx_need;
   /* rx_go / tx_go are 1-cycle pulses but are only taken in S_IDLE, with RX first:
    * a kick that arrived while the engine was busy (or in the same cycle as the
    * other one) was DROPPED -- the guest's transmits were lost behind host traffic
    * (Linux: TX packets 0, NETDEV WATCHDOG), and a lost rx_go stalls the host's RX
    * servicer forever.  Latch them until started. */
   logic          r_rx_pend, n_rx_pend;
   logic          r_tx_pend, n_tx_pend;

   // descriptor fields: BE in DRAM, byte-swap each 32-bit lane of the line
   wire [31:0] w_bp = bswap32(dma_rsp_load_data[31:0]);
   wire [31:0] w_bc = bswap32(dma_rsp_load_data[63:32]);
   wire [31:0] w_dp = bswap32(dma_rsp_load_data[95:64]);

   localparam logic [31:0] BC_COUNT = 32'h00003fff;
   localparam logic [31:0] BC_ROWN  = 32'h00004000;
   localparam logic [31:0] BC_ETXD  = 32'h00008000;

   /* BC lives at descriptor bytes 4..7, i.e. lane 1 of the 16-byte line.
    * Write it back with a byte mask so the neighbouring BP/DP words are untouched
    * -- a full-line store would race the CPU writing the ring. */
   localparam logic [15:0] BC_MASK = 16'h00f0;

   /* RX release: clear ROWN (hand the buffer to the CPU), set COUNT = residual,
    * preserve every other flag bit. TX: just set ETXD. */
   wire [31:0] w_bc_rx_wb = (r_bc & ~BC_ROWN & ~BC_COUNT) |
                            ({18'd0, r_bufsz} & BC_COUNT);
   wire [31:0] w_bc_tx_wb = r_bc | BC_ETXD;
   wire [31:0] w_bc_wb    = (r_state == S_TX_WB) ? w_bc_tx_wb : w_bc_rx_wb;

   always_comb
     begin
	n_state    = r_state;
	n_nbdp     = r_nbdp;
	n_bp       = r_bp;
	n_cnt      = r_cnt;
	n_dp       = r_dp;
	n_bc       = r_bc;
	n_bufsz    = r_bufsz;
	n_eox      = r_eox;
	n_xie      = r_xie;
	n_crbdp    = r_crbdp;
	n_desc_cnt = r_desc_cnt;
	n_acc      = r_acc;
	n_acc_n    = r_acc_n;
	n_txlen    = r_txlen;
	n_rx_left  = r_rx_left;
	n_rx_drop  = r_rx_drop;
	t_rx_off   = r_bp[3:0];
	t_rx_need  = ({1'b0, r_cnt} < (5'd16 - {1'b0, t_rx_off})) ? r_cnt[4:0] : (5'd16 - {1'b0, t_rx_off});
	t_tx_off   = r_bp[3:0];
	t_tx_take  = ({1'b0, r_cnt} < (5'd16 - {1'b0, t_tx_off})) ? r_cnt[4:0] : (5'd16 - {1'b0, t_tx_off});
	t_tx_bytes = (dma_rsp_load_data >> {t_tx_off, 3'd0}) & ({128{1'b1}} >> {(5'd16 - t_tx_take), 3'd0});
	n_rx_pend = r_rx_pend | rx_go;
	n_tx_pend = r_tx_pend | tx_go;
	n_done     = 1'b0;
	n_txdone   = 1'b0;
	n_drop     = 1'b0;
	n_irq      = 1'b0;

	dma_req_valid      = 1'b0;
	dma_req_addr       = {{(`PA_WIDTH-32){1'b0}}, r_nbdp};
	dma_req_opcode     = 5'd4;
	dma_req_store_data = 128'd0;
	dma_req_mask       = 16'hffff;
	rx_rd_en           = 1'b0;
	tx_wr_en           = 1'b0;
	tx_wr_data         = 128'd0;

	case(r_state)
	  S_IDLE:
	    begin
	       if(r_rx_pend | rx_go)
		 begin
		    n_nbdp     = rx_nbdp;
		    n_cnt      = rx_len;
		    n_desc_cnt = 8'd0;
		    n_rx_pend  = 1'b0;
		    n_acc      = 256'd0;
		    n_acc_n    = 6'd0;
		    n_rx_left  = 11'((rx_len + 14'd15) >> 4);
		    n_rx_drop  = 1'b0;
		    n_state    = S_RX_DESC;
		 end
	       else if(r_tx_pend | tx_go)
		 begin
		    n_nbdp     = tx_nbdp;
		    n_desc_cnt = 8'd0;
		    n_tx_pend  = 1'b0;
		    n_acc      = 256'd0;
		    n_acc_n    = 6'd0;
		    n_txlen    = 14'd0;
		    n_state    = S_TX_DESC;
		 end
	    end
	  S_RX_DESC:
	    begin                                   // read descriptor, check ownership
	       dma_req_valid  = 1'b1;
	       dma_req_addr   = {{(`PA_WIDTH-32){1'b0}}, r_nbdp};
	       dma_req_opcode = 5'd4;
	       if(dma_rsp_valid)
		 begin
		    n_bp    = w_bp;
		    n_bc    = w_bc;
		    n_dp    = w_dp;
		    n_bufsz = w_bc[13:0];
		    n_xie   = w_bc[29];
		    n_crbdp = r_nbdp;
		    /* ROWN=0 -> the CPU still owns this buffer: the ring is full and
		     * the frame is dropped, exactly as real hardware does.  A buffer
		     * smaller than [2 pad][>=0 frame][1 status] is unusable and is
		     * treated the same (a torn/stale descriptor reads as COUNT=0). */
		    if(!w_bc[14] || (w_bc[13:0] < 14'd3))
		      begin
			 n_rx_drop = 1'b1;
			 n_state   = S_RX_DRAIN;
		      end
		    else
		      begin
			 /* clamp an oversized frame to the buffer */
			 if(r_cnt > w_bc[13:0])
			   begin
			      n_cnt = w_bc[13:0];
			   end
			 /* the release writes COUNT = residual = buffer - bytes written
			  * (Linux: len = PKT_BUF_SZ - COUNT - 3).  r_cnt counts down to 0
			  * by the writeback, so capture the residual now. */
			 n_bufsz = w_bc[13:0] - n_cnt;
			 n_state = S_RX_BEAT;
		      end
		 end
	    end
	  S_RX_BEAT:
	    begin                                   // enough bytes for the next store? else pull a beat
	       if(r_acc_n >= {1'b0, t_rx_need})
		 begin
		    n_state = S_RX_MEM;
		 end
	       else if(rx_rd_valid)
		 begin
		    rx_rd_en  = 1'b1;
		    n_acc     = r_acc | ({128'd0, rx_rd_data} << {r_acc_n, 3'd0});
		    n_acc_n   = r_acc_n + 6'd16;
		    n_rx_left = r_rx_left - 11'd1;
		    n_state   = S_RX_MEM;
		 end
	    end
	  S_RX_MEM:
	    begin                                   // store up to the end of bp's line
	       dma_req_valid      = 1'b1;
	       dma_req_addr       = {{(`PA_WIDTH-32){1'b0}}, r_bp[31:4], 4'd0};
	       dma_req_opcode     = 5'd7;
	       dma_req_store_data = r_acc[127:0] << {t_rx_off, 3'd0};
	       dma_req_mask       = 16'(((17'd1 << t_rx_need) - 17'd1) << t_rx_off);
	       if(dma_rsp_valid)
		 begin
		    n_acc   = r_acc >> {t_rx_need, 3'd0};
		    n_acc_n = r_acc_n - {1'b0, t_rx_need};
		    n_bp    = r_bp + {27'd0, t_rx_need};
		    n_cnt   = r_cnt - {9'd0, t_rx_need};
		    n_state = (r_cnt == {9'd0, t_rx_need}) ? S_RX_DRAIN : S_RX_BEAT;
		 end
	    end
	  S_RX_DRAIN:
	    begin                                   // discard what the store did not use
	       if(r_rx_left != 11'd0)
		 begin
		    if(rx_rd_valid)
		      begin
			 rx_rd_en  = 1'b1;
			 n_rx_left = r_rx_left - 11'd1;
		      end
		 end
	       else
		 begin
		    n_state = r_rx_drop ? S_DROP : S_RX_WB;
		 end
	    end
	  S_RX_WB:
	    begin                                   // release the buffer to the CPU
	       dma_req_valid      = 1'b1;
	       dma_req_addr       = {{(`PA_WIDTH-32){1'b0}}, r_nbdp};
	       dma_req_opcode     = 5'd7;
	       dma_req_store_data = {64'd0, bswap32(w_bc_wb), 32'd0};   // BC = bytes 4..7 = bits [63:32] (BC_MASK)
	       dma_req_mask       = BC_MASK;
	       if(dma_rsp_valid)
		 begin
		    n_nbdp  = r_dp;                // ring: always advance
		    n_done  = 1'b1;                // pulse HERE: in S_DONE, r_state==S_DONE
		    n_irq   = r_xie;               // so a "which state did we come from"
		    n_state = S_IDLE;              // test there is always false
		 end
	    end
	  S_TX_DESC:
	    begin
	       dma_req_valid  = 1'b1;
	       dma_req_addr   = {{(`PA_WIDTH-32){1'b0}}, r_nbdp};
	       dma_req_opcode = 5'd4;
	       if(dma_rsp_valid)
		 begin
		    n_bp    = w_bp;
		    n_bc    = w_bc;
		    n_cnt   = w_bc[13:0];
		    n_dp    = w_dp;
		    n_eox   = w_bc[31];
		    n_xie   = w_bc[29];
		    n_state = (w_bc[13:0] == 14'd0) ? S_TX_WB : S_TX_MEM;
		 end
	    end
	  S_TX_MEM:
	    begin                                   // load the aligned line holding bp
	       dma_req_valid  = 1'b1;
	       dma_req_addr   = {{(`PA_WIDTH-32){1'b0}}, r_bp[31:4], 4'd0};
	       dma_req_opcode = 5'd4;
	       if(dma_rsp_valid)
		 begin
		    n_acc   = r_acc | ({128'd0, t_tx_bytes} << {r_acc_n, 3'd0});
		    n_acc_n = r_acc_n + {1'b0, t_tx_take};
		    n_bp    = r_bp + {27'd0, t_tx_take};
		    n_cnt   = r_cnt - {9'd0, t_tx_take};
		    n_txlen = r_txlen + {9'd0, t_tx_take};
		    n_state = S_TX_HOST;
		 end
	    end
	  S_TX_HOST:
	    begin                                   // a full beat is ready: push it
	       /* the host FIFO drops a push when full, so hold the beat until there is
		* room -- the ARM pops over AXI-Lite, far slower than the DRAM loads */
	       if(r_acc_n >= 6'd16)
		 begin
		    if(!tx_wr_full)
		      begin
			 tx_wr_en   = 1'b1;
			 tx_wr_data = r_acc[127:0];
			 n_acc      = r_acc >> 128;
			 n_acc_n    = r_acc_n - 6'd16;
			 n_state    = (r_cnt == 14'd0) ? S_TX_WB : S_TX_MEM;
		      end
		 end
	       else
		 begin
		    n_state = (r_cnt == 14'd0) ? S_TX_WB : S_TX_MEM;
		 end
	    end
	  S_TX_WB:
	    begin                                   // mark the buffer transmitted
	       dma_req_valid      = 1'b1;
	       dma_req_addr       = {{(`PA_WIDTH-32){1'b0}}, r_nbdp};
	       dma_req_opcode     = 5'd7;
	       dma_req_store_data = {64'd0, bswap32(w_bc_wb), 32'd0};   // BC = bytes 4..7 = bits [63:32] (BC_MASK)
	       dma_req_mask       = BC_MASK;
	       if(dma_rsp_valid)
		 begin
		    n_state = S_NEXT;
		 end
	    end
	  S_NEXT:
	    /* EOX, a null link (stale/garbage descriptor), or a runaway chain -> stop */
	    if(r_eox | (r_dp == 32'd0) | (r_desc_cnt == 8'hff))
	      begin
		 if(r_acc_n != 6'd0)
		   begin
		      n_state  = S_TX_FLUSH;
		   end
		 else
		   begin
		      n_txdone = 1'b1;
		      n_irq    = r_xie;
		      n_state  = S_IDLE;
		   end
	      end
	    else
	      begin
		 n_nbdp     = r_dp;
		 n_desc_cnt = r_desc_cnt + 8'd1;
		 n_state    = S_TX_DESC;
	      end
	  S_TX_FLUSH:
	    begin                                   // the chain's tail: a partial beat
	       if(!tx_wr_full)
		 begin
		    tx_wr_en   = 1'b1;
		    tx_wr_data = r_acc[127:0];
		    n_acc      = 256'd0;
		    n_acc_n    = 6'd0;
		    n_txdone   = 1'b1;
		    n_irq      = r_xie;
		    n_state    = S_IDLE;
		 end
	    end
	  S_DONE:                                   // unreachable: RX/TX pulse on exit
	    begin
	       n_state = S_IDLE;
	    end
	  S_DROP:
	    begin
	       n_drop  = 1'b1;
	       n_state = S_IDLE;
	    end
	  default: n_state = S_IDLE;
	endcase // case (r_state)
     end // always_comb

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_state    <= S_IDLE;
	     r_nbdp     <= 32'd0;
	     r_bp       <= 32'd0;
	     r_cnt      <= 14'd0;
	     r_dp       <= 32'd0;
	     r_bc       <= 32'd0;
	     r_bufsz    <= 14'd0;
	     r_eox      <= 1'b0;
	     r_xie      <= 1'b0;
	     r_done     <= 1'b0;
	     r_txdone   <= 1'b0;
	     r_drop     <= 1'b0;
	     r_irq      <= 1'b0;
	     r_crbdp    <= 32'd0;
	     r_desc_cnt <= 8'd0;
	     r_acc      <= 256'd0;
	     r_acc_n    <= 6'd0;
	     r_txlen    <= 14'd0;
	     r_rx_left  <= 11'd0;
	     r_rx_drop  <= 1'b0;
	     r_rx_pend  <= 1'b0;
	     r_tx_pend  <= 1'b0;
	  end
	else
	  begin
	     r_state    <= n_state;
	     r_nbdp     <= n_nbdp;
	     r_bp       <= n_bp;
	     r_cnt      <= n_cnt;
	     r_dp       <= n_dp;
	     r_bc       <= n_bc;
	     r_bufsz    <= n_bufsz;
	     r_eox      <= n_eox;
	     r_xie      <= n_xie;
	     r_done     <= n_done;
	     r_txdone   <= n_txdone;
	     r_drop     <= n_drop;
	     r_irq      <= n_irq;
	     r_crbdp    <= n_crbdp;
	     r_desc_cnt <= n_desc_cnt;
	     r_acc      <= n_acc;
	     r_acc_n    <= n_acc_n;
	     r_txlen    <= n_txlen;
	     r_rx_left  <= n_rx_left;
	     r_rx_drop  <= n_rx_drop;
	     r_rx_pend  <= n_rx_pend;
	     r_tx_pend  <= n_tx_pend;
	  end
     end // always_ff

`ifdef VERILATOR
   /* sim-only trace of the engine's state walk (ENET_DMA_TRACE) */
`ifdef ENET_DMA_TRACE
   logic [63:0] r_trc_cyc;
   always_ff@(posedge clk)
     begin
	r_trc_cyc <= reset ? 64'd0 : r_trc_cyc + 64'd1;
	if(!reset && (r_state != n_state))
	  begin
	     $display("[enet_dma] %0t st %0d -> %0d nbdp %08x bp %08x bc %08x dp %08x cnt %0d", r_trc_cyc, r_state, n_state, r_nbdp, r_bp, r_bc, r_dp, r_cnt);
	  end
	if(!reset && (rx_go | tx_go))
	  begin
	     $display("[enet_dma] %0t go rx %0d tx %0d st %0d rx_nbdp %08x tx_nbdp %08x", r_trc_cyc, rx_go, tx_go, r_state, rx_nbdp, tx_nbdp);
	  end
	if(!reset && (r_txdone | r_done))
	  begin
	     $display("[enet_dma] %0t done tx %0d rx %0d", r_trc_cyc, r_txdone, r_done);
	  end
     end // always_ff
`endif
`endif

   assign rx_busy      = (r_state == S_RX_DESC) | (r_state == S_RX_BEAT) |
			 (r_state == S_RX_MEM)  | (r_state == S_RX_WB) |
			 (r_state == S_RX_DRAIN);
   assign tx_busy      = (r_state == S_TX_DESC) | (r_state == S_TX_MEM) |
			 (r_state == S_TX_HOST) | (r_state == S_TX_WB) |
			 (r_state == S_NEXT) | (r_state == S_TX_FLUSH);
   assign rx_done      = r_done;
   assign tx_done      = r_txdone;
   assign tx_len       = r_txlen;
   assign rx_dropped   = r_drop;
   assign irq          = r_irq;
   assign rx_crbdp     = r_crbdp;
   assign rx_next_nbdp = r_nbdp;

endmodule // enet_dma
