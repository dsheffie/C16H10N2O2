`include "machine.vh"
// -----------------------------------------------------------------------------
// enet_ring_dma.sv -- HPC3 ENET RX/TX DMA against the ARM staging rings
// (docs/arm-device-protocol.md).  Replaces enet_dma's beat FIFOs.
//
// TX: walk the guest chain (through the snoop shim), gather each PACKET (up to
//     EOXP, or the chain end) into a 2 KB staging slot, post a completion entry,
//     publish tx_prod in the staging control block.  BC write-back touches byte 6
//     (ETXD) only, never the EOX/EOXP/XIE/XIU byte.
//     ETXD on a packet's HEAD descriptor is IRIX's "whole packet transmitted": its
//     if_ecintr then reclaims every descriptor of the packet (parking them with EOX).
//     So the head's ETXD is written only after the packet's last descriptor has been
//     gathered -- setting it as the head was fetched (as the engine first did) let
//     IRIX reclaim the rest of the packet mid-walk, and the engine then stopped at a
//     parked EOX: a truncated frame, ~1.5% of full-size TCP segments on silicon.
//     tx_crbdp moves per PACKET: the in-flight packet's head, then the next descriptor
//     at chain end.  While TX is ACTIVE, IRIX's clean_xd_chain (if_ec2.c:958-1043)
//     reclaims every whole packet whose head lies before CRBDP, walking it to EOXP
//     without checking ETXD -- a CRBDP inside a packet lets it reclaim the packet's
//     unread descriptors mid-walk (parked with EOX: a truncated frame).
// RX: for each ARM-submitted slot, deposit it at the next guest RX descriptor
//     (any BP offset, masked to [BP, BP+len)), write back BC bytes 6-7 (ROWN clear,
//     residual), publish rx_cons.  ROWN=0 drops the frame, as real HPC3 does.
//
// The two FSMs share one memory port (one access outstanding, round-robin), and
// neither ever waits on the ARM mid-transfer: TX waits for a free slot only before
// it opens a packet, RX starts only when a whole frame is already staged.
// -----------------------------------------------------------------------------
module enet_ring_dma
   (input  logic         clk,
    input  logic         reset,
    // ---- ARM doorbells (S00_AXI write-only regs) ----
    input  logic [31:0]  tx_cons,        // TX completions the ARM has consumed
    input  logic [31:0]  rx_prod,        // RX frames the ARM has staged
    // ---- TX control (enet_shim) ----
    input  logic         tx_go,          // 1-cycle pulse: transmit the chain at tx_nbdp
    input  logic [31:0]  tx_nbdp,
    output logic         tx_done,        // 1-cycle when the chain completes
    output logic [31:0]  tx_crbdp,       // live: current descriptor, next one at done
    // ---- RX control ----
    input  logic         rx_armed,       // the guest has armed its RX ring
    input  logic [31:0]  rx_nbdp,        // ring position to fill next
    output logic         rx_done,        // 1-cycle: frame delivered, descriptor released
    output logic         rx_dropped,     // 1-cycle: ring full (ROWN=0), frame dropped
    output logic [31:0]  rx_crbdp,       // descriptor just filled
    output logic [31:0]  rx_next_nbdp,   // ring position after this frame
    // ---- one memory port -> dma_snoop_shim (staging PAs pass through unsnooped) ----
    output logic                  dma_req_valid,
    output logic [`PA_WIDTH-1:0]  dma_req_addr,
    output logic [4:0]            dma_req_opcode,     // 4 = line load, 7 = line store
    output logic [127:0]          dma_req_store_data,
    output logic [15:0]           dma_req_mask,
    input  logic                  dma_rsp_valid,
    input  logic [127:0]          dma_rsp_load_data);

   /* staging layout (docs/arm-device-protocol.md) */
   localparam logic [31:0] STG_IDX  = 32'h1e000040;   // PL-owned indices: tx_prod, rx_cons, rx_drops
   localparam logic [31:0] STG_TXCQ = 32'h1e001000;   // 256 x 16 B
   localparam logic [31:0] STG_RXSQ = 32'h1e002000;   // 256 x 16 B
   localparam logic [31:0] STG_TXS  = 32'h1e100000;   // 256 x 2 KB
   localparam logic [31:0] STG_RXS  = 32'h1e180000;   // 256 x 2 KB
   localparam logic [31:0] STG_TRC  = 32'h1e400000;   // ENET_RING_TRACE: 64K x 16 B TX descriptor log
   localparam logic [31:0] NSLOT    = 32'd256;

   localparam logic [31:0] BC_COUNT = 32'h00003fff;
   localparam logic [31:0] BC_ROWN  = 32'h00004000;
   localparam logic [31:0] BC_ETXD  = 32'h00008000;
   /* BC is descriptor bytes 4..7 (big-endian): byte 6 = bc[15:8] (ETXD, ROWN,
    * count[13:8]), byte 7 = bc[7:0].  Never write bytes 4-5 (EOX/EOXP/XIE). */
   localparam logic [15:0] TX_BC_MASK = 16'h0040;
   localparam logic [15:0] RX_BC_MASK = 16'h00c0;

   typedef enum logic [3:0] {
      T_IDLE  = 4'd0,
      T_DESC  = 4'd1,    // read the descriptor at r_t_nbdp
      T_SLOT  = 4'd2,    // wait for a free TX slot, open a packet
      T_MEM   = 4'd3,    // load the aligned line holding bp
      T_PUT   = 4'd4,    // a full 16 B in the packer: store it to the slot
      T_BCWB  = 4'd5,    // set ETXD (byte 6 only)
      T_FLUSH = 4'd6,    // packet end: store the partial tail line
      T_CQ    = 4'd7,    // write the completion entry
      T_IDX   = 4'd8,    // publish tx_prod
      T_NEXT  = 4'd9,    // follow dp or finish the chain
      T_TRACE = 4'd10,   // ENET_RING_TRACE: log the descriptor just read
      T_HEAD  = 4'd11    // packet complete: ETXD on its head descriptor
   } tstate_t;

   typedef enum logic [2:0] {
      R_IDLE  = 3'd0,
      R_ENTRY = 3'd1,    // read the staged frame's entry (length)
      R_DESC  = 3'd2,    // read the guest descriptor, check ROWN
      R_BEAT  = 3'd3,    // enough bytes for the next store? else load a slot line
      R_STORE = 3'd4,    // store up to the end of bp's line
      R_BCWB  = 3'd5,    // release: ROWN clear + residual (bytes 6-7)
      R_IDX   = 3'd6     // publish rx_cons / rx_drops
   } rstate_t;

   // ---------------- TX state ----------------
   tstate_t       r_t_state, n_t_state;
   logic          r_t_pend, n_t_pend;
   logic [31:0]   r_t_nbdp, n_t_nbdp;
   logic [31:0]   r_t_bp, n_t_bp;
   logic [31:0]   r_t_bc, n_t_bc;
   logic [31:0]   r_t_dp, n_t_dp;
   logic [13:0]   r_t_cnt, n_t_cnt;
   logic [255:0]  r_t_acc, n_t_acc;
   logic [5:0]    r_t_acc_n, n_t_acc_n;
   logic          r_t_open, n_t_open;
   logic [15:0]   r_t_len, n_t_len;
   logic [11:0]   r_t_soff, n_t_soff;
   logic          r_t_trunc, n_t_trunc;
   logic [31:0]   r_t_first, n_t_first;
   logic [31:0]   r_t_fbc, n_t_fbc;          // the head descriptor's BC (for its deferred ETXD)
   logic [31:0]   r_t_prod, n_t_prod;
   logic [7:0]    r_t_ndesc, n_t_ndesc;
   logic          r_t_done, n_t_done;
   logic [31:0]   r_t_crbdp, n_t_crbdp;
   logic [31:0]   r_t_tidx, n_t_tidx;        // ENET_RING_TRACE: next trace record
   logic [31:0]   r_t_ftidx, n_t_ftidx;      // ENET_RING_TRACE: record of the packet's first descriptor
   logic          t_req_valid;
   logic [31:0]   t_req_addr;
   logic [4:0]    t_req_opcode;
   logic [127:0]  t_req_data;
   logic [15:0]   t_req_mask;
   logic [3:0]    t_off;
   logic [4:0]    t_take;
   logic [127:0]  t_bytes;
   logic          t_chain_end;
   logic          t_rsp;

   // ---------------- RX state ----------------
   rstate_t       r_r_state, n_r_state;
   logic [31:0]   r_r_cons, n_r_cons;
   logic [31:0]   r_r_drops, n_r_drops;
   logic [31:0]   r_r_nbdp, n_r_nbdp;
   logic [31:0]   r_r_bp, n_r_bp;
   logic [31:0]   r_r_bc, n_r_bc;
   logic [31:0]   r_r_dp, n_r_dp;
   logic [13:0]   r_r_len, n_r_len;
   logic [13:0]   r_r_cnt, n_r_cnt;
   logic [13:0]   r_r_res, n_r_res;
   logic [255:0]  r_r_acc, n_r_acc;
   logic [5:0]    r_r_acc_n, n_r_acc_n;
   logic [11:0]   r_r_soff, n_r_soff;
   logic          r_r_drop, n_r_drop;
   logic          r_r_done, n_r_done;
   logic          r_r_dropped, n_r_dropped;
   logic [31:0]   r_r_crbdp, n_r_crbdp;
   logic [31:0]   r_r_next, n_r_next;
   logic          r_req_valid;
   logic [31:0]   r_req_addr;
   logic [4:0]    r_req_opcode;
   logic [127:0]  r_req_data;
   logic [15:0]   r_req_mask;
   logic [3:0]    t_r_off;
   logic [4:0]    t_r_need;
   logic          t_r_rsp;

   // ---------------- port mux: one access outstanding, round-robin ----------------
   logic          r_busy, n_busy;
   logic          r_own_rx, n_own_rx;      // owner of the access in flight
   logic          r_last_rx, n_last_rx;    // last grant, for round-robin
   logic          t_grant_rx;

   // descriptor fields: BE in DRAM, byte-swap each 32-bit lane of the line
   wire [31:0] w_bp = bswap32(dma_rsp_load_data[31:0]);
   wire [31:0] w_bc = bswap32(dma_rsp_load_data[63:32]);
   wire [31:0] w_dp = bswap32(dma_rsp_load_data[95:64]);

   wire [31:0] w_tx_slot = STG_TXS + {13'd0, r_t_prod[7:0], 11'd0};
   wire [31:0] w_rx_slot = STG_RXS + {13'd0, r_r_cons[7:0], 11'd0};
   wire [31:0] w_rx_wb   = (r_r_bc & ~BC_ROWN & ~BC_COUNT) | ({18'd0, r_r_res} & BC_COUNT);

   always_comb
     begin
	/* port mux: the granted FSM's request is presented until its response */
	t_grant_rx = r_busy ? r_own_rx : (r_req_valid & (!t_req_valid | !r_last_rx));
	n_busy     = r_busy;
	n_own_rx   = r_own_rx;
	n_last_rx  = r_last_rx;
	if(!r_busy && (t_req_valid || r_req_valid))
	  begin
	     n_busy    = 1'b1;
	     n_own_rx  = t_grant_rx;
	     n_last_rx = t_grant_rx;
	  end
	if(r_busy && dma_rsp_valid)
	  begin
	     n_busy = 1'b0;
	  end
	dma_req_valid      = t_grant_rx ? r_req_valid : t_req_valid;
	dma_req_addr       = {{(`PA_WIDTH-32){1'b0}}, (t_grant_rx ? r_req_addr : t_req_addr)};
	dma_req_opcode     = t_grant_rx ? r_req_opcode : t_req_opcode;
	dma_req_store_data = t_grant_rx ? r_req_data : t_req_data;
	dma_req_mask       = t_grant_rx ? r_req_mask : t_req_mask;
	t_rsp   = r_busy && !r_own_rx && dma_rsp_valid;
	t_r_rsp = r_busy &&  r_own_rx && dma_rsp_valid;
     end // always_comb

   // ---------------- TX FSM ----------------
   always_comb
     begin
	n_t_state = r_t_state;
	n_t_pend  = r_t_pend | tx_go;
	n_t_nbdp  = r_t_nbdp;
	n_t_bp    = r_t_bp;
	n_t_bc    = r_t_bc;
	n_t_dp    = r_t_dp;
	n_t_cnt   = r_t_cnt;
	n_t_acc   = r_t_acc;
	n_t_acc_n = r_t_acc_n;
	n_t_open  = r_t_open;
	n_t_len   = r_t_len;
	n_t_soff  = r_t_soff;
	n_t_trunc = r_t_trunc;
	n_t_first = r_t_first;
	n_t_fbc   = r_t_fbc;
	n_t_prod  = r_t_prod;
	n_t_ndesc = r_t_ndesc;
	n_t_done  = 1'b0;
	n_t_crbdp = r_t_crbdp;
	n_t_tidx  = r_t_tidx;
	n_t_ftidx = r_t_ftidx;
	t_req_valid  = 1'b0;
	t_req_addr   = r_t_nbdp;
	t_req_opcode = 5'd4;
	t_req_data   = 128'd0;
	t_req_mask   = 16'hffff;
	t_off   = r_t_bp[3:0];
	t_take  = ({1'b0, r_t_cnt} < (5'd16 - {1'b0, t_off})) ? r_t_cnt[4:0] : (5'd16 - {1'b0, t_off});
	t_bytes = (dma_rsp_load_data >> {t_off, 3'd0}) & ({128{1'b1}} >> {(5'd16 - t_take), 3'd0});
	t_chain_end = r_t_bc[31] | (r_t_dp == 32'd0) | (r_t_ndesc == 8'hff);
	case(r_t_state)
	  T_IDLE:
	    begin
	       if(r_t_pend | tx_go)
		 begin
		    n_t_pend  = 1'b0;
		    n_t_nbdp  = tx_nbdp;
		    n_t_ndesc = 8'd0;
		    n_t_open  = 1'b0;
		    n_t_acc   = 256'd0;
		    n_t_acc_n = 6'd0;
		    n_t_state = T_DESC;
		 end
	    end
	  T_DESC:
	    begin
	       t_req_valid  = 1'b1;
	       t_req_addr   = r_t_nbdp;
	       t_req_opcode = 5'd4;
	       if(t_rsp)
		 begin
		    n_t_bp    = w_bp;
		    n_t_bc    = w_bc;
		    n_t_dp    = w_dp;
		    n_t_cnt   = w_bc[13:0];
`ifdef ENET_RING_TRACE
		    n_t_state = T_TRACE;
`else
		    n_t_state = !r_t_open ? T_SLOT : ((w_bc[13:0] == 14'd0) ? T_BCWB : T_MEM);
`endif
		 end
	    end
	  T_SLOT:
	    begin                                   // the only wait on the ARM: before a packet
	       if((r_t_prod - tx_cons) < NSLOT)
		 begin
		    n_t_open  = 1'b1;
		    n_t_len   = 16'd0;
		    n_t_soff  = 12'd0;
		    n_t_trunc = 1'b0;
		    n_t_first = r_t_nbdp;
		    n_t_fbc   = r_t_bc;
		    n_t_crbdp = r_t_nbdp;           /* CRBDP = this packet's head (see above) */
		    n_t_ftidx = r_t_tidx - 32'd1;
		    n_t_state = (r_t_cnt == 14'd0) ? T_BCWB : T_MEM;
		 end
	    end
	  T_MEM:
	    begin                                   // load the aligned line holding bp
	       t_req_valid  = 1'b1;
	       t_req_addr   = {r_t_bp[31:4], 4'd0};
	       t_req_opcode = 5'd4;
	       if(t_rsp)
		 begin
		    n_t_acc   = r_t_acc | ({128'd0, t_bytes} << {r_t_acc_n, 3'd0});
		    n_t_acc_n = r_t_acc_n + {1'b0, t_take};
		    n_t_bp    = r_t_bp + {27'd0, t_take};
		    n_t_cnt   = r_t_cnt - {9'd0, t_take};
		    n_t_len   = r_t_len + {11'd0, t_take};
		    n_t_state = T_PUT;
		 end
	    end
	  T_PUT:
	    begin                                   // a full 16 B: into the slot (2 KB cap)
	       if(r_t_acc_n >= 6'd16)
		 begin
		    if(r_t_soff[11])
		      begin                         // oversize packet: drop the excess bytes
			 n_t_acc   = r_t_acc >> 128;
			 n_t_acc_n = r_t_acc_n - 6'd16;
			 n_t_trunc = 1'b1;
			 n_t_state = (r_t_cnt == 14'd0) ? T_BCWB : T_MEM;
		      end
		    else
		      begin
			 t_req_valid  = 1'b1;
			 t_req_addr   = w_tx_slot + {20'd0, r_t_soff};
			 t_req_opcode = 5'd7;
			 t_req_data   = r_t_acc[127:0];
			 if(t_rsp)
			   begin
			      n_t_acc   = r_t_acc >> 128;
			      n_t_acc_n = r_t_acc_n - 6'd16;
			      n_t_soff  = r_t_soff + 12'd16;
			      n_t_state = (r_t_cnt == 14'd0) ? T_BCWB : T_MEM;
			   end
		      end
		 end
	       else
		 begin
		    n_t_state = (r_t_cnt == 14'd0) ? T_BCWB : T_MEM;
		 end
	    end
	  T_BCWB:
	    begin                                   // ETXD only: byte 6 of the descriptor
	       if(r_t_nbdp == r_t_first)
		 begin                              // the head's ETXD waits for the packet end (T_HEAD)
		    n_t_state = (r_t_bc[30] | t_chain_end) ? T_FLUSH : T_NEXT;
		 end
	       else
		 begin
		    t_req_valid  = 1'b1;
		    t_req_addr   = r_t_nbdp;
		    t_req_opcode = 5'd7;
		    t_req_data   = {64'd0, bswap32(r_t_bc | BC_ETXD), 32'd0};
		    t_req_mask   = TX_BC_MASK;
		    if(t_rsp)
		      begin
			 n_t_state = (r_t_bc[30] | t_chain_end) ? T_FLUSH : T_NEXT;
		      end
		 end
	    end
	  T_FLUSH:
	    begin                                   // packet end: the partial tail line
	       if((r_t_acc_n != 6'd0) && !r_t_soff[11])
		 begin
		    t_req_valid  = 1'b1;
		    t_req_addr   = w_tx_slot + {20'd0, r_t_soff};
		    t_req_opcode = 5'd7;
		    t_req_data   = r_t_acc[127:0];
		    if(t_rsp)
		      begin
			 n_t_acc   = 256'd0;
			 n_t_acc_n = 6'd0;
			 n_t_state = T_HEAD;
		      end
		 end
	       else
		 begin
		    n_t_trunc = r_t_trunc | (r_t_acc_n != 6'd0);
		    n_t_acc   = 256'd0;
		    n_t_acc_n = 6'd0;
		    n_t_state = T_HEAD;
		 end
	    end
	  T_HEAD:
	    begin                                   // the whole packet is in the slot: now ETXD the head
	       t_req_valid  = 1'b1;
	       t_req_addr   = r_t_first;
	       t_req_opcode = 5'd7;
	       t_req_data   = {64'd0, bswap32(r_t_fbc | BC_ETXD), 32'd0};
	       t_req_mask   = TX_BC_MASK;
	       if(t_rsp)
		 begin
		    n_t_state = T_CQ;
		 end
	    end
	  T_CQ:
	    begin                                   // {len|flags, first desc, chain desc #, 0}
	       t_req_valid  = 1'b1;
	       t_req_addr   = STG_TXCQ + {20'd0, r_t_prod[7:0], 4'd0};
	       t_req_opcode = 5'd7;
	       t_req_data   = {r_t_ftidx, {24'd0, r_t_ndesc}, r_t_first, {15'd0, r_t_trunc, r_t_len}};
	       if(t_rsp)
		 begin
		    n_t_state = T_IDX;
		 end
	    end
	  T_IDX:
	    begin                                   // publish tx_prod after the entry
	       t_req_valid  = 1'b1;
	       t_req_addr   = STG_IDX;
	       t_req_opcode = 5'd7;
	       t_req_data   = {96'd0, r_t_prod + 32'd1};
	       t_req_mask   = 16'h000f;
	       if(t_rsp)
		 begin
		    n_t_prod  = r_t_prod + 32'd1;
		    n_t_open  = 1'b0;
		    n_t_state = T_NEXT;
		 end
	    end
	  T_NEXT:
	    begin
	       if(t_chain_end)
		 begin
		    n_t_crbdp = r_t_dp;
		    n_t_done  = 1'b1;
		    n_t_state = T_IDLE;
		 end
	       else
		 begin
		    n_t_nbdp  = r_t_dp;
		    n_t_ndesc = r_t_ndesc + 8'd1;
		    n_t_state = T_DESC;
		 end
	    end
	  T_TRACE:
	    begin                                   // {seq|ndesc, nbdp, bc as read, dp}
	       t_req_valid  = 1'b1;
	       t_req_addr   = STG_TRC + {12'd0, r_t_tidx[15:0], 4'd0};
	       t_req_opcode = 5'd7;
	       t_req_data   = {r_t_dp, r_t_bc, r_t_nbdp, {r_t_prod[15:0], 8'd0, r_t_ndesc}};
	       if(t_rsp)
		 begin
		    n_t_tidx  = r_t_tidx + 32'd1;
		    n_t_state = !r_t_open ? T_SLOT : ((r_t_cnt == 14'd0) ? T_BCWB : T_MEM);
		 end
	    end
	  default:
	    begin
	       n_t_state = T_IDLE;
	    end
	endcase // case (r_t_state)
     end // always_comb

   // ---------------- RX FSM ----------------
   always_comb
     begin
	n_r_state   = r_r_state;
	n_r_cons    = r_r_cons;
	n_r_drops   = r_r_drops;
	n_r_nbdp    = r_r_nbdp;
	n_r_bp      = r_r_bp;
	n_r_bc      = r_r_bc;
	n_r_dp      = r_r_dp;
	n_r_len     = r_r_len;
	n_r_cnt     = r_r_cnt;
	n_r_res     = r_r_res;
	n_r_acc     = r_r_acc;
	n_r_acc_n   = r_r_acc_n;
	n_r_soff    = r_r_soff;
	n_r_drop    = r_r_drop;
	n_r_done    = 1'b0;
	n_r_dropped = 1'b0;
	n_r_crbdp   = r_r_crbdp;
	n_r_next    = r_r_next;
	r_req_valid  = 1'b0;
	r_req_addr   = r_r_nbdp;
	r_req_opcode = 5'd4;
	r_req_data   = 128'd0;
	r_req_mask   = 16'hffff;
	t_r_off  = r_r_bp[3:0];
	t_r_need = ({1'b0, r_r_cnt} < (5'd16 - {1'b0, t_r_off})) ? r_r_cnt[4:0] : (5'd16 - {1'b0, t_r_off});
	case(r_r_state)
	  R_IDLE:
	    begin
	       if(rx_armed && (rx_prod != r_r_cons))
		 begin
		    n_r_state = R_ENTRY;
		 end
	    end
	  R_ENTRY:
	    begin
	       r_req_valid  = 1'b1;
	       r_req_addr   = STG_RXSQ + {20'd0, r_r_cons[7:0], 4'd0};
	       r_req_opcode = 5'd4;
	       if(t_r_rsp)
		 begin
		    n_r_len   = dma_rsp_load_data[13:0];
		    n_r_nbdp  = rx_nbdp;
		    n_r_acc   = 256'd0;
		    n_r_acc_n = 6'd0;
		    n_r_soff  = 12'd0;
		    n_r_drop  = 1'b0;
		    n_r_state = R_DESC;
		 end
	    end
	  R_DESC:
	    begin
	       r_req_valid  = 1'b1;
	       r_req_addr   = r_r_nbdp;
	       r_req_opcode = 5'd4;
	       if(t_r_rsp)
		 begin
		    n_r_bp = w_bp;
		    n_r_bc = w_bc;
		    n_r_dp = w_dp;
		    /* ROWN=0 -> the CPU still owns it (ring full); a buffer smaller than
		     * [2 pad][frame][1 status] is unusable: drop, as real HPC3 does */
		    if(!w_bc[14] || (w_bc[13:0] < 14'd3) || (r_r_len == 14'd0))
		      begin
			 n_r_drop  = 1'b1;
			 n_r_state = R_IDX;
		      end
		    else
		      begin
			 n_r_cnt   = (r_r_len > w_bc[13:0]) ? w_bc[13:0] : r_r_len;
			 n_r_res   = w_bc[13:0] - ((r_r_len > w_bc[13:0]) ? w_bc[13:0] : r_r_len);
			 n_r_state = R_BEAT;
		      end
		 end
	    end
	  R_BEAT:
	    begin                                   // enough staged bytes for the next store?
	       if(r_r_acc_n >= {1'b0, t_r_need})
		 begin
		    n_r_state = R_STORE;
		 end
	       else
		 begin
		    r_req_valid  = 1'b1;
		    r_req_addr   = w_rx_slot + {20'd0, r_r_soff};
		    r_req_opcode = 5'd4;
		    if(t_r_rsp)
		      begin
			 n_r_acc   = r_r_acc | ({128'd0, dma_rsp_load_data} << {r_r_acc_n, 3'd0});
			 n_r_acc_n = r_r_acc_n + 6'd16;
			 n_r_soff  = r_r_soff + 12'd16;
			 n_r_state = R_STORE;
		      end
		 end
	    end
	  R_STORE:
	    begin                                   // store up to the end of bp's line
	       r_req_valid  = 1'b1;
	       r_req_addr   = {r_r_bp[31:4], 4'd0};
	       r_req_opcode = 5'd7;
	       r_req_data   = r_r_acc[127:0] << {t_r_off, 3'd0};
	       r_req_mask   = 16'(((17'd1 << t_r_need) - 17'd1) << t_r_off);
	       if(t_r_rsp)
		 begin
		    n_r_acc   = r_r_acc >> {t_r_need, 3'd0};
		    n_r_acc_n = r_r_acc_n - {1'b0, t_r_need};
		    n_r_bp    = r_r_bp + {27'd0, t_r_need};
		    n_r_cnt   = r_r_cnt - {9'd0, t_r_need};
		    n_r_state = (r_r_cnt == {9'd0, t_r_need}) ? R_BCWB : R_BEAT;
		 end
	    end
	  R_BCWB:
	    begin                                   // release: ROWN clear + residual, bytes 6-7
	       r_req_valid  = 1'b1;
	       r_req_addr   = r_r_nbdp;
	       r_req_opcode = 5'd7;
	       r_req_data   = {64'd0, bswap32(w_rx_wb), 32'd0};
	       r_req_mask   = RX_BC_MASK;
	       if(t_r_rsp)
		 begin
		    n_r_crbdp = r_r_nbdp;
		    n_r_next  = r_r_dp;
		    n_r_done  = 1'b1;
		    n_r_state = R_IDX;
		 end
	    end
	  R_IDX:
	    begin                                   // publish rx_cons (+ drops) after the frame
	       r_req_valid  = 1'b1;
	       r_req_addr   = STG_IDX;
	       r_req_opcode = 5'd7;
	       r_req_data   = {32'd0, r_r_drops + {31'd0, r_r_drop}, r_r_cons + 32'd1, 32'd0};
	       r_req_mask   = 16'h0ff0;
	       if(t_r_rsp)
		 begin
		    n_r_cons    = r_r_cons + 32'd1;
		    n_r_drops   = r_r_drops + {31'd0, r_r_drop};
		    n_r_dropped = r_r_drop;
		    n_r_state   = R_IDLE;
		 end
	    end
	  default:
	    begin
	       n_r_state = R_IDLE;
	    end
	endcase // case (r_r_state)
     end // always_comb

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_busy      <= 1'b0;
	     r_own_rx    <= 1'b0;
	     r_last_rx   <= 1'b0;
	     r_t_state   <= T_IDLE;
	     r_t_pend    <= 1'b0;
	     r_t_nbdp    <= 32'd0;
	     r_t_bp      <= 32'd0;
	     r_t_bc      <= 32'd0;
	     r_t_dp      <= 32'd0;
	     r_t_cnt     <= 14'd0;
	     r_t_acc     <= 256'd0;
	     r_t_acc_n   <= 6'd0;
	     r_t_open    <= 1'b0;
	     r_t_len     <= 16'd0;
	     r_t_soff    <= 12'd0;
	     r_t_trunc   <= 1'b0;
	     r_t_first   <= 32'd0;
	     r_t_fbc     <= 32'd0;
	     r_t_prod    <= 32'd0;
	     r_t_ndesc   <= 8'd0;
	     r_t_done    <= 1'b0;
	     r_t_crbdp   <= 32'd0;
	     r_t_tidx    <= 32'd0;
	     r_t_ftidx   <= 32'd0;
	     r_r_state   <= R_IDLE;
	     r_r_cons    <= 32'd0;
	     r_r_drops   <= 32'd0;
	     r_r_nbdp    <= 32'd0;
	     r_r_bp      <= 32'd0;
	     r_r_bc      <= 32'd0;
	     r_r_dp      <= 32'd0;
	     r_r_len     <= 14'd0;
	     r_r_cnt     <= 14'd0;
	     r_r_res     <= 14'd0;
	     r_r_acc     <= 256'd0;
	     r_r_acc_n   <= 6'd0;
	     r_r_soff    <= 12'd0;
	     r_r_drop    <= 1'b0;
	     r_r_done    <= 1'b0;
	     r_r_dropped <= 1'b0;
	     r_r_crbdp   <= 32'd0;
	     r_r_next    <= 32'd0;
	  end
	else
	  begin
	     r_busy      <= n_busy;
	     r_own_rx    <= n_own_rx;
	     r_last_rx   <= n_last_rx;
	     r_t_state   <= n_t_state;
	     r_t_pend    <= n_t_pend;
	     r_t_nbdp    <= n_t_nbdp;
	     r_t_bp      <= n_t_bp;
	     r_t_bc      <= n_t_bc;
	     r_t_dp      <= n_t_dp;
	     r_t_cnt     <= n_t_cnt;
	     r_t_acc     <= n_t_acc;
	     r_t_acc_n   <= n_t_acc_n;
	     r_t_open    <= n_t_open;
	     r_t_len     <= n_t_len;
	     r_t_soff    <= n_t_soff;
	     r_t_trunc   <= n_t_trunc;
	     r_t_first   <= n_t_first;
	     r_t_fbc     <= n_t_fbc;
	     r_t_prod    <= n_t_prod;
	     r_t_ndesc   <= n_t_ndesc;
	     r_t_done    <= n_t_done;
	     r_t_crbdp   <= n_t_crbdp;
	     r_t_tidx    <= n_t_tidx;
	     r_t_ftidx   <= n_t_ftidx;
	     r_r_state   <= n_r_state;
	     r_r_cons    <= n_r_cons;
	     r_r_drops   <= n_r_drops;
	     r_r_nbdp    <= n_r_nbdp;
	     r_r_bp      <= n_r_bp;
	     r_r_bc      <= n_r_bc;
	     r_r_dp      <= n_r_dp;
	     r_r_len     <= n_r_len;
	     r_r_cnt     <= n_r_cnt;
	     r_r_res     <= n_r_res;
	     r_r_acc     <= n_r_acc;
	     r_r_acc_n   <= n_r_acc_n;
	     r_r_soff    <= n_r_soff;
	     r_r_drop    <= n_r_drop;
	     r_r_done    <= n_r_done;
	     r_r_dropped <= n_r_dropped;
	     r_r_crbdp   <= n_r_crbdp;
	     r_r_next    <= n_r_next;
	  end
     end // always_ff

   assign tx_done      = r_t_done;
   assign tx_crbdp     = r_t_crbdp;
   assign rx_done      = r_r_done;
   assign rx_dropped   = r_r_dropped;
   assign rx_crbdp     = r_r_crbdp;
   assign rx_next_nbdp = r_r_next;

endmodule // enet_ring_dma
