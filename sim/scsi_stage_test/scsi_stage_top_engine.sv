`include "machine.vh"
// scsi_stage_top built on dma_engine (the unified DMA engine's SCSI channel): the same
// ports as scsi_stage_top.sv, so tb_scsi_stage.cpp tests either implementation.
module scsi_stage_top
  (input  logic         clk,
   input  logic         reset,
   input  logic         go,
   input  logic [31:0]  nbdp,
   input  logic         to_device,
   input  logic         cancel,
   input  logic [31:0]  rd_beats,
   input  logic [31:0]  rd_seq,
   input  logic [31:0]  req_seq,
   input  logic [31:0]  cq_cons,
   output logic         busy,
   output logic         done,
   output logic                  dn_req_valid,
   output logic [`PA_WIDTH-1:0]  dn_req_addr,
   output logic [4:0]            dn_req_opcode,
   output logic [127:0]          dn_req_store_data,
   output logic [15:0]           dn_req_mask,
   input  logic                  dn_rsp_valid,
   input  logic [127:0]          dn_rsp_load_data);

   dma_engine u_dma
     (.clk(clk), .reset(reset), .go(go), .nbdp(nbdp), .to_device(to_device), .cancel(cancel),
      .busy(busy), .done(done), .irq(), .rd_stalled(),
      .rd_beats(rd_beats), .rd_seq(rd_seq), .req_seq(req_seq), .cq_cons(cq_cons),
      .tx_cons(32'd0), .rx_prod(32'd0), .tx_go(1'b0), .tx_nbdp(32'd0), .tx_done(), .tx_crbdp(),
      .rx_armed(1'b0), .rx_nbdp(32'd0), .rx_done(), .rx_dropped(), .rx_crbdp(), .rx_next_nbdp(),
      .dn_req_valid(dn_req_valid), .dn_req_addr(dn_req_addr), .dn_req_opcode(dn_req_opcode),
      .dn_req_store_data(dn_req_store_data), .dn_req_mask(dn_req_mask),
      .dn_rsp_valid(dn_rsp_valid), .dn_rsp_load_data(dn_rsp_load_data), .owner());
endmodule // scsi_stage_top
