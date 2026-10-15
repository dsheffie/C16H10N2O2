`include "machine.vh"
// -----------------------------------------------------------------------------
// scsi_stage.sv -- scsi_dma's disk side, served from the ARM staging region
// (docs/arm-device-protocol.md) instead of AXI-Lite beat FIFOs.
//
// READ  (disk -> mem): per chain the ARM stages the transfer's remaining bytes as
//       16 B beats at STG_RD, writes the beat count, then the command's req_seq (the
//       pairing tag, written last).  This adapter reads them ahead
//       (2 beats) and feeds scsi_dma's disk_rd port.  The ARM never sizes the chain:
//       scsi_dma consumes what the chain needs and the completion says how much.
// WRITE (mem -> disk): scsi_dma's beats are stored to STG_WR (2-beat buffer; a full
//       buffer back-pressures the engine).
// Each chain posts one completion entry {bytes, chain head, flags, req_seq} to a
// 64-entry ring and bumps scsi_cq_prod in the control block.  req_seq (the shim's
// per-command/resume sequence, latched at go) pairs everything exactly: staged beats
// feed only the chain of their own command, and the ARM waits for the entry carrying
// its request's seq, skipping entries from chains it never waited for (a no-data
// command can still run the engine).  Flags:
//   done    -- the chain completed (writes: after its last beat reached staging)
//   starved -- READ wanted more beats than were staged (a short transfer: the ARM
//              posts the status, and the shim then cancels the engine)
//   aborted -- the shim cancelled the engine first
// One memory port, shared with scsi_dma (one access outstanding, round-robin), into
// the SCSI snoop shim; staging PAs pass it unsnooped.
// -----------------------------------------------------------------------------
module scsi_stage
   (input  logic         clk,
    input  logic         reset,
    // ---- ARM doorbells ----
    input  logic [31:0]  rd_beats,       // beats staged for the READ chain of command rd_seq
    input  logic [31:0]  rd_seq,         // written after rd_beats: which command they belong to
    input  logic [31:0]  cq_cons,        // completions the ARM has consumed
    // ---- scsi_shim / scsi_dma control taps ----
    input  logic [31:0]  req_seq,        // the shim's command sequence (stable from select to done)
    input  logic         eng_go,
    input  logic [31:0]  eng_nbdp,
    input  logic         eng_to_dev,
    input  logic         eng_done,
    input  logic         eng_rd_stalled,
    input  logic         eng_cancel,
    input  logic [31:0]  eng_xfer_bytes,
    // ---- scsi_dma disk side ----
    input  logic         disk_rd_en,
    output logic [127:0] disk_rd_data,
    output logic         disk_rd_valid,
    input  logic         disk_wr_en,
    input  logic [127:0] disk_wr_data,
    output logic         disk_wr_full,
    // ---- scsi_dma memory port (upstream) ----
    input  logic                  e_req_valid,
    input  logic [`PA_WIDTH-1:0]  e_req_addr,
    input  logic [4:0]            e_req_opcode,
    input  logic [127:0]          e_req_store_data,
    input  logic [15:0]           e_req_mask,
    output logic                  e_rsp_valid,
    output logic [127:0]          e_rsp_load_data,
    // ---- shared port -> the SCSI dma_snoop_shim ----
    output logic                  dn_req_valid,
    output logic [`PA_WIDTH-1:0]  dn_req_addr,
    output logic [4:0]            dn_req_opcode,
    output logic [127:0]          dn_req_store_data,
    output logic [15:0]           dn_req_mask,
    input  logic                  dn_rsp_valid,
    input  logic [127:0]          dn_rsp_load_data);

   localparam logic [31:0] STG_SIDX = 32'h1e000050;   // scsi_cq_prod (word 0 of the line)
   localparam logic [31:0] STG_SCQ  = 32'h1e003000;   // 64 x 16 B completions
   localparam logic [31:0] STG_RD   = 32'h1e800000;   // 4 MB: ARM -> device beats
   localparam logic [31:0] STG_WR   = 32'h1ec00000;   // 4 MB: device -> ARM beats
   localparam logic [23:0] NBEATS   = 24'd262144;     // 4 MB / 16

   typedef enum logic [2:0] {
      A_IDLE  = 3'd0,
      A_FETCH = 3'd1,     // load the next staged READ beat
      A_DRAIN = 3'd2,     // store the oldest WRITE beat
      A_CQ    = 3'd3,     // write the completion entry
      A_IDX   = 3'd4      // publish scsi_cq_prod
   } astate_t;

   astate_t       r_state, n_state;
   logic          r_active, n_active;        // a chain is open (go seen, not yet posted)
   logic          r_dir, n_dir;              // 1 = WRITE (mem -> disk)
   logic [31:0]   r_nbdp, n_nbdp;
   logic [7:0]    r_chain, n_chain;          // chain id: drops a read-ahead from an older chain
   logic [7:0]    r_fchain, n_fchain;        // chain id of the fetch in flight
   logic [7:0]    r_pchain, n_pchain;        // chain id being posted
   logic          r_gen_ok, n_gen_ok;        // this chain's staged-beat count is known
   logic [31:0]   r_seq, n_seq;              // req_seq of the open chain
   logic [23:0]   r_avail, n_avail;          // beats staged for this READ chain
   logic [23:0]   r_fetch, n_fetch;          // beats fetched so far
   logic [23:0]   r_wptr, n_wptr;            // beats stored so far (WRITE)
   logic          r_trunc, n_trunc;          // WRITE overflowed STG_WR
   logic          r_done_seen, n_done_seen;
   logic          r_abort_seen, n_abort_seen;
   logic [2:0]    r_flags, n_flags;          // {aborted, starved, done} as posted
   logic [31:0]   r_bytes, n_bytes;
   logic [31:0]   r_cq_prod, n_cq_prod;
   /* 2-entry beat buffers (read-ahead, write-behind) */
   logic [127:0]  r_rb [1:0];
   logic          r_rb_h, n_rb_h, r_rb_t, n_rb_t;
   logic [1:0]    r_rb_n, n_rb_n;
   logic [127:0]  r_wb [1:0];
   logic          r_wb_h, n_wb_h, r_wb_t, n_wb_t;
   logic [1:0]    r_wb_n, n_wb_n;
   logic          t_rb_push, t_wb_pop;
   /* port mux */
   logic          r_busy, n_busy, r_own_a, n_own_a, r_last_a, n_last_a;
   logic          t_grant_a, t_a_rsp;
   logic          a_req_valid;
   logic [31:0]   a_req_addr;
   logic [4:0]    a_req_opcode;
   logic [127:0]  a_req_data;
   logic [15:0]   a_req_mask;
   logic          t_starved, t_post, t_db_new;

   always_comb
     begin
	t_grant_a = r_busy ? r_own_a : (a_req_valid & (!e_req_valid | !r_last_a));
	n_busy    = r_busy;
	n_own_a   = r_own_a;
	n_last_a  = r_last_a;
	if(!r_busy && (e_req_valid || a_req_valid))
	  begin
	     n_busy   = 1'b1;
	     n_own_a  = t_grant_a;
	     n_last_a = t_grant_a;
	  end
	if(r_busy && dn_rsp_valid)
	  begin
	     n_busy = 1'b0;
	  end
	dn_req_valid      = t_grant_a ? a_req_valid : e_req_valid;
	dn_req_addr       = t_grant_a ? {{(`PA_WIDTH-32){1'b0}}, a_req_addr} : e_req_addr;
	dn_req_opcode     = t_grant_a ? a_req_opcode : e_req_opcode;
	dn_req_store_data = t_grant_a ? a_req_data : e_req_store_data;
	dn_req_mask       = t_grant_a ? a_req_mask : e_req_mask;
	e_rsp_valid       = r_busy && !r_own_a && dn_rsp_valid;
	e_rsp_load_data   = dn_rsp_load_data;
	t_a_rsp           = r_busy && r_own_a && dn_rsp_valid;
     end // always_comb

   always_comb
     begin
	n_state      = r_state;
	n_active     = r_active;
	n_dir        = r_dir;
	n_nbdp       = r_nbdp;
	n_chain      = r_chain;
	n_fchain     = r_fchain;
	n_pchain     = r_pchain;
	n_gen_ok     = r_gen_ok;
	n_seq        = r_seq;
	n_avail      = r_avail;
	n_fetch      = r_fetch;
	n_wptr       = r_wptr;
	n_trunc      = r_trunc;
	n_done_seen  = r_done_seen | eng_done;
	n_abort_seen = r_abort_seen | (eng_cancel & r_active);
	n_flags      = r_flags;
	n_bytes      = r_bytes;
	n_cq_prod    = r_cq_prod;
	n_rb_h       = r_rb_h;
	n_rb_t       = r_rb_t;
	n_rb_n       = r_rb_n;
	n_wb_h       = r_wb_h;
	n_wb_t       = r_wb_t;
	n_wb_n       = r_wb_n;
	t_rb_push    = 1'b0;
	t_wb_pop     = 1'b0;
	a_req_valid  = 1'b0;
	a_req_addr   = STG_SIDX;
	a_req_opcode = 5'd4;
	a_req_data   = 128'd0;
	a_req_mask   = 16'hffff;
	t_db_new     = (rd_seq == r_seq);           /* staged for THIS chain's command */
	/* the engine wants a beat the ARM never staged: a short READ */
	t_starved    = r_active && !r_dir && r_gen_ok && eng_rd_stalled &&
		       (r_fetch == r_avail) && (r_rb_n == 2'd0) && (r_state != A_FETCH);
	/* post once per chain, after a WRITE's last beat reached staging */
	t_post       = r_active && ((r_done_seen && (r_wb_n == 2'd0) && !disk_wr_en) ||
				    t_starved || r_abort_seen) &&
		       ((r_cq_prod - cq_cons) < 32'd64);

	/* engine side of the beat buffers */
	if(disk_rd_en && (r_rb_n != 2'd0))
	  begin
	     n_rb_h = ~r_rb_h;
	     n_rb_n = n_rb_n - 2'd1;
	  end
	if(disk_wr_en && (r_wb_n != 2'd2))
	  begin
	     n_wb_t = ~r_wb_t;
	     n_wb_n = n_wb_n + 2'd1;
	  end

	/* the staged-beat count for this READ chain, once its command's doorbell lands */
	if(r_active && !r_gen_ok && t_db_new)
	  begin
	     n_gen_ok = 1'b1;
	     n_avail  = rd_beats[23:0];
	  end

	case(r_state)
	  A_IDLE:
	    begin
	       if(r_wb_n != 2'd0)
		 begin
		    n_state = A_DRAIN;
		 end
	       else if(t_post)
		 begin
		    n_flags = {r_abort_seen & !r_done_seen, t_starved & !r_done_seen, r_done_seen};
		    n_bytes  = eng_xfer_bytes;
		    n_pchain = r_chain;
		    n_state  = A_CQ;
		 end
	       else if(r_active && !r_dir && r_gen_ok && (r_fetch != r_avail) && (r_rb_n != 2'd2))
		 begin
		    n_fchain = r_chain;
		    n_state  = A_FETCH;
		 end
	    end
	  A_FETCH:
	    begin
	       a_req_valid  = 1'b1;
	       a_req_addr   = STG_RD + {4'd0, r_fetch, 4'd0};
	       a_req_opcode = 5'd4;
	       if(t_a_rsp)
		 begin
		    if(r_fchain == r_chain)
		      begin                         // a fetch issued before a new go is dropped
			 t_rb_push = 1'b1;
			 n_rb_t    = ~r_rb_t;
			 n_rb_n    = n_rb_n + 2'd1;
			 n_fetch   = r_fetch + 24'd1;
		      end
		    n_state = A_IDLE;
		 end
	    end
	  A_DRAIN:
	    begin
	       if(r_wptr == NBEATS)
		 begin                              // past the 4 MB buffer: count, drop
		    t_wb_pop = 1'b1;
		    n_wb_h   = ~r_wb_h;
		    n_wb_n   = n_wb_n - 2'd1;
		    n_trunc  = 1'b1;
		    n_state  = A_IDLE;
		 end
	       else
		 begin
		    a_req_valid  = 1'b1;
		    a_req_addr   = STG_WR + {4'd0, r_wptr, 4'd0};
		    a_req_opcode = 5'd7;
		    a_req_data   = r_wb[r_wb_h];
		    if(t_a_rsp)
		      begin
			 t_wb_pop = 1'b1;
			 n_wb_h   = ~r_wb_h;
			 n_wb_n   = n_wb_n - 2'd1;
			 n_wptr   = r_wptr + 24'd1;
			 n_state  = A_IDLE;
		      end
		 end
	    end
	  A_CQ:
	    begin                                   // {bytes, chain head, flags|dir|trunc, gen}
	       a_req_valid  = 1'b1;
	       a_req_addr   = STG_SCQ + {22'd0, r_cq_prod[5:0], 4'd0};
	       a_req_opcode = 5'd7;
	       a_req_data   = {r_seq, {27'd0, r_trunc, r_dir, r_flags}, r_nbdp, r_bytes};
	       if(t_a_rsp)
		 begin
		    n_state = A_IDX;
		 end
	    end
	  A_IDX:
	    begin
	       a_req_valid  = 1'b1;
	       a_req_addr   = STG_SIDX;
	       a_req_opcode = 5'd7;
	       a_req_data   = {96'd0, r_cq_prod + 32'd1};
	       a_req_mask   = 16'h000f;
	       if(t_a_rsp)
		 begin
		    n_cq_prod = r_cq_prod + 32'd1;
		    n_active  = r_active & (r_chain != r_pchain);   // a newer chain stays open
		    n_state   = A_IDLE;
		 end
	    end
	  default:
	    begin
	       n_state = A_IDLE;
	    end
	endcase // case (r_state)

	/* a new chain: everything restarts (a pending read-ahead is dropped by tag) */
	if(eng_go)
	  begin
	     n_active     = 1'b1;
	     n_dir        = eng_to_dev;
	     n_nbdp       = eng_nbdp;
	     n_chain      = r_chain + 8'd1;
	     n_fetch      = 24'd0;
	     n_wptr       = 24'd0;
	     n_trunc      = 1'b0;
	     n_done_seen  = 1'b0;
	     n_abort_seen = 1'b0;
	     n_rb_h       = 1'b0;
	     n_rb_t       = 1'b0;
	     n_rb_n       = 2'd0;
	     n_seq        = req_seq;
	     n_gen_ok     = (rd_seq == req_seq);
	     n_avail      = rd_beats[23:0];
	  end
     end // always_comb

   always_ff@(posedge clk)
     begin
	if(t_rb_push)
	  begin
	     r_rb[r_rb_t] <= dn_rsp_load_data;
	  end
	if(disk_wr_en && (r_wb_n != 2'd2))
	  begin
	     r_wb[r_wb_t] <= disk_wr_data;
	  end
     end // always_ff

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_state      <= A_IDLE;
	     r_active     <= 1'b0;
	     r_dir        <= 1'b0;
	     r_nbdp       <= 32'd0;
	     r_chain      <= 8'd0;
	     r_fchain     <= 8'd0;
	     r_pchain     <= 8'd0;
	     r_gen_ok     <= 1'b0;
	     r_seq        <= 32'd0;
	     r_avail      <= 24'd0;
	     r_fetch      <= 24'd0;
	     r_wptr       <= 24'd0;
	     r_trunc      <= 1'b0;
	     r_done_seen  <= 1'b0;
	     r_abort_seen <= 1'b0;
	     r_flags      <= 3'd0;
	     r_bytes      <= 32'd0;
	     r_cq_prod    <= 32'd0;
	     r_rb_h       <= 1'b0;
	     r_rb_t       <= 1'b0;
	     r_rb_n       <= 2'd0;
	     r_wb_h       <= 1'b0;
	     r_wb_t       <= 1'b0;
	     r_wb_n       <= 2'd0;
	     r_busy       <= 1'b0;
	     r_own_a      <= 1'b0;
	     r_last_a     <= 1'b0;
	  end
	else
	  begin
	     r_state      <= n_state;
	     r_active     <= n_active;
	     r_dir        <= n_dir;
	     r_nbdp       <= n_nbdp;
	     r_chain      <= n_chain;
	     r_fchain     <= n_fchain;
	     r_pchain     <= n_pchain;
	     r_gen_ok     <= n_gen_ok;
	     r_seq        <= n_seq;
	     r_avail      <= n_avail;
	     r_fetch      <= n_fetch;
	     r_wptr       <= n_wptr;
	     r_trunc      <= n_trunc;
	     r_done_seen  <= n_done_seen;
	     r_abort_seen <= n_abort_seen;
	     r_flags      <= n_flags;
	     r_bytes      <= n_bytes;
	     r_cq_prod    <= n_cq_prod;
	     r_rb_h       <= n_rb_h;
	     r_rb_t       <= n_rb_t;
	     r_rb_n       <= n_rb_n;
	     r_wb_h       <= n_wb_h;
	     r_wb_t       <= n_wb_t;
	     r_wb_n       <= n_wb_n;
	     r_busy       <= n_busy;
	     r_own_a      <= n_own_a;
	     r_last_a     <= n_last_a;
	  end
     end // always_ff

   assign disk_rd_valid = (r_rb_n != 2'd0);
   assign disk_rd_data  = r_rb[r_rb_h];
   assign disk_wr_full  = (r_wb_n == 2'd2);

endmodule // scsi_stage
