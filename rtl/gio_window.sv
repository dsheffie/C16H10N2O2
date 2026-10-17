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
//   [31:0]   {type[31:30] (0 STORE, 1 READ), mask[29:22], dwoff[21:0]}
//            dwoff[21] = `space`: 0 the window at BASE, 1 a second ARM-served device
//            the SoC routes here (the IOC2 8042 keyboard/mouse controller)
//   [63:32]  recno -- 1, 2, 3, ...  (numbering from 1 means the answer register's
//            reset value 0 can never match a held load)
//   [127:64] lane[0..7] = the bytes at window offset dwoff*8 + i
// Ring slot of record n = (n-1) mod RING_N.  prod (records written, LE u32) is
// published at PROD_PA after every READ record, whenever the queue drains, and at
// least every PROD_EVERY records.  The CPU is held while the ring is full
// (assigned - cons == RING_N).
// One memory port (arbiter master 2); staging PAs are not snooped.
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
    output logic [127:0]          mem_req_store_data,
    output logic [15:0]           mem_req_mask,
    input  logic                  mem_rsp_valid);

   localparam int RING_N = 1 << LG_RING_N;
   localparam int QN     = 4;            // queued records not yet in memory

   typedef enum logic [1:0] {W_IDLE = 2'd0, W_REC = 2'd1, W_PROD = 2'd2} wstate_t;

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

   logic [127:0] t_rec;
   logic [7:0]   t_lanes_mask;
   logic [63:0]  t_lanes;
   logic         t_space, t_enq, t_deq;
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

	if(sel)
	  begin
	     /* a new access: build its record now (recno = assigned + 1) */
	     n_assigned = r_assigned + 32'd1;
	     if((r_q_cnt != 3'(QN)) && t_space)
	       begin
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
	else if(r_held && (r_q_cnt != 3'(QN)) && ((r_held_rec[63:32] - 32'd1 - cons) < 32'(RING_N)))
	  begin
	     t_enq     = 1'b1;
	     t_enq_rec = r_held_rec;
	     n_held    = 1'b0;
	     if(r_held_rd)
	       begin
		  n_wait     = 1'b1;
		  n_wait_seq = r_held_rec[63:32];
	       end
	     else
	       begin
		  n_done = 1'b1;
	       end
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
	       else if(r_q_cnt != 3'd0)
		 begin
		    n_wstate = W_REC;
		 end
	    end
	  W_REC:
	    begin
	       mem_req_valid      = 1'b1;
	       mem_req_addr       = `PA_WIDTH'(t_ring_addr);
	       mem_req_store_data = r_q[r_q_head];
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
	       mem_req_store_data = {96'd0, r_written} << (8 * PROD_PA[3:0]);
	       mem_req_mask       = 16'h000f << PROD_PA[3:0];
	       if(mem_rsp_valid)
		 begin
		    n_published = r_written;
		    n_rd_unpub  = 1'b0;
		    n_wstate    = W_IDLE;
		 end
	    end
	  default:
	    begin
	       n_wstate = W_IDLE;
	    end
	endcase // case (r_wstate)

	n_q_head = t_deq ? (r_q_head + 2'd1) : r_q_head;
	n_q_tail = t_enq ? (r_q_tail + 2'd1) : r_q_tail;
	n_q_cnt  = r_q_cnt + (t_enq ? 3'd1 : 3'd0) - (t_deq ? 3'd1 : 3'd0);
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
	  end
     end // always_ff

endmodule // gio_window
