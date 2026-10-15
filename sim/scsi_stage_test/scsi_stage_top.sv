`include "machine.vh"
// unit-test top: scsi_dma + scsi_stage wired as henry_soc does under SCSI_RINGS
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

   logic                  e_req_valid, e_rsp_valid;
   logic [`PA_WIDTH-1:0]  e_req_addr;
   logic [4:0]            e_req_opcode;
   logic [127:0]          e_req_store_data, e_rsp_load_data;
   logic [15:0]           e_req_mask;
   logic                  rd_en, rd_valid, wr_en, wr_full, rd_stalled;
   logic [127:0]          rd_data, wr_data;
   logic [31:0]           xfer;

   scsi_dma u_dma
     (.clk(clk), .reset(reset), .go(go), .nbdp(nbdp), .to_device(to_device),
      .busy(busy), .done(done), .irq(), .rd_stalled(rd_stalled),
      .dma_req_valid(e_req_valid), .dma_req_addr(e_req_addr), .dma_req_opcode(e_req_opcode),
      .dma_req_store_data(e_req_store_data), .dma_req_mask(e_req_mask),
      .dma_rsp_valid(e_rsp_valid), .dma_rsp_load_data(e_rsp_load_data),
      .disk_rd_en(rd_en), .disk_rd_data(rd_data), .disk_rd_valid(rd_valid), .cancel(cancel),
      .disk_wr_en(wr_en), .disk_wr_data(wr_data), .disk_wr_full(wr_full), .xfer_bytes(xfer));

   scsi_stage u_stage
     (.clk(clk), .reset(reset), .rd_beats(rd_beats), .rd_seq(rd_seq), .cq_cons(cq_cons), .req_seq(req_seq),
      .eng_go(go), .eng_nbdp(nbdp), .eng_to_dev(to_device), .eng_done(done),
      .eng_rd_stalled(rd_stalled), .eng_cancel(cancel), .eng_xfer_bytes(xfer),
      .disk_rd_en(rd_en), .disk_rd_data(rd_data), .disk_rd_valid(rd_valid),
      .disk_wr_en(wr_en), .disk_wr_data(wr_data), .disk_wr_full(wr_full),
      .e_req_valid(e_req_valid), .e_req_addr(e_req_addr), .e_req_opcode(e_req_opcode),
      .e_req_store_data(e_req_store_data), .e_req_mask(e_req_mask),
      .e_rsp_valid(e_rsp_valid), .e_rsp_load_data(e_rsp_load_data),
      .dn_req_valid(dn_req_valid), .dn_req_addr(dn_req_addr), .dn_req_opcode(dn_req_opcode),
      .dn_req_store_data(dn_req_store_data), .dn_req_mask(dn_req_mask),
      .dn_rsp_valid(dn_rsp_valid), .dn_rsp_load_data(dn_rsp_load_data));
endmodule // scsi_stage_top
