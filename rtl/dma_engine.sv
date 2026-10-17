`include "machine.vh"
// -----------------------------------------------------------------------------
// dma_engine.sv -- henry's DMA engine: three channels (SCSI, ENET TX, ENET RX) on one
// memory port and one shared byte mover.  Replaces scsi_dma + scsi_stage and
// enet_ring_dma (docs/arm-device-protocol.md); the MC VDMA is to follow.
//
// The mover.  The staging side of every transfer is 16 B aligned; only the guest
// side has a byte offset.  So every move is one 128-bit byte ROTATE plus lane masks,
// with a 128-bit "hold" and a 128-bit "beat" register per channel (no shifters):
//   gather  (guest -> staging: SCSI WRITE, ENET TX): the loaded guest line is rotated
//           so its first wanted byte lands at the stream's current lane (wn); lanes
//           >= wn complete the outgoing beat, the wrapped lanes start the next one.
//   scatter (staging -> guest: SCSI READ, ENET RX): the unconsumed rest of the current
//           staged beat stays at its own lanes [h, 16) (a beat's remainder always runs
//           to lane 15), the next beat fills lanes [0, h); that window is rotated by
//           (guest offset - h) and stored with the lane mask.
// There is ONE rotator: one access is outstanding at a time, and the channel that
// owns the port supplies its input -- the store data it presents, or the line it
// loaded when the response comes back.
//
// Port: one access outstanding, held stable until its response (the arbiter and
// snoop-shim contract); the channels take turns per access (round robin), and a
// channel waiting on the ARM issues nothing, so it never holds the port.
//
// SCSI channel, as scsi_dma + scsi_stage did:
//   - walk the HPC3 {BP,BC,DP} chain (descriptor words big-endian) until EOX, a null
//     DP, or 255 descriptors;
//   - READ: staged beats at STG_RD (rd_beats of them once rd_seq == the chain's
//     req_seq); WRITE: beats to STG_WR (past 4 MB: dropped, trunc);
//   - one completion entry per chain {bytes, chain head, flags|dir|trunc, req_seq}
//     at STG_SCQ, then scsi_cq_prod; flags done / starved (READ wanted more than was
//     staged: posted while stalled, the shim then cancels) / aborted (cancelled first);
//   - rd_stalled: waiting for a beat with no memory access outstanding, so the shim's
//     cancel never abandons an access; a cancel is acted on only between accesses.
// ENET channels, as enet_ring_dma did:
//   TX: walk the guest chain, gather each PACKET (up to EOXP, or the chain end) into
//     a 2 KB staging slot, post a completion entry, publish tx_prod.  BC write-back
//     touches byte 6 (ETXD) only, never the EOX/EOXP/XIE/XIU byte.  ETXD on a packet's
//     HEAD descriptor is IRIX's "whole packet transmitted" (if_ecintr then reclaims the
//     whole packet), so the head's ETXD is written only after the packet's last
//     descriptor was gathered (setting it at the head let IRIX reclaim the rest
//     mid-walk: ~1.5% truncated TCP segments on silicon).  tx_crbdp moves per PACKET:
//     the in-flight packet's head, then the next descriptor at chain end -- IRIX's
//     clean_xd_chain (if_ec2.c:958-1043) reclaims every whole packet whose head lies
//     before CRBDP, so a CRBDP inside a packet truncates it.
//   RX: for each ARM-staged frame, deposit it at the next guest RX descriptor (any BP
//     offset, masked to [BP, BP+len)), write back BC bytes 6-7 (ROWN clear, residual),
//     publish rx_cons.  ROWN=0 (or a buffer too small for [2 pad][frame][status])
//     drops the frame, as real HPC3 does.
//   Neither waits on the ARM mid-transfer: TX waits for a free slot only before it
//   opens a packet, RX starts only when a whole frame is already staged.
// -----------------------------------------------------------------------------
module dma_engine
  (input  logic                  clk,
   input  logic                  reset,
   // ---- SCSI channel control (scsi_shim) ----
   input  logic                  go,           // 1-cycle pulse: start the chain at nbdp
   input  logic [31:0]           nbdp,         // chain head (physical, 16-byte aligned)
   input  logic                  to_device,    // 1 = WRITE (mem -> disk), 0 = READ
   input  logic                  cancel,       // short/no-data/selection timeout
   output logic                  busy,
   output logic                  done,         // 1-cycle pulse: the chain's data moved
   output logic                  irq,          // 1-cycle pulse with done if the last desc had XIE
   output logic                  rd_stalled,
   // ---- SCSI channel ARM doorbells ----
   input  logic [31:0]           rd_beats,     // beats staged for the READ chain of command rd_seq
   input  logic [31:0]           rd_seq,       // written after rd_beats
   input  logic [31:0]           req_seq,      // the shim's command sequence
   input  logic [31:0]           cq_cons,      // completions the ARM has consumed
   // ---- ENET channels: ARM doorbells ----
   input  logic [31:0]           tx_cons,      // TX completions the ARM has consumed
   input  logic [31:0]           rx_prod,      // RX frames the ARM has staged
   // ---- ENET TX control (enet_shim) ----
   input  logic                  tx_go,        // 1-cycle pulse: transmit the chain at tx_nbdp
   input  logic [31:0]           tx_nbdp,
   output logic                  tx_done,      // 1-cycle when the chain completes
   output logic [31:0]           tx_crbdp,     // live: the in-flight packet's head, the next desc at done
   // ---- ENET RX control ----
   input  logic                  rx_armed,     // the guest has armed its RX ring
   input  logic [31:0]           rx_nbdp,      // ring position to fill next
   output logic                  rx_done,      // 1-cycle: frame delivered, descriptor released
   output logic                  rx_dropped,   // 1-cycle: ring full (ROWN=0), frame dropped
   output logic [31:0]           rx_crbdp,     // descriptor just filled
   output logic [31:0]           rx_next_nbdp, // ring position after this frame
   // ---- memory port (the DMA snoop shim) ----
   output logic                  dn_req_valid,
   output logic [`PA_WIDTH-1:0]  dn_req_addr,
   output logic [4:0]            dn_req_opcode,     // 4 = line load, 7 = line store
   output logic [127:0]          dn_req_store_data,
   output logic [15:0]           dn_req_mask,
   input  logic                  dn_rsp_valid,
   input  logic [127:0]          dn_rsp_load_data,
   output logic [1:0]            owner);            // channel of the access in flight (logging)

   /* staging layout (docs/arm-device-protocol.md) */
   localparam logic [31:0] STG_IDX  = 32'h1e000040;   // ENET PL-owned indices: tx_prod, rx_cons, rx_drops
   localparam logic [31:0] STG_SIDX = 32'h1e000050;   // scsi_cq_prod (word 0 of the line)
   localparam logic [31:0] STG_TXCQ = 32'h1e001000;   // 256 x 16 B
   localparam logic [31:0] STG_RXSQ = 32'h1e002000;   // 256 x 16 B
   localparam logic [31:0] STG_SCQ  = 32'h1e003000;   // 64 x 16 B SCSI completions
   localparam logic [31:0] STG_TXS  = 32'h1e100000;   // 256 x 2 KB
   localparam logic [31:0] STG_RXS  = 32'h1e180000;   // 256 x 2 KB
   localparam logic [31:0] STG_TRC  = 32'h1e400000;   // ENET_RING_TRACE: 64K x 16 B TX descriptor log
   localparam logic [31:0] STG_RD   = 32'h1e800000;   // 4 MB: ARM -> device SCSI beats
   localparam logic [31:0] STG_WR   = 32'h1ec00000;   // 4 MB: device -> ARM SCSI beats
   localparam logic [23:0] NBEATS   = 24'd262144;     // 4 MB / 16
   localparam logic [31:0] NSLOT    = 32'd256;

   localparam logic [31:0] BC_COUNT = 32'h00003fff;
   localparam logic [31:0] BC_ROWN  = 32'h00004000;
   localparam logic [31:0] BC_ETXD  = 32'h00008000;
   /* BC is descriptor bytes 4..7 (big-endian): byte 6 = bc[15:8] (ETXD, ROWN,
    * count[13:8]), byte 7 = bc[7:0].  Never write bytes 4-5 (EOX/EOXP/XIE). */
   localparam logic [15:0] TX_BC_MASK = 16'h0040;
   localparam logic [15:0] RX_BC_MASK = 16'h00c0;

   localparam logic [1:0] CH_S = 2'd0;    // SCSI
   localparam logic [1:0] CH_T = 2'd1;    // ENET TX
   localparam logic [1:0] CH_R = 2'd2;    // ENET RX

   // ---------------- the mover ----------------
   /* lane i of d moves to lane (i + n) mod 16 */
   function automatic logic [127:0] rotl_lanes(input logic [127:0] d, input logic [3:0] n);
      logic [7:0] lsh, rsh;
      lsh = {1'b0, n, 3'd0};
      rsh = 8'd128 - lsh;                        /* n == 0: a 128-bit shift is 0 */
      rotl_lanes = (d << lsh) | (d >> rsh);
   endfunction
   /* byte enables for lanes [lo, hi), 0 <= lo <= hi <= 16 */
   function automatic logic [15:0] lanes(input logic [4:0] lo, input logic [4:0] hi);
      lanes = (16'hffff >> (5'd16 - (hi - lo))) << lo[3:0];
      if(hi == lo)
	begin
	   lanes = 16'd0;
	end
   endfunction
   function automatic logic [127:0] bytes_of(input logic [15:0] m);
      for(int i = 0; i < 16; i++)
	begin
	   bytes_of[8*i +: 8] = {8{m[i]}};
	end
   endfunction
   function automatic logic [31:0] bswap32(input logic [31:0] v);
      bswap32 = {v[7:0], v[15:8], v[23:16], v[31:24]};
   endfunction
   /* bytes taken from bp's line: min(16 - bp[3:0], cnt) */
   function automatic logic [4:0] line_take(input logic [3:0] off, input logic [13:0] cnt);
      logic [4:0] room;
      room = 5'd16 - {1'b0, off};
      line_take = (cnt < {9'd0, room}) ? cnt[4:0] : room;
   endfunction

   /* descriptor fields of a loaded descriptor line: BE in DRAM, swap each 32-bit lane */
   wire [31:0] w_bp = bswap32(dn_rsp_load_data[31:0]);
   wire [31:0] w_bc = bswap32(dn_rsp_load_data[63:32]);
   wire [31:0] w_dp = bswap32(dn_rsp_load_data[95:64]);

   // ---------------- port arbiter + shared rotator ----------------
   logic          r_busy, n_busy;
   logic [1:0]    r_own, n_own;              // owner of the access in flight
   logic [1:0]    r_last, n_last;            // last grant, for round robin
   logic [1:0]    t_grant, t_own;
   logic          t_any;
   logic [2:0]    t_valid;                   // per channel: a request is presented
   logic [2:0]    t_rsp;                     // per channel: its response is here
   logic [127:0]  t_rot_in, t_rot;
   logic [3:0]    t_rot_n;

   // ---------------- SCSI channel ----------------
   typedef enum logic [3:0] {
      S_IDLE    = 4'd0,
      S_DESC    = 4'd1,    // load the descriptor line @ r_s_nbdp
      S_R_NEED  = 4'd2,    // READ: is there enough staged data for bp's line?
      S_R_FETCH = 4'd3,    // READ: load the next staged beat
      S_R_STORE = 4'd4,    // READ: store bp's line (masked)
      S_W_LOAD  = 4'd5,    // WRITE: load bp's line
      S_W_DRAIN = 4'd6,    // WRITE: store the full beat to staging
      S_NEXT    = 4'd7,    // follow DP or finish
      S_DONE    = 4'd8,    // pulse done/irq, then post
      S_CQ      = 4'd9,    // completion entry
      S_IDX     = 4'd10    // publish scsi_cq_prod
   } sstate_t;

   sstate_t       r_s_state, n_s_state;
   /* a go pulse is latched: it may land while the previous chain still posts */
   logic          r_s_go, n_s_go;
   logic [31:0]   r_s_go_nbdp, n_s_go_nbdp;
   logic          r_s_go_dir, n_s_go_dir;
   logic [31:0]   r_s_go_seq, n_s_go_seq;
   logic          r_s_active, n_s_active;    // a chain is open (not yet posted)
   logic          r_s_dir, n_s_dir;          // 1 = WRITE
   logic [31:0]   r_s_head, n_s_head;        // chain head (for the completion entry)
   logic [31:0]   r_s_nbdp, n_s_nbdp;
   logic [31:0]   r_s_bp, n_s_bp;
   logic [13:0]   r_s_cnt, n_s_cnt;
   logic [31:0]   r_s_dp, n_s_dp;
   logic          r_s_eox, n_s_eox;
   logic          r_s_xie, n_s_xie;
   logic [7:0]    r_s_ndesc, n_s_ndesc;
   logic [31:0]   r_s_xfer, n_s_xfer;
   logic [31:0]   r_s_seq, n_s_seq;
   logic          r_s_gen_ok, n_s_gen_ok;    // the staged-beat count for this chain is known
   logic [23:0]   r_s_avail, n_s_avail;
   logic [23:0]   r_s_fetch, n_s_fetch;
   logic [23:0]   r_s_wptr, n_s_wptr;
   logic          r_s_trunc, n_s_trunc;
   logic          r_s_flush, n_s_flush;      // WRITE: the drain in progress is the final partial beat
   logic          r_s_cancel, n_s_cancel;    // a cancel waiting for a quiescent point
   logic          r_s_stall_post, n_s_stall_post;  // the posted entry was 'starved': keep stalling
   logic [2:0]    r_s_flags, n_s_flags;      // {aborted, starved, done} being posted
   logic [31:0]   r_s_cq_prod, n_s_cq_prod;
   logic          r_s_done, n_s_done;
   logic          r_s_irq, n_s_irq;
   logic [127:0]  r_s_hold, n_s_hold;        // READ: rest of the staged beat at [h,16); WRITE: partial beat at [0,wn)
   logic [127:0]  r_s_beat, n_s_beat;        // READ: the next staged beat; WRITE: a full outgoing beat
   logic          r_s_beat_v, n_s_beat_v;
   logic [4:0]    r_s_h, n_s_h;              // READ: first unconsumed lane of r_s_hold (16 = empty)
   logic [3:0]    r_s_wn, n_s_wn;            // WRITE: bytes in the partial beat
   logic          s_req_valid;
   logic [31:0]   s_req_addr;
   logic [4:0]    s_req_opcode;
   logic [127:0]  s_req_data;
   logic [15:0]   s_req_mask;
   logic [3:0]    t_s_off;
   logic [4:0]    t_s_take, t_s_have, t_s_wsum;
   logic          t_s_need_beat;             // READ: bp's line needs bytes of the next beat
   logic [127:0]  t_s_rot_in;
   logic [3:0]    t_s_rot_n;
   logic          t_s_quiet, t_s_cancel;

   // ---------------- ENET TX channel ----------------
   typedef enum logic [3:0] {
      T_IDLE  = 4'd0,
      T_DESC  = 4'd1,    // read the descriptor at r_t_nbdp
      T_SLOT  = 4'd2,    // wait for a free TX slot, open a packet
      T_MEM   = 4'd3,    // load the aligned line holding bp
      T_PUT   = 4'd4,    // a full 16 B beat gathered: store it to the slot
      T_BCWB  = 4'd5,    // set ETXD (byte 6 only)
      T_FLUSH = 4'd6,    // packet end: store the partial tail beat
      T_CQ    = 4'd7,    // write the completion entry
      T_IDX   = 4'd8,    // publish tx_prod
      T_NEXT  = 4'd9,    // follow dp or finish the chain
      T_TRACE = 4'd10,   // ENET_RING_TRACE: log the descriptor just read
      T_HEAD  = 4'd11    // packet complete: ETXD on its head descriptor
   } tstate_t;

   tstate_t       r_t_state, n_t_state;
   logic          r_t_pend, n_t_pend;
   logic [31:0]   r_t_nbdp, n_t_nbdp;
   logic [31:0]   r_t_bp, n_t_bp;
   logic [31:0]   r_t_bc, n_t_bc;
   logic [31:0]   r_t_dp, n_t_dp;
   logic [13:0]   r_t_cnt, n_t_cnt;
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
   logic [127:0]  r_t_hold, n_t_hold;        // the packet's partial beat at lanes [0, wn)
   logic [127:0]  r_t_beat, n_t_beat;        // a full gathered beat, to store
   logic [3:0]    r_t_wn, n_t_wn;
   logic          t_req_valid;
   logic [31:0]   t_req_addr;
   logic [4:0]    t_req_opcode;
   logic [127:0]  t_req_data;
   logic [15:0]   t_req_mask;
   logic [3:0]    t_t_off;
   logic [4:0]    t_t_take, t_t_wsum;
   logic          t_t_chain_end;
   wire  [31:0]   w_tx_slot = STG_TXS + {13'd0, r_t_prod[7:0], 11'd0};

   // ---------------- ENET RX channel ----------------
   typedef enum logic [2:0] {
      R_IDLE  = 3'd0,
      R_ENTRY = 3'd1,    // read the staged frame's entry (length)
      R_DESC  = 3'd2,    // read the guest descriptor, check ROWN
      R_BEAT  = 3'd3,    // enough bytes for the next store? else load a slot line
      R_STORE = 3'd4,    // store up to the end of bp's line
      R_BCWB  = 3'd5,    // release: ROWN clear + residual (bytes 6-7)
      R_IDX   = 3'd6     // publish rx_cons / rx_drops
   } rstate_t;

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
   logic [11:0]   r_r_soff, n_r_soff;
   logic          r_r_drop, n_r_drop;
   logic          r_r_done, n_r_done;
   logic          r_r_dropped, n_r_dropped;
   logic [31:0]   r_r_crbdp, n_r_crbdp;
   logic [31:0]   r_r_next, n_r_next;
   logic [127:0]  r_r_hold, n_r_hold;        // rest of the staged line at lanes [h, 16)
   logic [127:0]  r_r_beat, n_r_beat;        // the next staged line
   logic          r_r_beat_v, n_r_beat_v;
   logic [4:0]    r_r_h, n_r_h;              // first unconsumed lane of r_r_hold (16 = empty)
   logic          r_req_valid;
   logic [31:0]   r_req_addr;
   logic [4:0]    r_req_opcode;
   logic [127:0]  r_req_data;
   logic [15:0]   r_req_mask;
   logic [3:0]    t_r_off;
   logic [4:0]    t_r_take, t_r_have;
   logic          t_r_need_beat;
   wire  [31:0]   w_rx_slot = STG_RXS + {13'd0, r_r_cons[7:0], 11'd0};
   wire  [31:0]   w_rx_wb   = (r_r_bc & ~BC_ROWN & ~BC_COUNT) | ({18'd0, r_r_res} & BC_COUNT);

   // ======================================================================
   //  mover inputs per channel (registers only: no dependence on the port)
   // ======================================================================
   always_comb
     begin
	/* SCSI */
	t_s_off       = r_s_bp[3:0];
	t_s_take      = line_take(t_s_off, r_s_cnt);
	t_s_have      = 5'd16 - r_s_h;
	t_s_need_beat = (t_s_take > t_s_have);
	t_s_wsum      = {1'b0, r_s_wn} + t_s_take;
	if(r_s_dir)
	  begin
	     t_s_rot_in = dn_rsp_load_data;
	     t_s_rot_n  = r_s_wn - t_s_off;
	  end
	else
	  begin
	     t_s_rot_in = t_s_need_beat ? ((r_s_hold & bytes_of(lanes(r_s_h, 5'd16))) |
					   (r_s_beat & bytes_of(lanes(5'd0, r_s_h))))
			                : r_s_hold;
	     t_s_rot_n  = t_s_off - r_s_h[3:0];
	  end
	/* ENET TX: gather */
	t_t_off  = r_t_bp[3:0];
	t_t_take = line_take(t_t_off, r_t_cnt);
	t_t_wsum = {1'b0, r_t_wn} + t_t_take;
	/* ENET RX: scatter */
	t_r_off       = r_r_bp[3:0];
	t_r_take      = line_take(t_r_off, r_r_cnt);
	t_r_have      = 5'd16 - r_r_h;
	t_r_need_beat = (t_r_take > t_r_have);
     end // always_comb

   /* SCSI: waiting for a staged beat that cannot be fetched, with nothing outstanding */
   assign rd_stalled = (r_s_state == S_R_NEED) && t_s_need_beat && !r_s_beat_v &&
		       !(r_s_gen_ok && (r_s_fetch != r_s_avail));

   // ======================================================================
   //  port arbiter (one access outstanding, round robin) and the one rotator
   // ======================================================================
   always_comb
     begin
	t_valid = {r_req_valid, t_req_valid, s_req_valid};
	t_any   = |t_valid;
	/* round robin: the first requester after the last grant */
	t_grant = r_last;
	for(int i = 2; i >= 0; i--)
	  begin
	     /* lowest i wins: r_last + 1 first, r_last itself last */
	     if(t_valid[(int'(r_last) + i + 1) % 3])
	       begin
		  t_grant = 2'((int'(r_last) + i + 1) % 3);
	       end
	  end
	t_own  = r_busy ? r_own : t_grant;
	n_busy = r_busy;
	n_own  = r_own;
	n_last = r_last;
	if(r_busy)
	  begin
	     if(dn_rsp_valid)
	       begin
		  n_busy = 1'b0;
	       end
	  end
	else if(t_any)
	  begin
	     n_busy = ~dn_rsp_valid;
	     n_own  = t_grant;
	     n_last = t_grant;
	  end
	t_rsp = {(t_own == CH_R), (t_own == CH_T), (t_own == CH_S)} & {3{dn_rsp_valid}};

	/* the owner drives the rotator: scatter store data, or the gathered line */
	case(t_own)
	  CH_T:
	    begin
	       t_rot_in = dn_rsp_load_data;
	       t_rot_n  = r_t_wn - t_t_off;
	    end
	  CH_R:
	    begin
	       t_rot_in = t_r_need_beat ? ((r_r_hold & bytes_of(lanes(r_r_h, 5'd16))) |
					   (r_r_beat & bytes_of(lanes(5'd0, r_r_h))))
			                : r_r_hold;
	       t_rot_n  = t_r_off - r_r_h[3:0];
	    end
	  default:
	    begin
	       t_rot_in = t_s_rot_in;
	       t_rot_n  = t_s_rot_n;
	    end
	endcase
	t_rot = rotl_lanes(t_rot_in, t_rot_n);
     end // always_comb

   /* the owner's request goes out (its store data may come from the rotator) */
   always_comb
     begin
	case(t_own)
	  CH_T:
	    begin
	       dn_req_valid      = t_req_valid;
	       dn_req_addr       = {{(`PA_WIDTH-32){1'b0}}, t_req_addr};
	       dn_req_opcode     = t_req_opcode;
	       dn_req_store_data = t_req_data;
	       dn_req_mask       = t_req_mask;
	    end
	  CH_R:
	    begin
	       dn_req_valid      = r_req_valid;
	       dn_req_addr       = {{(`PA_WIDTH-32){1'b0}}, r_req_addr};
	       dn_req_opcode     = r_req_opcode;
	       dn_req_store_data = r_req_data;
	       dn_req_mask       = r_req_mask;
	    end
	  default:
	    begin
	       dn_req_valid      = s_req_valid;
	       dn_req_addr       = {{(`PA_WIDTH-32){1'b0}}, s_req_addr};
	       dn_req_opcode     = s_req_opcode;
	       dn_req_store_data = s_req_data;
	       dn_req_mask       = s_req_mask;
	    end
	endcase
     end // always_comb

   assign owner = t_own;

   // ======================================================================
   //  SCSI channel
   // ======================================================================
   always_comb
     begin
	n_s_state      = r_s_state;
	n_s_go         = r_s_go;
	n_s_go_nbdp    = r_s_go_nbdp;
	n_s_go_dir     = r_s_go_dir;
	n_s_go_seq     = r_s_go_seq;
	n_s_active     = r_s_active;
	n_s_dir        = r_s_dir;
	n_s_head       = r_s_head;
	n_s_nbdp       = r_s_nbdp;
	n_s_bp         = r_s_bp;
	n_s_cnt        = r_s_cnt;
	n_s_dp         = r_s_dp;
	n_s_eox        = r_s_eox;
	n_s_xie        = r_s_xie;
	n_s_ndesc      = r_s_ndesc;
	n_s_xfer       = r_s_xfer;
	n_s_seq        = r_s_seq;
	n_s_gen_ok     = r_s_gen_ok;
	n_s_avail      = r_s_avail;
	n_s_fetch      = r_s_fetch;
	n_s_wptr       = r_s_wptr;
	n_s_trunc      = r_s_trunc;
	n_s_flush      = r_s_flush;
	n_s_cancel     = r_s_cancel | (cancel & r_s_active);
	n_s_stall_post = r_s_stall_post;
	n_s_flags      = r_s_flags;
	n_s_cq_prod    = r_s_cq_prod;
	n_s_done       = 1'b0;
	n_s_irq        = 1'b0;
	n_s_hold       = r_s_hold;
	n_s_beat       = r_s_beat;
	n_s_beat_v     = r_s_beat_v;
	n_s_h          = r_s_h;
	n_s_wn         = r_s_wn;

	s_req_valid  = 1'b0;
	s_req_addr   = r_s_nbdp;
	s_req_opcode = 5'd4;
	s_req_data   = 128'd0;
	s_req_mask   = 16'hffff;

	/* this chain's staged-beat count, once its command's doorbell lands */
	if(r_s_active && !r_s_gen_ok && (rd_seq == r_s_seq))
	  begin
	     n_s_gen_ok = 1'b1;
	     n_s_avail  = rd_beats[23:0];
	  end
	if(go)
	  begin
	     n_s_go      = 1'b1;
	     n_s_go_nbdp = nbdp;
	     n_s_go_dir  = to_device;
	     n_s_go_seq  = req_seq;
	  end

	/* a cancel is acted on only where no access is outstanding */
	t_s_quiet  = (r_s_state == S_R_NEED) || (r_s_state == S_NEXT);
	t_s_cancel = (cancel || r_s_cancel) && t_s_quiet;

	case(r_s_state)
	  S_IDLE:
	    begin
	       if(r_s_go)
		 begin
		    n_s_go         = go;              /* a new go this very cycle stays latched */
		    n_s_active     = 1'b1;
		    n_s_dir        = r_s_go_dir;
		    n_s_head       = r_s_go_nbdp;
		    n_s_nbdp       = r_s_go_nbdp;
		    n_s_seq        = r_s_go_seq;
		    n_s_gen_ok     = (rd_seq == r_s_go_seq);
		    n_s_avail      = rd_beats[23:0];
		    n_s_fetch      = 24'd0;
		    n_s_wptr       = 24'd0;
		    n_s_trunc      = 1'b0;
		    n_s_flush      = 1'b0;
		    n_s_cancel     = 1'b0;
		    n_s_stall_post = 1'b0;
		    n_s_ndesc      = 8'd0;
		    n_s_xfer       = 32'd0;
		    n_s_hold       = 128'd0;
		    n_s_beat_v     = 1'b0;
		    n_s_h          = 5'd16;
		    n_s_wn         = 4'd0;
		    n_s_state      = S_DESC;
		 end
	    end
	  S_DESC:
	    begin
	       s_req_valid  = 1'b1;
	       s_req_addr   = r_s_nbdp;
	       s_req_opcode = 5'd4;
	       if(t_rsp[CH_S])
		 begin
		    n_s_bp    = w_bp;
		    n_s_cnt   = w_bc[13:0];
		    n_s_eox   = w_bc[31];
		    n_s_xie   = w_bc[29];
		    n_s_dp    = w_dp;
		    n_s_state = (w_bc[13:0] == 14'd0) ? S_NEXT : (r_s_dir ? S_W_LOAD : S_R_NEED);
		 end
	    end
	  S_R_NEED:
	    begin
	       if(t_s_cancel)
		 begin
		    if(r_s_stall_post)
		      begin
			 n_s_active = 1'b0;           /* the starved entry was this chain's post */
			 n_s_state  = S_IDLE;
		      end
		    else
		      begin
			 n_s_flags = 3'b100;
			 n_s_state = S_CQ;
		      end
		 end
	       else if(!t_s_need_beat || r_s_beat_v)
		 begin
		    n_s_state = S_R_STORE;
		 end
	       else if(r_s_gen_ok && (r_s_fetch != r_s_avail))
		 begin
		    n_s_state = S_R_FETCH;
		 end
	       else if(r_s_gen_ok && !r_s_stall_post)
		 begin
		    /* starved: the ARM staged less than the chain wants -- post now and keep
		     * stalling; the shim cancels once the status is in */
		    n_s_flags      = 3'b010;
		    n_s_stall_post = 1'b1;
		    n_s_state      = S_CQ;
		 end
	    end
	  S_R_FETCH:
	    begin
	       s_req_valid  = 1'b1;
	       s_req_addr   = STG_RD + {4'd0, r_s_fetch, 4'd0};
	       s_req_opcode = 5'd4;
	       if(t_rsp[CH_S])
		 begin
		    n_s_beat   = dn_rsp_load_data;
		    n_s_beat_v = 1'b1;
		    n_s_fetch  = r_s_fetch + 24'd1;
		    n_s_state  = S_R_STORE;
		 end
	    end
	  S_R_STORE:
	    begin
	       s_req_valid  = 1'b1;
	       s_req_addr   = {r_s_bp[31:4], 4'd0};
	       s_req_opcode = 5'd7;
	       s_req_data   = t_rot;
	       s_req_mask   = lanes({1'b0, t_s_off}, {1'b0, t_s_off} + t_s_take);
	       if(t_rsp[CH_S])
		 begin
		    if(t_s_need_beat)
		      begin
			 n_s_hold   = r_s_beat;       /* the rest of the new beat */
			 n_s_h      = r_s_h + t_s_take - 5'd16;
			 n_s_beat_v = 1'b0;
		      end
		    else
		      begin
			 n_s_h = r_s_h + t_s_take;
		      end
		    n_s_bp    = r_s_bp + {27'd0, t_s_take};
		    n_s_cnt   = r_s_cnt - {9'd0, t_s_take};
		    n_s_xfer  = r_s_xfer + {27'd0, t_s_take};
		    n_s_state = (r_s_cnt == {9'd0, t_s_take}) ? S_NEXT : S_R_NEED;
		 end
	    end
	  S_W_LOAD:
	    begin
	       s_req_valid  = 1'b1;
	       s_req_addr   = {r_s_bp[31:4], 4'd0};
	       s_req_opcode = 5'd4;
	       if(t_rsp[CH_S])
		 begin
		    if(t_s_wsum >= 5'd16)
		      begin
			 /* the outgoing beat completes; the wrapped lanes start the next */
			 n_s_beat   = (r_s_hold & bytes_of(lanes(5'd0, {1'b0, r_s_wn}))) |
				      (t_rot & bytes_of(lanes({1'b0, r_s_wn}, 5'd16)));
			 n_s_beat_v = 1'b1;
			 n_s_hold   = t_rot & bytes_of(lanes(5'd0, t_s_wsum - 5'd16));
		      end
		    else
		      begin
			 n_s_hold = r_s_hold | (t_rot & bytes_of(lanes({1'b0, r_s_wn}, t_s_wsum)));
		      end
		    n_s_wn    = t_s_wsum[3:0];
		    n_s_bp    = r_s_bp + {27'd0, t_s_take};
		    n_s_cnt   = r_s_cnt - {9'd0, t_s_take};
		    n_s_xfer  = r_s_xfer + {27'd0, t_s_take};
		    n_s_state = (t_s_wsum >= 5'd16) ? S_W_DRAIN :
				((r_s_cnt == {9'd0, t_s_take}) ? S_NEXT : S_W_LOAD);
		 end
	    end
	  S_W_DRAIN:
	    begin
	       if(r_s_wptr == NBEATS)
		 begin                                /* past the 4 MB buffer: count, drop */
		    n_s_beat_v = 1'b0;
		    n_s_trunc  = 1'b1;
		    n_s_state  = r_s_flush ? S_DONE : ((r_s_cnt == 14'd0) ? S_NEXT : S_W_LOAD);
		 end
	       else
		 begin
		    s_req_valid  = 1'b1;
		    s_req_addr   = STG_WR + {4'd0, r_s_wptr, 4'd0};
		    s_req_opcode = 5'd7;
		    s_req_data   = r_s_beat;
		    if(t_rsp[CH_S])
		      begin
			 n_s_beat_v = 1'b0;
			 n_s_wptr   = r_s_wptr + 24'd1;
			 n_s_state  = r_s_flush ? S_DONE : ((r_s_cnt == 14'd0) ? S_NEXT : S_W_LOAD);
		      end
		 end
	    end
	  S_NEXT:
	    begin
	       if(t_s_cancel)
		 begin
		    n_s_flags = 3'b100;
		    n_s_state = S_CQ;
		 end
	       /* EOX, a null link (stale/garbage descriptor) or a runaway chain: stop */
	       else if(r_s_eox || (r_s_dp == 32'd0) || (r_s_ndesc == 8'hff))
		 begin
		    if(r_s_dir && (r_s_wn != 4'd0))
		      begin
			 /* the stream's tail as a zero-padded beat */
			 n_s_beat   = r_s_hold;
			 n_s_beat_v = 1'b1;
			 n_s_hold   = 128'd0;
			 n_s_wn     = 4'd0;
			 n_s_flush  = 1'b1;
			 n_s_state  = S_W_DRAIN;
		      end
		    else
		      begin
			 n_s_state = S_DONE;
		      end
		 end
	       else
		 begin
		    n_s_nbdp  = r_s_dp;
		    n_s_ndesc = r_s_ndesc + 8'd1;
		    n_s_state = S_DESC;
		 end
	    end
	  S_DONE:
	    begin
	       n_s_done  = 1'b1;
	       n_s_irq   = r_s_xie;
	       n_s_flags = 3'b001;
	       n_s_state = S_CQ;
	    end
	  S_CQ:
	    begin
	       if((r_s_cq_prod - cq_cons) < 32'd64)
		 begin                                /* {req_seq, flags|dir|trunc, chain head, bytes} */
		    s_req_valid  = 1'b1;
		    s_req_addr   = STG_SCQ + {22'd0, r_s_cq_prod[5:0], 4'd0};
		    s_req_opcode = 5'd7;
		    s_req_data   = {r_s_seq, {27'd0, r_s_trunc, r_s_dir, r_s_flags}, r_s_head, r_s_xfer};
		    if(t_rsp[CH_S])
		      begin
			 n_s_state = S_IDX;
		      end
		 end
	    end
	  S_IDX:
	    begin
	       s_req_valid  = 1'b1;
	       s_req_addr   = STG_SIDX;
	       s_req_opcode = 5'd7;
	       s_req_data   = {96'd0, r_s_cq_prod + 32'd1};
	       s_req_mask   = 16'h000f;
	       if(t_rsp[CH_S])
		 begin
		    n_s_cq_prod = r_s_cq_prod + 32'd1;
		    if(r_s_flags == 3'b010)
		      begin
			 n_s_state = S_R_NEED;          /* starved: stall until the shim cancels */
		      end
		    else
		      begin
			 n_s_active = 1'b0;
			 n_s_state  = S_IDLE;
		      end
		 end
	    end
	  default:
	    begin
	       n_s_state = S_IDLE;
	    end
	endcase // case (r_s_state)
     end // always_comb

   // ======================================================================
   //  ENET TX channel
   // ======================================================================
   always_comb
     begin
	n_t_state = r_t_state;
	n_t_pend  = r_t_pend | tx_go;
	n_t_nbdp  = r_t_nbdp;
	n_t_bp    = r_t_bp;
	n_t_bc    = r_t_bc;
	n_t_dp    = r_t_dp;
	n_t_cnt   = r_t_cnt;
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
	n_t_hold  = r_t_hold;
	n_t_beat  = r_t_beat;
	n_t_wn    = r_t_wn;
	t_req_valid  = 1'b0;
	t_req_addr   = r_t_nbdp;
	t_req_opcode = 5'd4;
	t_req_data   = 128'd0;
	t_req_mask   = 16'hffff;
	t_t_chain_end = r_t_bc[31] | (r_t_dp == 32'd0) | (r_t_ndesc == 8'hff);
	case(r_t_state)
	  T_IDLE:
	    begin
	       if(r_t_pend | tx_go)
		 begin
		    n_t_pend  = 1'b0;
		    n_t_nbdp  = tx_nbdp;
		    n_t_ndesc = 8'd0;
		    n_t_open  = 1'b0;
		    n_t_hold  = 128'd0;
		    n_t_wn    = 4'd0;
		    n_t_state = T_DESC;
		 end
	    end
	  T_DESC:
	    begin
	       t_req_valid  = 1'b1;
	       t_req_addr   = r_t_nbdp;
	       t_req_opcode = 5'd4;
	       if(t_rsp[CH_T])
		 begin
		    n_t_bp  = w_bp;
		    n_t_bc  = w_bc;
		    n_t_dp  = w_dp;
		    n_t_cnt = w_bc[13:0];
`ifdef ENET_RING_TRACE
		    n_t_state = T_TRACE;
`else
		    n_t_state = !r_t_open ? T_SLOT : ((w_bc[13:0] == 14'd0) ? T_BCWB : T_MEM);
`endif
		 end
	    end
	  T_SLOT:
	    begin                                     /* the only wait on the ARM: before a packet */
	       if((r_t_prod - tx_cons) < NSLOT)
		 begin
		    n_t_open  = 1'b1;
		    n_t_len   = 16'd0;
		    n_t_soff  = 12'd0;
		    n_t_trunc = 1'b0;
		    n_t_first = r_t_nbdp;
		    n_t_fbc   = r_t_bc;
		    n_t_crbdp = r_t_nbdp;             /* CRBDP = this packet's head (see above) */
		    n_t_ftidx = r_t_tidx - 32'd1;
		    n_t_state = (r_t_cnt == 14'd0) ? T_BCWB : T_MEM;
		 end
	    end
	  T_MEM:
	    begin                                     /* load the aligned line holding bp: gather */
	       t_req_valid  = 1'b1;
	       t_req_addr   = {r_t_bp[31:4], 4'd0};
	       t_req_opcode = 5'd4;
	       if(t_rsp[CH_T])
		 begin
		    if(t_t_wsum >= 5'd16)
		      begin
			 n_t_beat = (r_t_hold & bytes_of(lanes(5'd0, {1'b0, r_t_wn}))) |
				    (t_rot & bytes_of(lanes({1'b0, r_t_wn}, 5'd16)));
			 n_t_hold = t_rot & bytes_of(lanes(5'd0, t_t_wsum - 5'd16));
		      end
		    else
		      begin
			 n_t_hold = r_t_hold | (t_rot & bytes_of(lanes({1'b0, r_t_wn}, t_t_wsum)));
		      end
		    n_t_wn    = t_t_wsum[3:0];
		    n_t_bp    = r_t_bp + {27'd0, t_t_take};
		    n_t_cnt   = r_t_cnt - {9'd0, t_t_take};
		    n_t_len   = r_t_len + {11'd0, t_t_take};
		    n_t_state = (t_t_wsum >= 5'd16) ? T_PUT :
				((r_t_cnt == {9'd0, t_t_take}) ? T_BCWB : T_MEM);
		 end
	    end
	  T_PUT:
	    begin                                     /* a full 16 B beat: into the slot (2 KB cap) */
	       if(r_t_soff[11])
		 begin                                /* oversize packet: drop the excess bytes */
		    n_t_trunc = 1'b1;
		    n_t_state = (r_t_cnt == 14'd0) ? T_BCWB : T_MEM;
		 end
	       else
		 begin
		    t_req_valid  = 1'b1;
		    t_req_addr   = w_tx_slot + {20'd0, r_t_soff};
		    t_req_opcode = 5'd7;
		    t_req_data   = r_t_beat;
		    if(t_rsp[CH_T])
		      begin
			 n_t_soff  = r_t_soff + 12'd16;
			 n_t_state = (r_t_cnt == 14'd0) ? T_BCWB : T_MEM;
		      end
		 end
	    end
	  T_BCWB:
	    begin                                     /* ETXD only: byte 6 of the descriptor */
	       if(r_t_nbdp == r_t_first)
		 begin                                /* the head's ETXD waits for the packet end (T_HEAD) */
		    n_t_state = (r_t_bc[30] | t_t_chain_end) ? T_FLUSH : T_NEXT;
		 end
	       else
		 begin
		    t_req_valid  = 1'b1;
		    t_req_addr   = r_t_nbdp;
		    t_req_opcode = 5'd7;
		    t_req_data   = {64'd0, bswap32(r_t_bc | BC_ETXD), 32'd0};
		    t_req_mask   = TX_BC_MASK;
		    if(t_rsp[CH_T])
		      begin
			 n_t_state = (r_t_bc[30] | t_t_chain_end) ? T_FLUSH : T_NEXT;
		      end
		 end
	    end
	  T_FLUSH:
	    begin                                     /* packet end: the partial tail beat */
	       if((r_t_wn != 4'd0) && !r_t_soff[11])
		 begin
		    t_req_valid  = 1'b1;
		    t_req_addr   = w_tx_slot + {20'd0, r_t_soff};
		    t_req_opcode = 5'd7;
		    t_req_data   = r_t_hold;
		    if(t_rsp[CH_T])
		      begin
			 n_t_hold  = 128'd0;
			 n_t_wn    = 4'd0;
			 n_t_state = T_HEAD;
		      end
		 end
	       else
		 begin
		    n_t_trunc = r_t_trunc | (r_t_wn != 4'd0);
		    n_t_hold  = 128'd0;
		    n_t_wn    = 4'd0;
		    n_t_state = T_HEAD;
		 end
	    end
	  T_HEAD:
	    begin                                     /* the whole packet is in the slot: now ETXD the head */
	       t_req_valid  = 1'b1;
	       t_req_addr   = r_t_first;
	       t_req_opcode = 5'd7;
	       t_req_data   = {64'd0, bswap32(r_t_fbc | BC_ETXD), 32'd0};
	       t_req_mask   = TX_BC_MASK;
	       if(t_rsp[CH_T])
		 begin
		    n_t_state = T_CQ;
		 end
	    end
	  T_CQ:
	    begin                                     /* {trace, ndesc, first desc, len|trunc} */
	       t_req_valid  = 1'b1;
	       t_req_addr   = STG_TXCQ + {20'd0, r_t_prod[7:0], 4'd0};
	       t_req_opcode = 5'd7;
	       t_req_data   = {r_t_ftidx, {24'd0, r_t_ndesc}, r_t_first, {15'd0, r_t_trunc, r_t_len}};
	       if(t_rsp[CH_T])
		 begin
		    n_t_state = T_IDX;
		 end
	    end
	  T_IDX:
	    begin                                     /* publish tx_prod after the entry */
	       t_req_valid  = 1'b1;
	       t_req_addr   = STG_IDX;
	       t_req_opcode = 5'd7;
	       t_req_data   = {96'd0, r_t_prod + 32'd1};
	       t_req_mask   = 16'h000f;
	       if(t_rsp[CH_T])
		 begin
		    n_t_prod  = r_t_prod + 32'd1;
		    n_t_open  = 1'b0;
		    n_t_state = T_NEXT;
		 end
	    end
	  T_NEXT:
	    begin
	       if(t_t_chain_end)
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
	    begin                                     /* {seq|ndesc, nbdp, bc as read, dp} */
	       t_req_valid  = 1'b1;
	       t_req_addr   = STG_TRC + {12'd0, r_t_tidx[15:0], 4'd0};
	       t_req_opcode = 5'd7;
	       t_req_data   = {r_t_dp, r_t_bc, r_t_nbdp, {r_t_prod[15:0], 8'd0, r_t_ndesc}};
	       if(t_rsp[CH_T])
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

   // ======================================================================
   //  ENET RX channel
   // ======================================================================
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
	n_r_soff    = r_r_soff;
	n_r_drop    = r_r_drop;
	n_r_done    = 1'b0;
	n_r_dropped = 1'b0;
	n_r_crbdp   = r_r_crbdp;
	n_r_next    = r_r_next;
	n_r_hold    = r_r_hold;
	n_r_beat    = r_r_beat;
	n_r_beat_v  = r_r_beat_v;
	n_r_h       = r_r_h;
	r_req_valid  = 1'b0;
	r_req_addr   = r_r_nbdp;
	r_req_opcode = 5'd4;
	r_req_data   = 128'd0;
	r_req_mask   = 16'hffff;
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
	       if(t_rsp[CH_R])
		 begin
		    n_r_len    = dn_rsp_load_data[13:0];
		    n_r_nbdp   = rx_nbdp;
		    n_r_hold   = 128'd0;
		    n_r_beat_v = 1'b0;
		    n_r_h      = 5'd16;
		    n_r_soff   = 12'd0;
		    n_r_drop   = 1'b0;
		    n_r_state  = R_DESC;
		 end
	    end
	  R_DESC:
	    begin
	       r_req_valid  = 1'b1;
	       r_req_addr   = r_r_nbdp;
	       r_req_opcode = 5'd4;
	       if(t_rsp[CH_R])
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
	    begin                                     /* enough staged bytes for the next store? */
	       if(!t_r_need_beat || r_r_beat_v)
		 begin
		    n_r_state = R_STORE;
		 end
	       else
		 begin
		    r_req_valid  = 1'b1;
		    r_req_addr   = w_rx_slot + {20'd0, r_r_soff};
		    r_req_opcode = 5'd4;
		    if(t_rsp[CH_R])
		      begin
			 n_r_beat   = dn_rsp_load_data;
			 n_r_beat_v = 1'b1;
			 n_r_soff   = r_r_soff + 12'd16;
			 n_r_state  = R_STORE;
		      end
		 end
	    end
	  R_STORE:
	    begin                                     /* store up to the end of bp's line: scatter */
	       r_req_valid  = 1'b1;
	       r_req_addr   = {r_r_bp[31:4], 4'd0};
	       r_req_opcode = 5'd7;
	       r_req_data   = t_rot;
	       r_req_mask   = lanes({1'b0, t_r_off}, {1'b0, t_r_off} + t_r_take);
	       if(t_rsp[CH_R])
		 begin
		    if(t_r_need_beat)
		      begin
			 n_r_hold   = r_r_beat;
			 n_r_h      = r_r_h + t_r_take - 5'd16;
			 n_r_beat_v = 1'b0;
		      end
		    else
		      begin
			 n_r_h = r_r_h + t_r_take;
		      end
		    n_r_bp    = r_r_bp + {27'd0, t_r_take};
		    n_r_cnt   = r_r_cnt - {9'd0, t_r_take};
		    n_r_state = (r_r_cnt == {9'd0, t_r_take}) ? R_BCWB : R_BEAT;
		 end
	    end
	  R_BCWB:
	    begin                                     /* release: ROWN clear + residual, bytes 6-7 */
	       r_req_valid  = 1'b1;
	       r_req_addr   = r_r_nbdp;
	       r_req_opcode = 5'd7;
	       r_req_data   = {64'd0, bswap32(w_rx_wb), 32'd0};
	       r_req_mask   = RX_BC_MASK;
	       if(t_rsp[CH_R])
		 begin
		    n_r_crbdp = r_r_nbdp;
		    n_r_next  = r_r_dp;
		    n_r_done  = 1'b1;
		    n_r_state = R_IDX;
		 end
	    end
	  R_IDX:
	    begin                                     /* publish rx_cons (+ drops) after the frame */
	       r_req_valid  = 1'b1;
	       r_req_addr   = STG_IDX;
	       r_req_opcode = 5'd7;
	       r_req_data   = {32'd0, r_r_drops + {31'd0, r_r_drop}, r_r_cons + 32'd1, 32'd0};
	       r_req_mask   = 16'h0ff0;
	       if(t_rsp[CH_R])
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

   always_ff @(posedge clk)
     begin
	if(reset)
	  begin
	     r_busy         <= 1'b0;
	     r_own          <= CH_S;
	     r_last         <= CH_R;
	     r_s_state      <= S_IDLE;
	     r_s_go         <= 1'b0;
	     r_s_go_nbdp    <= 32'd0;
	     r_s_go_dir     <= 1'b0;
	     r_s_go_seq     <= 32'd0;
	     r_s_active     <= 1'b0;
	     r_s_dir        <= 1'b0;
	     r_s_head       <= 32'd0;
	     r_s_nbdp       <= 32'd0;
	     r_s_bp         <= 32'd0;
	     r_s_cnt        <= 14'd0;
	     r_s_dp         <= 32'd0;
	     r_s_eox        <= 1'b0;
	     r_s_xie        <= 1'b0;
	     r_s_ndesc      <= 8'd0;
	     r_s_xfer       <= 32'd0;
	     r_s_seq        <= 32'd0;
	     r_s_gen_ok     <= 1'b0;
	     r_s_avail      <= 24'd0;
	     r_s_fetch      <= 24'd0;
	     r_s_wptr       <= 24'd0;
	     r_s_trunc      <= 1'b0;
	     r_s_flush      <= 1'b0;
	     r_s_cancel     <= 1'b0;
	     r_s_stall_post <= 1'b0;
	     r_s_flags      <= 3'd0;
	     r_s_cq_prod    <= 32'd0;
	     r_s_done       <= 1'b0;
	     r_s_irq        <= 1'b0;
	     r_s_hold       <= 128'd0;
	     r_s_beat       <= 128'd0;
	     r_s_beat_v     <= 1'b0;
	     r_s_h          <= 5'd16;
	     r_s_wn         <= 4'd0;
	     r_t_state      <= T_IDLE;
	     r_t_pend       <= 1'b0;
	     r_t_nbdp       <= 32'd0;
	     r_t_bp         <= 32'd0;
	     r_t_bc         <= 32'd0;
	     r_t_dp         <= 32'd0;
	     r_t_cnt        <= 14'd0;
	     r_t_open       <= 1'b0;
	     r_t_len        <= 16'd0;
	     r_t_soff       <= 12'd0;
	     r_t_trunc      <= 1'b0;
	     r_t_first      <= 32'd0;
	     r_t_fbc        <= 32'd0;
	     r_t_prod       <= 32'd0;
	     r_t_ndesc      <= 8'd0;
	     r_t_done       <= 1'b0;
	     r_t_crbdp      <= 32'd0;
	     r_t_tidx       <= 32'd0;
	     r_t_ftidx      <= 32'd0;
	     r_t_hold       <= 128'd0;
	     r_t_beat       <= 128'd0;
	     r_t_wn         <= 4'd0;
	     r_r_state      <= R_IDLE;
	     r_r_cons       <= 32'd0;
	     r_r_drops      <= 32'd0;
	     r_r_nbdp       <= 32'd0;
	     r_r_bp         <= 32'd0;
	     r_r_bc         <= 32'd0;
	     r_r_dp         <= 32'd0;
	     r_r_len        <= 14'd0;
	     r_r_cnt        <= 14'd0;
	     r_r_res        <= 14'd0;
	     r_r_soff       <= 12'd0;
	     r_r_drop       <= 1'b0;
	     r_r_done       <= 1'b0;
	     r_r_dropped    <= 1'b0;
	     r_r_crbdp      <= 32'd0;
	     r_r_next       <= 32'd0;
	     r_r_hold       <= 128'd0;
	     r_r_beat       <= 128'd0;
	     r_r_beat_v     <= 1'b0;
	     r_r_h          <= 5'd16;
	  end
	else
	  begin
	     r_busy         <= n_busy;
	     r_own          <= n_own;
	     r_last         <= n_last;
	     r_s_state      <= n_s_state;
	     r_s_go         <= n_s_go;
	     r_s_go_nbdp    <= n_s_go_nbdp;
	     r_s_go_dir     <= n_s_go_dir;
	     r_s_go_seq     <= n_s_go_seq;
	     r_s_active     <= n_s_active;
	     r_s_dir        <= n_s_dir;
	     r_s_head       <= n_s_head;
	     r_s_nbdp       <= n_s_nbdp;
	     r_s_bp         <= n_s_bp;
	     r_s_cnt        <= n_s_cnt;
	     r_s_dp         <= n_s_dp;
	     r_s_eox        <= n_s_eox;
	     r_s_xie        <= n_s_xie;
	     r_s_ndesc      <= n_s_ndesc;
	     r_s_xfer       <= n_s_xfer;
	     r_s_seq        <= n_s_seq;
	     r_s_gen_ok     <= n_s_gen_ok;
	     r_s_avail      <= n_s_avail;
	     r_s_fetch      <= n_s_fetch;
	     r_s_wptr       <= n_s_wptr;
	     r_s_trunc      <= n_s_trunc;
	     r_s_flush      <= n_s_flush;
	     r_s_cancel     <= n_s_cancel;
	     r_s_stall_post <= n_s_stall_post;
	     r_s_flags      <= n_s_flags;
	     r_s_cq_prod    <= n_s_cq_prod;
	     r_s_done       <= n_s_done;
	     r_s_irq        <= n_s_irq;
	     r_s_hold       <= n_s_hold;
	     r_s_beat       <= n_s_beat;
	     r_s_beat_v     <= n_s_beat_v;
	     r_s_h          <= n_s_h;
	     r_s_wn         <= n_s_wn;
	     r_t_state      <= n_t_state;
	     r_t_pend       <= n_t_pend;
	     r_t_nbdp       <= n_t_nbdp;
	     r_t_bp         <= n_t_bp;
	     r_t_bc         <= n_t_bc;
	     r_t_dp         <= n_t_dp;
	     r_t_cnt        <= n_t_cnt;
	     r_t_open       <= n_t_open;
	     r_t_len        <= n_t_len;
	     r_t_soff       <= n_t_soff;
	     r_t_trunc      <= n_t_trunc;
	     r_t_first      <= n_t_first;
	     r_t_fbc        <= n_t_fbc;
	     r_t_prod       <= n_t_prod;
	     r_t_ndesc      <= n_t_ndesc;
	     r_t_done       <= n_t_done;
	     r_t_crbdp      <= n_t_crbdp;
	     r_t_tidx       <= n_t_tidx;
	     r_t_ftidx      <= n_t_ftidx;
	     r_t_hold       <= n_t_hold;
	     r_t_beat       <= n_t_beat;
	     r_t_wn         <= n_t_wn;
	     r_r_state      <= n_r_state;
	     r_r_cons       <= n_r_cons;
	     r_r_drops      <= n_r_drops;
	     r_r_nbdp       <= n_r_nbdp;
	     r_r_bp         <= n_r_bp;
	     r_r_bc         <= n_r_bc;
	     r_r_dp         <= n_r_dp;
	     r_r_len        <= n_r_len;
	     r_r_cnt        <= n_r_cnt;
	     r_r_res        <= n_r_res;
	     r_r_soff       <= n_r_soff;
	     r_r_drop       <= n_r_drop;
	     r_r_done       <= n_r_done;
	     r_r_dropped    <= n_r_dropped;
	     r_r_crbdp      <= n_r_crbdp;
	     r_r_next       <= n_r_next;
	     r_r_hold       <= n_r_hold;
	     r_r_beat       <= n_r_beat;
	     r_r_beat_v     <= n_r_beat_v;
	     r_r_h          <= n_r_h;
	  end
     end // always_ff

   /* SCSI busy: a chain is latched or open (ACTIVE in hd0.cntl), through its posting */
   assign busy         = r_s_go || (r_s_state != S_IDLE);
   assign done         = r_s_done;
   assign irq          = r_s_irq;
   assign tx_done      = r_t_done;
   assign tx_crbdp     = r_t_crbdp;
   assign rx_done      = r_r_done;
   assign rx_dropped   = r_r_dropped;
   assign rx_crbdp     = r_r_crbdp;
   assign rx_next_nbdp = r_r_next;

`ifdef VERILATOR
   always_ff @(posedge clk)
     begin
	if((r_s_state == S_IDLE) && r_s_go)
	  begin
	     $display("[sdma] GO nbdp=%08x to_dev=%b", r_s_go_nbdp, r_s_go_dir);
	  end
	if((r_s_state == S_DESC) && t_rsp[CH_S])
	  begin
	     $display("[sdma] DESC @%08x -> bp=%08x cnt=%0d eox=%b dp=%08x",
		      r_s_nbdp, w_bp, w_bc[13:0], w_bc[31], w_dp);
	  end
	if(r_s_done)
	  begin
	     $display("[sdma] DONE");
	  end
     end // always_ff
`endif

endmodule // dma_engine
