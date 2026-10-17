`include "machine.vh"
// enet_ring_dma built on dma_engine (the unified DMA engine's ENET channels, SCSI idle):
// the same ports as rtl/enet_ring_dma.sv, so tb_enet_ring_dma.cpp tests either one.
module enet_ring_dma
   (input  logic         clk,
    input  logic         reset,
    input  logic [31:0]  tx_cons,
    input  logic [31:0]  rx_prod,
    input  logic         tx_go,
    input  logic [31:0]  tx_nbdp,
    output logic         tx_done,
    output logic [31:0]  tx_crbdp,
    input  logic         rx_armed,
    input  logic [31:0]  rx_nbdp,
    output logic         rx_done,
    output logic         rx_dropped,
    output logic [31:0]  rx_crbdp,
    output logic [31:0]  rx_next_nbdp,
    output logic                  dma_req_valid,
    output logic [`PA_WIDTH-1:0]  dma_req_addr,
    output logic [4:0]            dma_req_opcode,
    output logic [127:0]          dma_req_store_data,
    output logic [15:0]           dma_req_mask,
    input  logic                  dma_rsp_valid,
    input  logic [127:0]          dma_rsp_load_data);

   dma_engine u_dma
     (.clk(clk), .reset(reset),
      .go(1'b0), .nbdp(32'd0), .to_device(1'b0), .cancel(1'b0),
      .busy(), .done(), .irq(), .rd_stalled(),
      .rd_beats(32'd0), .rd_seq(32'd0), .req_seq(32'd0), .cq_cons(32'd0),
      .tx_cons(tx_cons), .rx_prod(rx_prod), .tx_go(tx_go), .tx_nbdp(tx_nbdp),
      .tx_done(tx_done), .tx_crbdp(tx_crbdp),
      .rx_armed(rx_armed), .rx_nbdp(rx_nbdp), .rx_done(rx_done), .rx_dropped(rx_dropped),
      .rx_crbdp(rx_crbdp), .rx_next_nbdp(rx_next_nbdp),
      .dn_req_valid(dma_req_valid), .dn_req_addr(dma_req_addr), .dn_req_opcode(dma_req_opcode),
      .dn_req_store_data(dma_req_store_data), .dn_req_mask(dma_req_mask),
      .dn_rsp_valid(dma_rsp_valid), .dn_rsp_load_data(dma_rsp_load_data), .owner());
endmodule // enet_ring_dma
