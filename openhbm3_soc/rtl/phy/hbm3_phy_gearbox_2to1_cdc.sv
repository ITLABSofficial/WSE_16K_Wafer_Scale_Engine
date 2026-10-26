// ============================================================================
// File: hbm3_phy_gearbox_2to1_cdc.sv
// Project: Open_HBM3_PHY
// Technology: ASAP7 7nm FinFET Predictive PDK
// Description:
//   2:1 Stream Gearbox and Dual-Clock Asynchronous CDC FIFO per HBM3 channel.
//   Packs two 256-bit Core beats @ 2.0 GHz into one 512-bit PHY beat @ 1.15 GHz.
//   Features isolated per-channel reset buffer cells to break the 15,000-FF
//   reset fanout tree without incurring stagger desynchronization.
// ============================================================================

`include "hbm3_phy_defs.svh"

module hbm3_phy_gearbox_2to1_cdc #(
    parameter int CHANNELS       = 16,
    parameter int ADDR_BITS      = 35,
    parameter int HOST_DATA_BITS = 256,
    parameter int PHY_DATA_BITS  = 512,
    parameter int FIFO_ADDR_BITS = 3
)(
    input  logic                                            core_clk,
    input  logic                                            phy_clk,
    input  logic                                            core_rst_n,
    input  logic                                            phy_rst_n,
    input  logic                                            phy_cal_done,

    // Core Domain Interface (256-bit beats @ 2.0 GHz)
    input  logic [CHANNELS-1:0]                             core_valid,
    output logic [CHANNELS-1:0]                             core_ready,
    input  logic [CHANNELS-1:0]                             core_flush,
    input  logic [CHANNELS*ADDR_BITS-1:0]                  core_addr,
    input  logic [CHANNELS*HOST_DATA_BITS-1:0]             core_wdata,

    // PHY Domain Interface (512-bit beats @ 1.15 GHz)
    output logic [CHANNELS-1:0]                             phy_valid,
    input  logic [CHANNELS-1:0]                             phy_ready,
    output logic [CHANNELS*2-1:0]                           phy_mask,
    output logic [CHANNELS*2*ADDR_BITS-1:0]                 phy_addr,
    output logic [CHANNELS*PHY_DATA_BITS-1:0]               phy_wdata
);
    localparam int PACKET_BITS = ADDR_BITS + HOST_DATA_BITS;
    localparam int FIFO_BITS   = 2 + (2 * PACKET_BITS);

    logic [PACKET_BITS-1:0]      half_packet [0:CHANNELS-1];
    logic [CHANNELS-1:0]         half_valid;
    logic [CHANNELS-1:0]         fifo_wr_valid, fifo_wr_ready;
    logic [CHANNELS-1:0]         fifo_rd_valid;
    logic [CHANNELS*FIFO_BITS-1:0] fifo_wr_data, fifo_rd_data;

    // Reset Fanout Buffer Trees
    logic [CHANNELS-1:0] core_rst_fan, phy_rst_fan;
    genvar grb;
    generate
        for (grb = 0; grb < CHANNELS; grb = grb + 1) begin : g_rstbuf
            hbm3_phy_rst_buf u_crb (
                .clk(core_clk), .arst_n(core_rst_n),
                .rst_n_in(core_rst_n), .rst_n_out(core_rst_fan[grb])
            );
            hbm3_phy_rst_buf u_prb (
                .clk(phy_clk),  .arst_n(phy_rst_n),
                .rst_n_in(phy_rst_n),  .rst_n_out(phy_rst_fan[grb])
            );
        end
    endgenerate

    // Per-Channel Gearbox Packer & CDC FIFO
    genvar gch;
    generate
        for (gch = 0; gch < CHANNELS; gch = gch + 1) begin : g_chan
            logic [ADDR_BITS-1:0]      in_addr;
            logic [HOST_DATA_BITS-1:0] in_data;
            logic [PACKET_BITS-1:0]    cur_packet;

            assign in_addr    = core_addr[gch*ADDR_BITS +: ADDR_BITS];
            assign in_data    = core_wdata[gch*HOST_DATA_BITS +: HOST_DATA_BITS];
            assign cur_packet = {in_addr, in_data};

            // Gate core_ready with local reset buffer to prevent dropped beats during reset release
            assign core_ready[gch] = core_rst_fan[gch] && phy_cal_done && (!half_valid[gch] || fifo_wr_ready[gch]);

            always_ff @(posedge core_clk or negedge core_rst_fan[gch]) begin
                if (!core_rst_fan[gch]) begin
                    half_valid[gch]  <= 1'b0;
                    half_packet[gch] <= '0;
                end else if (core_valid[gch] && core_ready[gch]) begin
                    if (!half_valid[gch]) begin
                        half_valid[gch]  <= 1'b1;
                        half_packet[gch] <= cur_packet;
                    end else begin
                        half_valid[gch]  <= 1'b0;
                    end
                end else if (core_flush[gch] && half_valid[gch] && fifo_wr_ready[gch]) begin
                    half_valid[gch]  <= 1'b0;
                end
            end

            // 2:1 Packing Logic
            always_comb begin
                fifo_wr_valid[gch] = 1'b0;
                fifo_wr_data[gch*FIFO_BITS +: FIFO_BITS] = '0;

                if (half_valid[gch] && core_valid[gch] && core_ready[gch]) begin
                    // Pair of beats available
                    fifo_wr_valid[gch] = 1'b1;
                    fifo_wr_data[gch*FIFO_BITS +: FIFO_BITS] = {2'b11, cur_packet, half_packet[gch]};
                end else if (core_flush[gch] && half_valid[gch]) begin
                    // Flushed single beat
                    fifo_wr_valid[gch] = 1'b1;
                    fifo_wr_data[gch*FIFO_BITS +: FIFO_BITS] = {2'b01, {PACKET_BITS{1'b0}}, half_packet[gch]};
                end
            end

            // Asynchronous CDC FIFO
            hbm3_phy_async_fifo #(
                .DATA_BITS (FIFO_BITS),
                .ADDR_BITS (FIFO_ADDR_BITS)
            ) u_fifo (
                .wr_clk   (core_clk),
                .wr_rst_n (core_rst_fan[gch]),
                .wr_valid (fifo_wr_valid[gch]),
                .wr_ready (fifo_wr_ready[gch]),
                .wr_data  (fifo_wr_data[gch*FIFO_BITS +: FIFO_BITS]),

                .rd_clk   (phy_clk),
                .rd_rst_n (phy_rst_fan[gch]),
                .rd_valid (fifo_rd_valid[gch]),
                .rd_ready (phy_ready[gch]),
                .rd_data  (fifo_rd_data[gch*FIFO_BITS +: FIFO_BITS])
            );

            // PHY Domain Unpack
            logic [1:0]             rd_mask;
            logic [PACKET_BITS-1:0] p1, p0;

            assign {rd_mask, p1, p0} = fifo_rd_data[gch*FIFO_BITS +: FIFO_BITS];

            assign phy_valid[gch] = fifo_rd_valid[gch];
            assign phy_mask[gch*2 +: 2] = rd_mask;
            assign phy_addr[gch*2*ADDR_BITS +: 2*ADDR_BITS] = {p1[HOST_DATA_BITS +: ADDR_BITS], p0[HOST_DATA_BITS +: ADDR_BITS]};
            assign phy_wdata[gch*PHY_DATA_BITS +: PHY_DATA_BITS] = {p1[0 +: HOST_DATA_BITS], p0[0 +: HOST_DATA_BITS]};
        end
    endgenerate

endmodule
