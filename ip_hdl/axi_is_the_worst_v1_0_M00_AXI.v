
`timescale 1 ns / 1 ps



module axi_is_the_worst_v1_0_M00_AXI #
  (
   // Users to add parameters here
   
   // User parameters ends
   // Do not modify the parameters beyond this line

   // Base address of targeted slave
   parameter  C_M_TARGET_SLAVE_BASE_ADDR	= 32'h40000000,
   // Burst Length. Supports 1, 2, 4, 8, 16, 32, 64, 128, 256 burst lengths
   parameter integer C_M_AXI_BURST_LEN	= 16,
   // Thread ID Width
   parameter integer C_M_AXI_ID_WIDTH	= 1,
   // Width of Address Bus
   parameter integer C_M_AXI_ADDR_WIDTH	= 32,
   // Width of Data Bus
   parameter integer C_M_AXI_DATA_WIDTH	= 32,
   // Width of User Write Address Bus
   parameter integer C_M_AXI_AWUSER_WIDTH	= 0,
   // Width of User Read Address Bus
   parameter integer C_M_AXI_ARUSER_WIDTH	= 0,
   // Width of User Write Data Bus
   parameter integer C_M_AXI_WUSER_WIDTH	= 0,
   // Width of User Read Data Bus
   parameter integer C_M_AXI_RUSER_WIDTH	= 0,
   // Width of User Response Bus
   parameter integer C_M_AXI_BUSER_WIDTH	= 0
   )
   (
    // Users to add ports here
    input wire				     rv_reset,
    input wire				     step_txn,
    input wire				     ack_txn,
    input wire [31:0]			     baseaddr,
    input wire [31:0]			     addrmask,
    input wire [35:0]			     cpuaddr,
    output wire [63:0]			     txn_cnt,
    output wire [63:0]			     txn_lat,
    
    output wire [127:0]			     load_data,
    output wire [3:0]			     state,
    output wire [31:0]			     last_addr,
    output wire [31:0]			     last_data,
    output wire [63:0]			     axi_reads,
    output wire [63:0]			     axi_writes,
    output wire				     axi_busy,
    
    input wire [127:0]			     mem_req_store_data,
    
    input wire				     mem_req_valid,
    input wire [4:0]			     mem_opcode,
    input wire [15:0]			     mem_mask,
    output wire				     mem_rsp_valid,
    output wire				     mem_rsp_bad,
    output wire				     mem_req_gnt,

    input wire [1:0]			     mem_req_tag,
    output wire [1:0]			     mem_rsp_tag,
    /* lane 1 (AXI ID 1): DMA engine + GIO ring writer + MC fill, one request
     * outstanding, concurrent with lane 0 (CPU, AXI ID 0).  Opcodes 4/7 = 16B
     * read/masked write as on lane 0; 5/6 = 64B read/write (4-beat INCR burst,
     * address forced 64B-aligned, full strobes). */
    input wire				     mem2_req_valid,
    input wire [35:0]			     mem2_req_addr,
    input wire [4:0]			     mem2_opcode,
    input wire [15:0]			     mem2_mask,
    input wire [511:0]			     mem2_req_store_data,
    output wire				     mem2_rsp_valid,
    output wire				     mem2_rsp_bad,
    output wire [511:0]			     mem2_load_data,

    input wire [31:0]			     max_fetches,
    input wire				     sgi_mode,
    
    // User ports ends
    // Do not modify the ports beyond this line

    // Initiate AXI transactions
    input wire				     INIT_AXI_TXN,
    // Asserts when transaction is complete
    output wire				     TXN_DONE,
    // Asserts when ERROR is detected
    output reg				     ERROR,
    // Global Clock Signal.
    input wire				     M_AXI_ACLK,
    // Global Reset Singal. This Signal is Active Low
    input wire				     M_AXI_ARESETN,
    // Master Interface Write Address ID
    output wire [C_M_AXI_ID_WIDTH-1 : 0]     M_AXI_AWID,
    // Master Interface Write Address
    output wire [C_M_AXI_ADDR_WIDTH-1 : 0]   M_AXI_AWADDR,
    // Burst length. The burst length gives the exact number of transfers in a burst
    output wire [7 : 0]			     M_AXI_AWLEN,
    // Burst size. This signal indicates the size of each transfer in the burst
    output wire [2 : 0]			     M_AXI_AWSIZE,
    // Burst type. The burst type and the size information, 
    // determine how the address for each transfer within the burst is calculated.
    output wire [1 : 0]			     M_AXI_AWBURST,
    // Lock type. Provides additional information about the
    // atomic characteristics of the transfer.
    output wire				     M_AXI_AWLOCK,
    // Memory type. This signal indicates how transactions
    // are required to progress through a system.
    output wire [3 : 0]			     M_AXI_AWCACHE,
    // Protection type. This signal indicates the privilege
    // and security level of the transaction, and whether
    // the transaction is a data access or an instruction access.
    output wire [2 : 0]			     M_AXI_AWPROT,
    // Quality of Service, QoS identifier sent for each write transaction.
    output wire [3 : 0]			     M_AXI_AWQOS,
    // Optional User-defined signal in the write address channel.
    output wire [C_M_AXI_AWUSER_WIDTH-1 : 0] M_AXI_AWUSER,
    // Write address valid. This signal indicates that
    // the channel is signaling valid write address and control information.
    output wire				     M_AXI_AWVALID,
    // Write address ready. This signal indicates that
    // the slave is ready to accept an address and associated control signals
    input wire				     M_AXI_AWREADY,
    // Master Interface Write Data.
    output wire [C_M_AXI_DATA_WIDTH-1 : 0]   M_AXI_WDATA,
    // Write strobes. This signal indicates which byte
    // lanes hold valid data. There is one write strobe
    // bit for each eight bits of the write data bus.
    output wire [C_M_AXI_DATA_WIDTH/8-1 : 0] M_AXI_WSTRB,
    // Write last. This signal indicates the last transfer in a write burst.
    output wire				     M_AXI_WLAST,
    // Optional User-defined signal in the write data channel.
    output wire [C_M_AXI_WUSER_WIDTH-1 : 0]  M_AXI_WUSER,
    // Write valid. This signal indicates that valid write
    // data and strobes are available
    output wire				     M_AXI_WVALID,
    // Write ready. This signal indicates that the slave
    // can accept the write data.
    input wire				     M_AXI_WREADY,
    // Master Interface Write Response.
    input wire [C_M_AXI_ID_WIDTH-1 : 0]	     M_AXI_BID,
    // Write response. This signal indicates the status of the write transaction.
    input wire [1 : 0]			     M_AXI_BRESP,
    // Optional User-defined signal in the write response channel
    input wire [C_M_AXI_BUSER_WIDTH-1 : 0]   M_AXI_BUSER,
    // Write response valid. This signal indicates that the
    // channel is signaling a valid write response.
    input wire				     M_AXI_BVALID,
    // Response ready. This signal indicates that the master
    // can accept a write response.
    output wire				     M_AXI_BREADY,
    // Master Interface Read Address.
    output wire [C_M_AXI_ID_WIDTH-1 : 0]     M_AXI_ARID,
    // Read address. This signal indicates the initial
    // address of a read burst transaction.
    output wire [C_M_AXI_ADDR_WIDTH-1 : 0]   M_AXI_ARADDR,
    // Burst length. The burst length gives the exact number of transfers in a burst
    output wire [7 : 0]			     M_AXI_ARLEN,
    // Burst size. This signal indicates the size of each transfer in the burst
    output wire [2 : 0]			     M_AXI_ARSIZE,
    // Burst type. The burst type and the size information, 
    // determine how the address for each transfer within the burst is calculated.
    output wire [1 : 0]			     M_AXI_ARBURST,
    // Lock type. Provides additional information about the
    // atomic characteristics of the transfer.
    output wire				     M_AXI_ARLOCK,
    // Memory type. This signal indicates how transactions
    // are required to progress through a system.
    output wire [3 : 0]			     M_AXI_ARCACHE,
    // Protection type. This signal indicates the privilege
    // and security level of the transaction, and whether
    // the transaction is a data access or an instruction access.
    output wire [2 : 0]			     M_AXI_ARPROT,
    // Quality of Service, QoS identifier sent for each read transaction
    output wire [3 : 0]			     M_AXI_ARQOS,
    // Optional User-defined signal in the read address channel.
    output wire [C_M_AXI_ARUSER_WIDTH-1 : 0] M_AXI_ARUSER,
    // Write address valid. This signal indicates that
    // the channel is signaling valid read address and control information
    output wire				     M_AXI_ARVALID,
    // Read address ready. This signal indicates that
    // the slave is ready to accept an address and associated control signals
    input wire				     M_AXI_ARREADY,
    // Read ID tag. This signal is the identification tag
    // for the read data group of signals generated by the slave.
    input wire [C_M_AXI_ID_WIDTH-1 : 0]	     M_AXI_RID,
    // Master Read Data
    input wire [C_M_AXI_DATA_WIDTH-1 : 0]    M_AXI_RDATA,
    // Read response. This signal indicates the status of the read transfer
    input wire [1 : 0]			     M_AXI_RRESP,
    // Read last. This signal indicates the last transfer in a read burst
    input wire				     M_AXI_RLAST,
    // Optional User-defined signal in the read address channel.
    input wire [C_M_AXI_RUSER_WIDTH-1 : 0]   M_AXI_RUSER,
    // Read valid. This signal indicates that the channel
    // is signaling the required read data.
    input wire				     M_AXI_RVALID,
    // Read ready. This signal indicates that the master can
    // accept the read data and response information.
    output wire				     M_AXI_RREADY
    );

   wire w_reset = (M_AXI_ARESETN == 1'b0) | rv_reset;
   reg  r_sgi_mode;
   always@(posedge M_AXI_ACLK)
     begin
	r_sgi_mode <= w_reset ? 1'b0 : sgi_mode;
     end

   // ---- per-lane request engines ----
   wire        w_ar_valid0, w_ar_valid1, w_aw_valid0, w_aw_valid1;
   wire [31:0] w_ar_addr0, w_ar_addr1, w_aw_addr0, w_aw_addr1;
   wire [7:0]  w_ar_len0, w_ar_len1, w_aw_len0, w_aw_len1;
   wire        w_w_valid0, w_w_valid1, w_w_last0, w_w_last1;
   wire [127:0] w_w_data0, w_w_data1;
   wire [15:0]  w_w_strb0, w_w_strb1;
   wire        w_busy0, w_busy1, w_wr0, w_wr1, w_acc0, w_acc_wr0;
   wire [25:0] w_line0, w_line1, w_acc_line0;
   wire        w_rd_pulse0, w_rd_pulse1, w_wr_pulse0, w_wr_pulse1;
   wire [3:0]  w_state0, w_state1;
   wire [511:0] w_rsp_data0;
   wire [31:0] w_last_addr0, w_last_addr1;

   /* channel ownership (one AR and one AW/W in flight at a time across lanes) */
   reg         r_ar_lock, r_ar_own;
   reg         r_aw_lock, r_aw_own;
   reg         r_w_busy, r_w_own;
   wire        w_ar_sel = r_ar_lock ? r_ar_own : (w_ar_valid0 ? 1'b0 : 1'b1);
   wire        w_aw_sel = r_aw_lock ? r_aw_own : (w_aw_valid0 ? 1'b0 : 1'b1);

   assign M_AXI_ARVALID = w_ar_sel ? w_ar_valid1 : w_ar_valid0;
   assign M_AXI_ARADDR  = w_ar_sel ? w_ar_addr1  : w_ar_addr0;
   assign M_AXI_ARLEN   = w_ar_sel ? w_ar_len1   : w_ar_len0;
   assign M_AXI_ARID    = w_ar_sel;
   wire   w_ar_fire     = M_AXI_ARVALID & M_AXI_ARREADY;

   /* AW only while no W burst is in progress (AXI4: W data follows AW order) */
   assign M_AXI_AWVALID = ~r_w_busy & (w_aw_sel ? w_aw_valid1 : w_aw_valid0);
   assign M_AXI_AWADDR  = w_aw_sel ? w_aw_addr1 : w_aw_addr0;
   assign M_AXI_AWLEN   = w_aw_sel ? w_aw_len1  : w_aw_len0;
   assign M_AXI_AWID    = w_aw_sel;
   wire   w_aw_fire     = M_AXI_AWVALID & M_AXI_AWREADY;

   assign M_AXI_WVALID  = r_w_busy & (r_w_own ? w_w_valid1 : w_w_valid0);
   assign M_AXI_WDATA   = r_w_own ? w_w_data1 : w_w_data0;
   assign M_AXI_WSTRB   = r_w_own ? w_w_strb1 : w_w_strb0;
   assign M_AXI_WLAST   = r_w_own ? w_w_last1 : w_w_last0;
   wire   w_w_fire      = M_AXI_WVALID & M_AXI_WREADY;

   assign M_AXI_RREADY  = 1'b1;    /* each lane is waiting in its R state when its data arrives */
   assign M_AXI_BREADY  = 1'b1;

   always@(posedge M_AXI_ACLK)
     begin
	if(w_reset)
	  begin
	     r_ar_lock <= 1'b0;
	     r_ar_own <= 1'b0;
	     r_aw_lock <= 1'b0;
	     r_aw_own <= 1'b0;
	     r_w_busy <= 1'b0;
	     r_w_own <= 1'b0;
	  end
	else
	  begin
	     r_ar_lock <= M_AXI_ARVALID & ~M_AXI_ARREADY;
	     r_ar_own <= w_ar_sel;
	     r_aw_lock <= M_AXI_AWVALID & ~M_AXI_AWREADY;
	     r_aw_own <= w_aw_sel;
	     if(w_aw_fire)
	       begin
		  r_w_busy <= 1'b1;
		  r_w_own <= w_aw_sel;
	       end
	     else if(w_w_fire & M_AXI_WLAST)
	       begin
		  r_w_busy <= 1'b0;
	       end
	  end
     end // always@ (posedge M_AXI_ACLK)

   axi_lane #(.ID(0), .BURST(0)) lane0
     (.clk(M_AXI_ACLK),
      .reset(w_reset),
      .sgi_mode(r_sgi_mode),
      .baseaddr(baseaddr),
      .addrmask(addrmask),
      .req_valid(mem_req_valid),
      .req_addr(cpuaddr),
      .req_opcode(mem_opcode),
      .req_mask(mem_mask),
      .req_store_data({384'd0, mem_req_store_data}),
      .other_busy(w_busy1),
      .other_wr(w_wr1),
      .other_line(w_line1),
      .other_acc(1'b0),
      .other_acc_wr(1'b0),
      .other_acc_line(26'd0),
      .busy(w_busy0),
      .wr(w_wr0),
      .line(w_line0),
      .acc(w_acc0),
      .acc_wr(w_acc_wr0),
      .acc_line(w_acc_line0),
      .rsp_valid(mem_rsp_valid),
      .rsp_bad(mem_rsp_bad),
      .rsp_data(w_rsp_data0),
      .ar_valid(w_ar_valid0),
      .ar_addr(w_ar_addr0),
      .ar_len(w_ar_len0),
      .ar_fire(w_ar_fire & (w_ar_sel == 1'b0)),
      .aw_valid(w_aw_valid0),
      .aw_addr(w_aw_addr0),
      .aw_len(w_aw_len0),
      .aw_fire(w_aw_fire & (w_aw_sel == 1'b0)),
      .w_valid(w_w_valid0),
      .w_data(w_w_data0),
      .w_strb(w_w_strb0),
      .w_last(w_w_last0),
      .w_fire(w_w_fire & (r_w_own == 1'b0)),
      .r_valid(M_AXI_RVALID & (M_AXI_RID == 1'b0)),
      .r_data_in(M_AXI_RDATA),
      .r_last(M_AXI_RLAST),
      .b_valid(M_AXI_BVALID & (M_AXI_BID == 1'b0)),
      .rd_pulse(w_rd_pulse0),
      .wr_pulse(w_wr_pulse0),
      .state(w_state0),
      .last_addr(w_last_addr0));

   axi_lane #(.ID(1), .BURST(1)) lane1
     (.clk(M_AXI_ACLK),
      .reset(w_reset),
      .sgi_mode(r_sgi_mode),
      .baseaddr(baseaddr),
      .addrmask(addrmask),
      .req_valid(mem2_req_valid),
      .req_addr(mem2_req_addr),
      .req_opcode(mem2_opcode),
      .req_mask(mem2_mask),
      .req_store_data(mem2_req_store_data),
      .other_busy(w_busy0),
      .other_wr(w_wr0),
      .other_line(w_line0),
      .other_acc(w_acc0),
      .other_acc_wr(w_acc_wr0),
      .other_acc_line(w_acc_line0),
      .busy(w_busy1),
      .wr(w_wr1),
      .line(w_line1),
      .acc(),
      .acc_wr(),
      .acc_line(),
      .rsp_valid(mem2_rsp_valid),
      .rsp_bad(mem2_rsp_bad),
      .rsp_data(mem2_load_data),
      .ar_valid(w_ar_valid1),
      .ar_addr(w_ar_addr1),
      .ar_len(w_ar_len1),
      .ar_fire(w_ar_fire & (w_ar_sel == 1'b1)),
      .aw_valid(w_aw_valid1),
      .aw_addr(w_aw_addr1),
      .aw_len(w_aw_len1),
      .aw_fire(w_aw_fire & (w_aw_sel == 1'b1)),
      .w_valid(w_w_valid1),
      .w_data(w_w_data1),
      .w_strb(w_w_strb1),
      .w_last(w_w_last1),
      .w_fire(w_w_fire & (r_w_own == 1'b1)),
      .r_valid(M_AXI_RVALID & (M_AXI_RID == 1'b1)),
      .r_data_in(M_AXI_RDATA),
      .r_last(M_AXI_RLAST),
      .b_valid(M_AXI_BVALID & (M_AXI_BID == 1'b1)),
      .rd_pulse(w_rd_pulse1),
      .wr_pulse(w_wr_pulse1),
      .state(w_state1),
      .last_addr(w_last_addr1));

   // ---- fixed AXI attributes ----
   assign M_AXI_AWSIZE  = 3'd4;    /* 16-byte beats */
   assign M_AXI_ARSIZE  = 3'd4;
   assign M_AXI_AWBURST = 2'b01;   /* INCR (a 1-beat INCR is the old single transfer) */
   assign M_AXI_ARBURST = 2'b01;
   assign M_AXI_AWLOCK  = 1'b0;
   assign M_AXI_AWCACHE = 4'b0010;
   assign M_AXI_AWPROT  = 3'h0;
   assign M_AXI_AWQOS   = 4'h0;
   assign M_AXI_AWUSER  = 'b1;
   assign M_AXI_WUSER   = 'b0;
   assign M_AXI_ARLOCK  = 1'b0;
   assign M_AXI_ARCACHE = 4'b0010;
   assign M_AXI_ARPROT  = 3'h0;
   assign M_AXI_ARQOS   = 4'h0;
   assign M_AXI_ARUSER  = 'b1;
   assign TXN_DONE      = 1'b1;

   // ---- lane-0 compatibility outputs + counters ----
   reg [1:0]   r_tag;
   reg	       r_mem_req_gnt;
   reg [63:0]  r_axi_reads, r_axi_writes, r_cnt, r_lat;
   always@(posedge M_AXI_ACLK)
     begin
	if(w_reset)
	  begin
	     r_tag <= 2'd0;
	     r_mem_req_gnt <= 1'b0;
	     r_axi_reads <= 64'd0;
	     r_axi_writes <= 64'd0;
	     r_cnt <= 64'd0;
	     r_lat <= 64'd0;
	  end
	else
	  begin
	     r_mem_req_gnt <= w_acc0;
	     if(w_acc0)
	       begin
		  r_tag <= mem_req_tag;
	       end
	     r_axi_reads <= r_axi_reads + {63'd0, w_rd_pulse0} + {63'd0, w_rd_pulse1};
	     r_axi_writes <= r_axi_writes + {63'd0, w_wr_pulse0} + {63'd0, w_wr_pulse1};
	     r_cnt <= r_cnt + 64'd1;
	     if((w_state0 == 4'd0) & (w_state1 == 4'd0))
	       begin
		  r_lat <= r_lat + 64'd1;
	       end
	  end
     end // always@ (posedge M_AXI_ACLK)

   assign mem_rsp_tag = r_tag;
   assign mem_req_gnt = r_mem_req_gnt;
   assign axi_reads = r_axi_reads;
   assign axi_writes = r_axi_writes;
   assign txn_cnt = r_cnt;
   assign txn_lat = r_lat;
   assign axi_busy = w_busy0 | w_busy1;
   assign state = w_state0;
   assign load_data = w_rsp_data0[127:0];
   assign last_addr = w_last_addr0;
   assign last_data = w_rsp_data0[31:0];
   always@(posedge M_AXI_ACLK)
     begin
	ERROR <= 1'b0;
     end

endmodule // axi_is_the_worst_v1_0_M00_AXI


/* axi_lane -- one request engine of the M00 master (one request outstanding).
 * The requester holds mem_req_valid until rsp_valid, then must drop it for at
 * least a cycle (WAIT) before the next request -- the existing core-bus contract.
 * A request is not accepted while the OTHER lane has an access in flight (or is
 * accepting one this cycle) to the same 64B line and either access is a write,
 * so the two AXI IDs never reorder a write against a same-line access. */
module axi_lane #(parameter ID = 0, parameter BURST = 1)
   (input wire           clk,
    input wire           reset,
    input wire           sgi_mode,
    input wire [31:0]    baseaddr,
    input wire [31:0]    addrmask,
    input wire           req_valid,
    input wire [35:0]    req_addr,
    input wire [4:0]     req_opcode,
    input wire [15:0]    req_mask,
    input wire [511:0]   req_store_data,
    input wire           other_busy,
    input wire           other_wr,
    input wire [25:0]    other_line,
    input wire           other_acc,
    input wire           other_acc_wr,
    input wire [25:0]    other_acc_line,
    output wire          busy,
    output wire          wr,
    output wire [25:0]   line,
    output wire          acc,
    output wire          acc_wr,
    output wire [25:0]   acc_line,
    output wire          rsp_valid,
    output wire          rsp_bad,
    output wire [511:0]  rsp_data,
    output wire          ar_valid,
    output wire [31:0]   ar_addr,
    output wire [7:0]    ar_len,
    input wire           ar_fire,
    output wire          aw_valid,
    output wire [31:0]   aw_addr,
    output wire [7:0]    aw_len,
    input wire           aw_fire,
    output wire          w_valid,
    output wire [127:0]  w_data,
    output wire [15:0]   w_strb,
    output wire          w_last,
    input wire           w_fire,
    input wire           r_valid,
    input wire [127:0]   r_data_in,
    input wire           r_last,
    input wire           b_valid,
    output wire          rd_pulse,
    output wire          wr_pulse,
    output wire [3:0]    state,
    output wire [31:0]   last_addr);

   localparam IDLE = 4'd0;
   localparam AR   = 4'd1;
   localparam RD   = 4'd2;
   localparam AW   = 4'd3;
   localparam WD   = 4'd4;
   localparam WB   = 4'd5;
   localparam BAD  = 4'd6;
   localparam WAIT = 4'd7;

   reg [3:0]   r_state, n_state;
   reg [31:0]  r_addr, n_addr;
   reg [7:0]   r_len, n_len;
   reg [1:0]   r_beat, n_beat;
   reg [15:0]  r_mask, n_mask;
   reg         r_is_wr, n_is_wr;
   reg         r_burst, n_burst;
   reg [511:0] r_sd, n_sd;
   reg [511:0] r_data;
   reg         r_rsp_valid, n_rsp_valid;
   reg         r_rsp_bad, n_rsp_bad;
   reg [4:0]   r_ticks, n_ticks;
   reg         t_acc, t_rd_pulse, t_wr_pulse;

   /* IP22 sgi_mode PA fold, exactly as the single-lane master did it */
   reg [35:0]  t_cpuaddr;
   always@(*)
     begin
	t_cpuaddr = req_addr;
	if(sgi_mode)
	  begin
	     if((req_addr <= 36'h17ffffff) & (req_addr >= 36'h08000000))
	       begin
		  t_cpuaddr = {8'd0, req_addr[27:0]};
	       end
	     else if((req_addr <= 36'h1fffffff) & (req_addr >= 36'h1f000000))
	       begin
		  t_cpuaddr = {12'd16, req_addr[23:0]};
	       end
	  end
     end // always@ (*)

   wire [31:0] w_axi_addr = baseaddr + t_cpuaddr[31:0];
   wire        w_bad_addr = (t_cpuaddr > {4'd0, addrmask});
   /* BURST=0 (the CPU lane) never sees 5/6, so its upper data slots and beat
    * counter synthesize away */
   wire        w_is_burst = (BURST != 0) & ((req_opcode == 5'd5) | (req_opcode == 5'd6));
   wire        w_rd = req_valid & ((req_opcode == 5'd4) | ((BURST != 0) & (req_opcode == 5'd5)));
   wire        w_wr = req_valid & ((req_opcode == 5'd7) | ((BURST != 0) & (req_opcode == 5'd6)));
   wire [25:0] w_req_line = w_axi_addr[31:6];
   wire        w_same_busy = other_busy & (other_line == w_req_line) & (other_wr | w_wr);
   wire        w_same_acc = other_acc & (other_acc_line == w_req_line) & (other_acc_wr | w_wr);
   wire        w_hazard = w_same_busy | w_same_acc;

   assign busy = (r_state != IDLE) & (r_state != WAIT);
   assign wr = r_is_wr;
   assign line = r_addr[31:6];
   assign acc = t_acc;
   assign acc_wr = w_wr;
   assign acc_line = w_req_line;
   assign rsp_valid = r_rsp_valid;
   assign rsp_bad = r_rsp_bad;
   assign rsp_data = r_data;
   assign ar_valid = (r_state == AR);
   assign ar_addr = r_addr;
   assign ar_len = r_len;
   assign aw_valid = (r_state == AW);
   assign aw_addr = r_addr;
   assign aw_len = r_len;
   assign w_valid = (r_state == WD);
   assign w_data = (r_beat == 2'd0) ? r_sd[127:0] :
		   (r_beat == 2'd1) ? r_sd[255:128] :
		   (r_beat == 2'd2) ? r_sd[383:256] :
		   r_sd[511:384];
   assign w_strb = r_burst ? 16'hffff : r_mask;
   assign w_last = (r_beat == r_len[1:0]);
   assign rd_pulse = t_rd_pulse;
   assign wr_pulse = t_wr_pulse;
   assign state = r_state;
   assign last_addr = r_addr;

   always@(*)
     begin
	n_state = r_state;
	n_addr = r_addr;
	n_len = r_len;
	n_beat = r_beat;
	n_mask = r_mask;
	n_is_wr = r_is_wr;
	n_burst = r_burst;
	n_sd = r_sd;
	n_rsp_valid = 1'b0;
	n_rsp_bad = 1'b0;
	n_ticks = r_ticks;
	t_acc = 1'b0;
	t_rd_pulse = 1'b0;
	t_wr_pulse = 1'b0;
	case(r_state)
	  IDLE:
	    begin
	       if((w_rd | w_wr) & ~w_hazard)
		 begin
		    t_acc = 1'b1;
		    n_is_wr = w_wr;
		    n_burst = w_is_burst;
		    n_len = w_is_burst ? 8'd3 : 8'd0;
		    n_beat = 2'd0;
		    n_mask = req_mask;
		    n_sd = req_store_data;
		    n_ticks = 5'd0;
		    if(w_bad_addr)
		      begin
			 n_addr = {w_axi_addr[31:4], w_wr ? 4'd1 : 4'd2};
			 n_state = BAD;
		      end
		    else
		      begin
			 n_addr = w_is_burst ? {w_axi_addr[31:6], 6'd0} : w_axi_addr;
			 n_state = w_wr ? AW : AR;
			 t_rd_pulse = w_rd;
			 t_wr_pulse = w_wr;
		      end
		 end
	    end
	  AR:
	    begin
	       if(ar_fire)
		 begin
		    n_state = RD;
		 end
	    end
	  RD:
	    begin
	       if(r_valid)
		 begin
		    n_beat = r_beat + 2'd1;
		    if(r_last)
		      begin
			 n_rsp_valid = 1'b1;
			 n_state = WAIT;
		      end
		 end
	    end
	  AW:
	    begin
	       if(aw_fire)
		 begin
		    n_state = WD;
		 end
	    end
	  WD:
	    begin
	       if(w_fire)
		 begin
		    n_beat = r_beat + 2'd1;
		    if(w_last)
		      begin
			 n_state = WB;
		      end
		 end
	    end
	  WB:
	    begin
	       if(b_valid)
		 begin
		    n_rsp_valid = 1'b1;
		    n_state = WAIT;
		 end
	    end
	  BAD:
	    begin
	       n_ticks = r_ticks + 5'd1;
	       if(r_ticks == 5'd16)
		 begin
		    n_rsp_valid = 1'b1;
		    n_rsp_bad = 1'b1;
		    n_state = WAIT;
		 end
	    end
	  WAIT:
	    begin
	       n_state = req_valid ? WAIT : IDLE;
	    end
	  default:
	    begin
	       n_state = IDLE;
	    end
	endcase // case (r_state)
     end // always@ (*)

   always@(posedge clk)
     begin
	if(reset)
	  begin
	     r_state <= IDLE;
	     r_addr <= 32'hdeadbee0;
	     r_len <= 8'd0;
	     r_beat <= 2'd0;
	     r_mask <= 16'd0;
	     r_is_wr <= 1'b0;
	     r_burst <= 1'b0;
	     r_rsp_valid <= 1'b0;
	     r_rsp_bad <= 1'b0;
	     r_ticks <= 5'd0;
	  end
	else
	  begin
	     r_state <= n_state;
	     r_addr <= n_addr;
	     r_len <= n_len;
	     r_beat <= n_beat;
	     r_mask <= n_mask;
	     r_is_wr <= n_is_wr;
	     r_burst <= n_burst;
	     r_rsp_valid <= n_rsp_valid;
	     r_rsp_bad <= n_rsp_bad;
	     r_ticks <= n_ticks;
	  end
	r_sd <= n_sd;
	/* read beats land in their 128b slot (a 16B read uses slot 0); out-of-range
	 * reads are POISONED with 0xA5 (> addrmask, so a wild pointer chain keeps
	 * faulting visibly) exactly as the single-lane master did */
	if((r_state == RD) & r_valid & (BURST == 0))
	  begin
	     r_data[127:0] <= r_data_in;
	  end
	else if((r_state == RD) & r_valid)
	  begin
	     case(r_beat)
	       2'd0:
		 begin
		    r_data[127:0] <= r_data_in;
		 end
	       2'd1:
		 begin
		    r_data[255:128] <= r_data_in;
		 end
	       2'd2:
		 begin
		    r_data[383:256] <= r_data_in;
		 end
	       default:
		 begin
		    r_data[511:384] <= r_data_in;
		 end
	     endcase // case (r_beat)
	  end
	else if((r_state == BAD) & ~r_is_wr)
	  begin
	     r_data <= {64{8'hA5}};
	  end
     end // always@ (posedge clk)
endmodule // axi_lane
