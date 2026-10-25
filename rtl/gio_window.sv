`include "machine.vh"
// -----------------------------------------------------------------------------
// gio_window.sv -- an ARM-served GIO address window (docs/newport-on-henry.md).
//
// The device behind the window is software on the ARM.  Every CPU access to the
// window becomes a 16-byte record in a capture ring in the staging region:
//   STORE: posted -- the CPU continues as soon as the record is queued.
//   READ : the record goes through the same ring (so the ARM sees it after every
//          earlier store), and the CPU load is held until the ARM writes the
//          answer and then its sequence number (AXI-Lite 0x20/0x21, then 0x22).
// Record (LE, byte i = bits [8i+7:8i]):
//   [31:0]   {type[31:30] (0 STORE, 1 READ, 2 VDMA STORE, 3 VDMA MARKER), mask[29:22], dwoff[21:0]}
//            MARKER: mask bit 0 = BEGIN (1) / END (0) of one MC VDMA transfer
//            dwoff[21] = `space`: 0 the window at BASE, 1 a second ARM-served device
//            the SoC routes here (the IOC2 8042 keyboard/mouse controller)
//   [63:32]  recno -- 1, 2, 3, ...  (numbering from 1 means the answer register's
//            reset value 0 can never match a held load)
//   [127:64] lane[0..7] = the bytes at window offset dwoff*8 + i
// Ring slot of record n = (n-1) mod RING_N.  prod (records written, LE u32) is
// published at PROD_PA after every READ record, whenever the queue drains, and at
// least every PROD_EVERY records.  The CPU is held while the ring is full
// (assigned - cons == RING_N).
// One memory port (arbiter master 2, AXI lane 1); staging PAs are not snooped.  When the
// queue holds 4 records and the next slot is 64B-aligned, they go out as one 64B burst
// write (opcode 6); otherwise one 16B write per record.
// A second source, the MC VDMA (memory -> GIO), adds 8-byte VDMA STORE records (mask
// 0xff), bracketed by a BEGIN marker (queued ahead of any CPU access after the start)
// and an END marker (after the last doubleword).  The CPU is never held for the DMA --
// a held CPU access keeps the L1D from answering the DMA's snoops: deadlock.  Instead
// the ARM acts as REX3 does during a host-data DMA: between the markers it reports busy
// and applies the CPU's stores only after END (gio_service.h).
// A record's recno is assigned when it is queued, so the ring stays in recno order.
// -----------------------------------------------------------------------------
module gio_window #(parameter logic [31:0] BASE       = 32'h1f0f0000,
		    parameter int          LG_SIZE    = 13,             // 8 KB
		    parameter logic [31:0] RING_PA    = 32'h1e200000,
		    parameter int          LG_RING_N  = 16,             // 65536 x 16 B
		    parameter logic [31:0] PROD_PA    = 32'h1e000060,
		    parameter int          PROD_EVERY = 32)
   (input  logic                  clk,
    input  logic                  reset,
    // ---- CPU side (henry_soc device FSM) ----
    input  logic                  sel,            // 1-cycle: accept this access
    input  logic                  is_store,
    input  logic                  space,          // record dwoff[21]: which ARM-served device
    input  logic [31:0]           addr,           // 16-byte aligned (the mask selects bytes)
    input  logic [15:0]           mask,
    input  logic [127:0]          wdata,
    output logic                  hit,            // combinational: addr is in the window
    output logic                  done,           // 1-cycle: the access is complete
    output logic [127:0]          rdata,          // valid with done (loads)
    // ---- MC VDMA: doublewords to store into the window ----
    input  logic                  dma_begin,      // 1-cycle: a VDMA transfer starts (queue BEGIN)
    input  logic                  dma_end,        // 1-cycle: its last doubleword was taken (queue END)
    input  logic                  dma_valid,
    input  logic [31:0]           dma_addr,       // GIO address (8-byte aligned)
    input  logic [63:0]           dma_lanes,      // lane i = the byte at dma_addr + i
    output logic                  dma_ready,      // 1-cycle: taken this cycle
    // ---- ARM doorbells (S00_AXI) ----
    input  logic [31:0]           cons,           // records the ARM has consumed
    input  logic [31:0]           ans_lo,         // answer lanes 0-3
    input  logic [31:0]           ans_hi,         // answer lanes 4-7
    input  logic [31:0]           ans_seq,        // recno of the READ answered
    // ---- debug readback ----
    output logic [31:0]           prod,
    output logic                  pend,
    output logic [31:0]           pend_seq,
    // ---- one memory port (arbiter master 2) ----
    output logic                  mem_req_valid,
    output logic [`PA_WIDTH-1:0]  mem_req_addr,
    output logic [4:0]            mem_req_opcode,
    output logic [511:0]          mem_req_store_data,  // [127:0] for a 16B write, all 64B for a burst
    output logic [15:0]           mem_req_mask,
    input  logic                  mem_rsp_valid);

   localparam int RING_N = 1 << LG_RING_N;
   localparam int QN     = 4;            // queued records not yet in memory

   typedef enum logic [1:0] {W_IDLE = 2'd0, W_REC = 2'd1, W_PROD = 2'd2, W_BURST = 2'd3} wstate_t;

   // ---- record queue ----
   logic [127:0] r_q [QN-1:0];
   logic [1:0]   r_q_head, n_q_head, r_q_tail, n_q_tail;
   logic [2:0]   r_q_cnt, n_q_cnt;

   // ---- CPU side ----
   logic         r_held, n_held;          // an accepted access not yet queued
   logic [127:0] r_held_rec, n_held_rec;
   logic         r_held_rd, n_held_rd;
   logic         r_wait, n_wait;          // a READ is queued, waiting for its answer
   logic [31:0]  r_wait_seq, n_wait_seq;
   logic [31:0]  r_assigned, n_assigned;  // recno of the last record built
   logic         r_done, n_done;
   logic [127:0] r_rdata, n_rdata;

   // ---- writer ----
   wstate_t      r_wstate, n_wstate;
   logic [31:0]  r_written, n_written;    // records in memory
   logic [31:0]  r_published, n_published;
   logic         r_rd_unpub, n_rd_unpub;  // a READ record is written but prod not yet published

   logic [127:0] t_rec, t_drec, t_brec, t_erec;
   logic         r_beg, n_beg;            // BEGIN marker to queue
   logic         r_end, n_end;            // END marker to queue
   logic [7:0]   t_lanes_mask;
   logic [63:0]  t_lanes;
   logic         t_space, t_enq, t_deq, t_deq4;
   logic [127:0] t_enq_rec;
   logic [31:0]  t_slot;
   logic [31:0]  t_ring_addr, t_prod_addr;

   assign hit            = (addr[31:LG_SIZE] == BASE[31:LG_SIZE]);
   assign done           = r_done;
   assign rdata          = r_rdata;
   assign prod           = r_published;
   assign pend           = r_wait;
   assign pend_seq       = r_wait_seq;

   always_comb
     begin
	/* the CPU's doubleword: the core issues at most 8 bytes, in one half of the line */
	t_lanes_mask = (|mask[15:8]) ? mask[15:8] : mask[7:0];
	t_lanes      = (|mask[15:8]) ? wdata[127:64] : wdata[63:0];
	t_rec        = {is_store ? t_lanes : 64'd0,      /* a READ carries no data */
			r_assigned + 32'd1,
			is_store ? 2'b00 : 2'b01,
			t_lanes_mask,
			space,
			21'({addr[LG_SIZE-1:4], |mask[15:8]})};   /* addr is line aligned: the mask picks the half */
	t_drec       = {dma_lanes, r_assigned + 32'd1, 2'b10, 8'hff, 1'b0, 21'(dma_addr[LG_SIZE-1:3])};
	t_brec       = {64'd0, r_assigned + 32'd1, 2'b11, 8'h01, 22'd0};
	t_erec       = {64'd0, r_assigned + 32'd1, 2'b11, 8'h00, 22'd0};
	/* ring space counts every record built so far, queued or written */
	t_space = (r_assigned - cons) < 32'(RING_N);

	n_held      = r_held;
	n_held_rec  = r_held_rec;
	n_held_rd   = r_held_rd;
	n_wait      = r_wait;
	n_wait_seq  = r_wait_seq;
	n_assigned  = r_assigned;
	n_done      = 1'b0;
	n_rdata     = r_rdata;
	t_enq       = 1'b0;
	t_enq_rec   = t_rec;
	dma_ready   = 1'b0;
	n_beg       = r_beg | dma_begin;
	n_end       = r_end | dma_end;

	if(r_beg && !r_end && (r_q_cnt != 3'(QN)) && t_space)
	  begin
	     /* BEGIN goes first (but after the previous transfer's END): a CPU access
	      * this cycle waits one cycle as a held one */
	     n_assigned = r_assigned + 32'd1;
	     t_enq      = 1'b1;
	     t_enq_rec  = t_brec;
	     n_beg      = dma_begin;
	     if(sel)
	       begin
		  n_held     = 1'b1;
		  n_held_rec = t_rec;
		  n_held_rd  = !is_store;
	       end
	  end
	else if(r_end && (!dma_valid || r_beg) && (r_q_cnt != 3'(QN)) && t_space)
	  begin
	     /* END goes ahead of any CPU access that arrives after the transfer finished:
	      * the CPU sees DMA_RUN clear at the same pulse, so its next GIO access (e.g.
	      * a GFXBUSY read) must reach the ARM after END.  Safe to hold the CPU here:
	      * the transfer's last doubleword (and its snoops) are already done. */
	     n_assigned = r_assigned + 32'd1;
	     t_enq      = 1'b1;
	     t_enq_rec  = t_erec;
	     n_end      = dma_end;
	     if(sel)
	       begin
		  n_held     = 1'b1;
		  n_held_rec = t_rec;
		  n_held_rd  = !is_store;
	       end
	  end
	else if(sel)
	  begin
	     /* a new access: queue it now (recno = assigned + 1), or hold it (also while
	      * a finished transfer's END is still waiting for queue room) */
	     if(!r_beg && !r_end && (r_q_cnt != 3'(QN)) && t_space)
	       begin
		  n_assigned = r_assigned + 32'd1;
		  t_enq = 1'b1;
		  if(is_store)
		    begin
		       n_done = 1'b1;          /* posted */
		    end
		  else
		    begin
		       n_wait     = 1'b1;
		       n_wait_seq = r_assigned + 32'd1;
		    end
	       end
	     else
	       begin
		  n_held     = 1'b1;
		  n_held_rec = t_rec;
		  n_held_rd  = !is_store;
	       end
	  end
	else if(r_held && !r_beg && !r_end)
	  begin
	     if((r_q_cnt != 3'(QN)) && t_space)
	       begin
		  /* the held record takes its recno now */
		  n_assigned = r_assigned + 32'd1;
		  t_enq      = 1'b1;
		  t_enq_rec  = {r_held_rec[127:64], r_assigned + 32'd1, r_held_rec[31:0]};
		  n_held     = 1'b0;
		  if(r_held_rd)
		    begin
		       n_wait     = 1'b1;
		       n_wait_seq = r_assigned + 32'd1;
		    end
		  else
		    begin
		       n_done = 1'b1;
		    end
	       end
	  end
	else if(dma_valid && !r_beg && (r_q_cnt != 3'(QN)) && t_space)
	  begin
	     /* a VDMA doubleword: a posted store record */
	     n_assigned = r_assigned + 32'd1;
	     t_enq      = 1'b1;
	     t_enq_rec  = t_drec;
	     dma_ready  = 1'b1;
	  end

	if(r_wait && (ans_seq == r_wait_seq))
	  begin
	     n_wait  = 1'b0;
	     n_done  = 1'b1;
	     n_rdata = {ans_hi, ans_lo, ans_hi, ans_lo};
	  end
     end // always_comb

   // ---- writer: queue head -> ring slot, then publish prod when due ----
   always_comb
     begin
	n_wstate    = r_wstate;
	n_written   = r_written;
	n_published = r_published;
	n_rd_unpub  = r_rd_unpub;
	t_deq       = 1'b0;
	t_deq4      = 1'b0;
	t_slot      = r_written & 32'(RING_N - 1);   /* record r_written+1 goes to slot r_written */
	t_ring_addr = RING_PA + (t_slot << 4);
	t_prod_addr = PROD_PA & ~32'hf;
	mem_req_valid      = 1'b0;
	mem_req_addr       = '0;
	mem_req_opcode     = 5'd7;
	mem_req_store_data = '0;
	mem_req_mask       = 16'hffff;
	case(r_wstate)
	  W_IDLE:
	    begin
	       if((r_published != r_written) &&
		  (r_rd_unpub || (r_q_cnt == 3'd0) || ((r_written - r_published) >= 32'(PROD_EVERY))))
		 begin
		    n_wstate = W_PROD;
		 end
	       else if((r_q_cnt == 3'(QN)) && (r_written[1:0] == 2'd0))
		 begin
		    n_wstate = W_BURST;       /* 4 records filling one 64B ring line */
		 end
	       else if(r_q_cnt != 3'd0)
		 begin
		    n_wstate = W_REC;
		 end
	    end
	  W_REC:
	    begin
	       mem_req_valid      = 1'b1;
	       mem_req_addr       = `PA_WIDTH'(t_ring_addr);
	       mem_req_store_data = {384'd0, r_q[r_q_head]};
	       if(mem_rsp_valid)
		 begin
		    t_deq     = 1'b1;
		    n_written = r_written + 32'd1;
		    if(r_q[r_q_head][31:30] == 2'b01)
		      begin
			 n_rd_unpub = 1'b1;
		      end
		    n_wstate = W_IDLE;
		 end
	    end
	  W_PROD:
	    begin
	       mem_req_valid      = 1'b1;
	       mem_req_addr       = `PA_WIDTH'(t_prod_addr);
	       mem_req_store_data = {384'd0, {96'd0, r_written} << (8 * PROD_PA[3:0])};
	       mem_req_mask       = 16'h000f << PROD_PA[3:0];
	       if(mem_rsp_valid)
		 begin
		    n_published = r_written;
		    n_rd_unpub  = 1'b0;
		    n_wstate    = W_IDLE;
		 end
	    end
	  W_BURST:
	    begin
	       mem_req_valid      = 1'b1;
	       mem_req_addr       = `PA_WIDTH'(t_ring_addr);   /* slot % 4 == 0: 64B-aligned */
	       mem_req_opcode     = 5'd6;
	       mem_req_store_data = {r_q[r_q_head + 2'd3], r_q[r_q_head + 2'd2],
				     r_q[r_q_head + 2'd1], r_q[r_q_head]};
	       if(mem_rsp_valid)
		 begin
		    t_deq4    = 1'b1;
		    n_written = r_written + 32'd4;
		    if((r_q[r_q_head][31:30] == 2'b01) || (r_q[r_q_head + 2'd1][31:30] == 2'b01) ||
		       (r_q[r_q_head + 2'd2][31:30] == 2'b01) || (r_q[r_q_head + 2'd3][31:30] == 2'b01))
		      begin
			 n_rd_unpub = 1'b1;
		      end
		    n_wstate = W_IDLE;
		 end
	    end
	  default:
	    begin
	       n_wstate = W_IDLE;
	    end
	endcase // case (r_wstate)

	n_q_head = t_deq4 ? r_q_head : (t_deq ? (r_q_head + 2'd1) : r_q_head);   /* +4 wraps to itself */
	n_q_tail = t_enq ? (r_q_tail + 2'd1) : r_q_tail;
	n_q_cnt  = r_q_cnt + (t_enq ? 3'd1 : 3'd0) - (t_deq ? 3'd1 : 3'd0) - (t_deq4 ? 3'd4 : 3'd0);
     end // always_comb

   always_ff@(posedge clk)
     begin
	if(t_enq)
	  begin
	     r_q[r_q_tail] <= t_enq_rec;
	  end
     end // always_ff

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_q_head    <= '0;
	     r_q_tail    <= '0;
	     r_q_cnt     <= '0;
	     r_held      <= 1'b0;
	     r_held_rec  <= '0;
	     r_held_rd   <= 1'b0;
	     r_wait      <= 1'b0;
	     r_wait_seq  <= '0;
	     r_assigned  <= '0;
	     r_done      <= 1'b0;
	     r_rdata     <= '0;
	     r_wstate    <= W_IDLE;
	     r_written   <= '0;
	     r_published <= '0;
	     r_rd_unpub  <= 1'b0;
	     r_beg       <= 1'b0;
	     r_end       <= 1'b0;
	  end
	else
	  begin
	     r_q_head    <= n_q_head;
	     r_q_tail    <= n_q_tail;
	     r_q_cnt     <= n_q_cnt;
	     r_held      <= n_held;
	     r_held_rec  <= n_held_rec;
	     r_held_rd   <= n_held_rd;
	     r_wait      <= n_wait;
	     r_wait_seq  <= n_wait_seq;
	     r_assigned  <= n_assigned;
	     r_done      <= n_done;
	     r_rdata     <= n_rdata;
	     r_wstate    <= n_wstate;
	     r_written   <= n_written;
	     r_published <= n_published;
	     r_rd_unpub  <= n_rd_unpub;
	     r_beg       <= n_beg;
	     r_end       <= n_end;
	  end
     end // always_ff

endmodule // gio_window
