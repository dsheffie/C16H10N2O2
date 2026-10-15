`include "machine.vh"
// -----------------------------------------------------------------------------
// dma_snoop_shim.sv -- make one DMA master coherent with the inclusive L2.
//
// Sits between a DMA engine (enet_dma today; scsi_dma can use it unchanged) and
// its henry mem_arbiter master port.  The engine keeps its protocol -- hold a
// request until dma_rsp_valid, one access at a time -- and every access becomes:
//
//   PRE   WBINV-snoop the line: the L2 probes the L1D (pidx) if it may hold it,
//         writes back whichever copy is dirty (incl. an L1D writeback still in
//         transit, D3) and invalidates.  DRAM is now current for the device.
//   FWD   the access itself, through the arbiter, at DRAM.
//   POST  (writes only) WBINV-snoop the line again: invalidate any copy refilled
//         since PRE (D2), so the CPU's next read misses to the device data.  A
//         wrong-path refill is clean, so this is a plain invalidate; WBINV rather than
//         a discard so a CPU store is never thrown away (it can only be present if the
//         CPU wrote a device-owned line, which the non-coherent OS rule excludes).
//   RSP   hand the response to the engine.
//
// The engine can therefore only report done (descriptor released, IRQ) after the
// POST of its last write -- D2's "completion after the post-write invalidate".  Protocol rules:
// INCLUSIVE_L2_PROTOCOL.md "DMA coherence by L2 snoop" (D1-D5).
//
// One snoop at a time: snp_req_valid is held until snp_req_ack, then the shim
// waits for snp_done.  The L2 acks a snoop only in IDLE, after any earlier snoop
// has completed, so the first snp_done after our ack is ours.
// -----------------------------------------------------------------------------
module dma_snoop_shim
  (input  logic                    clk,
   input  logic                    reset,
   // ---- upstream: the DMA engine ----
   input  logic                    up_req_valid,
   input  logic [`PA_WIDTH-1:0]    up_req_addr,
   input  logic [4:0]              up_req_opcode,      // 5'd4 line load, 5'd7 line store
   input  logic [127:0]            up_req_store_data,
   input  logic [15:0]             up_req_mask,
   output logic                    up_rsp_valid,
   output logic [127:0]            up_rsp_load_data,
   // ---- downstream: the mem_arbiter master port ----
   output logic                    dn_req_valid,
   output logic [`PA_WIDTH-1:0]    dn_req_addr,
   output logic [4:0]              dn_req_opcode,
   output logic [127:0]            dn_req_store_data,
   output logic [15:0]             dn_req_mask,
   input  logic                    dn_rsp_valid,
   input  logic [127:0]            dn_rsp_load_data,
   // ---- the core's L2 snoop port ----
   output logic                    snp_req_valid,
   output logic [`PA_WIDTH-1:0]    snp_req_addr,
   output logic                    snp_req_wbinv,      // 1 = WBINV (PRE and POST)
   input  logic                    snp_req_ack,
   input  logic                    snp_done);

   typedef enum logic [2:0] {
      S_IDLE      = 3'd0,
      S_PRE       = 3'd1,   // WBINV snoop requested, waiting for the ack
      S_PRE_WAIT  = 3'd2,   // WBINV snoop accepted, waiting for snp_done
      S_FWD       = 3'd3,   // the access, waiting for the arbiter response
      S_POST      = 3'd4,   // post-write WBINV snoop requested, waiting for the ack
      S_POST_WAIT = 3'd5,   // post-write WBINV snoop accepted, waiting for snp_done
      S_RSP       = 3'd6    // pulse the response to the engine
   } state_t;

   state_t        r_state, n_state;
   logic [127:0]  r_load_data, n_load_data;

   wire [`PA_WIDTH-1:0] w_line = {up_req_addr[`PA_WIDTH-1:4], 4'd0};
   /* ARM<->device staging (docs/arm-device-protocol.md): PA 0x1e000000-0x1effffff is
    * IP22 reserved GIO space, never mapped by the guest, so the core can never cache
    * it -- staging accesses skip both snoops */
   wire w_staging = (up_req_addr[`PA_WIDTH-1:24] == 'h1e);

   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_state <= S_IDLE;
	     r_load_data <= 'd0;
	  end
	else
	  begin
	     r_state <= n_state;
	     r_load_data <= n_load_data;
	  end
     end // always_ff

   always_comb
     begin
	n_state = r_state;
	n_load_data = r_load_data;
	up_rsp_valid = 1'b0;
	up_rsp_load_data = r_load_data;
	/* the access is presented downstream only in FWD; the engine holds it stable */
	dn_req_valid = 1'b0;
	dn_req_addr = up_req_addr;
	dn_req_opcode = up_req_opcode;
	dn_req_store_data = up_req_store_data;
	dn_req_mask = up_req_mask;
	snp_req_valid = 1'b0;
	snp_req_addr = w_line;
	snp_req_wbinv = 1'b1;
	case(r_state)
	  S_IDLE:
	    begin
	       if(up_req_valid)
		 begin
		    n_state = w_staging ? S_FWD : S_PRE;
		 end
	    end
	  S_PRE:
	    begin
	       snp_req_valid = 1'b1;
	       if(snp_req_ack)
		 begin
		    n_state = S_PRE_WAIT;
		 end
	    end
	  S_PRE_WAIT:
	    begin
	       if(snp_done)
		 begin
		    n_state = S_FWD;
		 end
	    end
	  S_FWD:
	    begin
	       dn_req_valid = 1'b1;
	       if(dn_rsp_valid)
		 begin
		    n_load_data = dn_rsp_load_data;
		    n_state = ((up_req_opcode == 5'd7) && !w_staging) ? S_POST : S_RSP;
		 end
	    end
	  S_POST:
	    begin
	       snp_req_valid = 1'b1;
	       if(snp_req_ack)
		 begin
		    n_state = S_POST_WAIT;
		 end
	    end
	  S_POST_WAIT:
	    begin
	       if(snp_done)
		 begin
		    n_state = S_RSP;
		 end
	    end
	  S_RSP:
	    begin
	       up_rsp_valid = 1'b1;
	       n_state = S_IDLE;
	    end
	  default:
	    begin
	       n_state = S_IDLE;
	    end
	endcase // case (r_state)
     end // always_comb

`ifdef VERILATOR
   /* sim-only: prove the snoops actually reach the L2 (BISTAT only counts the
    * ones that had to probe the L1D) */
   logic [63:0] r_n_acc, r_n_pre, r_n_post;
   always_ff@(posedge clk)
     begin
	if(reset)
	  begin
	     r_n_acc <= 'd0;
	     r_n_pre <= 'd0;
	     r_n_post <= 'd0;
	  end
	else
	  begin
	     r_n_acc <= r_n_acc + ((r_state == S_FWD) && dn_rsp_valid ? 64'd1 : 64'd0);
	     r_n_pre <= r_n_pre + ((r_state == S_PRE) && snp_req_ack ? 64'd1 : 64'd0);
	     r_n_post <= r_n_post + ((r_state == S_POST) && snp_req_ack ? 64'd1 : 64'd0);
	  end
     end // always_ff
   final
     begin
	$display("[dmasnoop] %m accesses %0d pre_snoops %0d post_snoops %0d", r_n_acc, r_n_pre, r_n_post);
     end
`endif

endmodule // dma_snoop_shim
