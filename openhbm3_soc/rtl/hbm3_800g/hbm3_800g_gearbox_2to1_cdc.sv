// Synthesizable 2:1 stream gearbox plus asynchronous CDC per physical channel.
// Two 256-bit core beats become one 512-bit PHY-side beat. This is a digital
// streaming contract, not a vendor DFI protocol or an analog HBM PHY.
`include "hbm3_800g_defs.svh"

module hbm3_800g_gearbox_2to1_cdc #(
    parameter int FIFO_ADDR_BITS = 3
) (
    input  logic core_clk,
    input  logic phy_clk,
    input  logic core_rst_n,
    input  logic phy_rst_n,
    input  logic phy_cal_done,
    input  logic [HBM3_CHANNELS-1:0] core_valid,
    output logic [HBM3_CHANNELS-1:0] core_ready,
    input  logic [HBM3_CHANNELS-1:0] core_flush,
    input  logic [HBM3_CHANNELS*HBM3_ADDR_BITS-1:0] core_addr,
    input  logic [HBM3_CHANNELS*HBM3_HOST_DATA_BITS-1:0] core_wdata,
    output logic [HBM3_CHANNELS-1:0] phy_valid,
    input  logic [HBM3_CHANNELS-1:0] phy_ready,
    output logic [HBM3_CHANNELS*HBM3_GEAR_RATIO-1:0] phy_mask,
    output logic [HBM3_CHANNELS*HBM3_GEAR_RATIO*HBM3_ADDR_BITS-1:0] phy_addr,
    output logic [HBM3_CHANNELS*HBM3_PHY_DATA_BITS_PER_CHANNEL-1:0] phy_wdata
);
    localparam int PACKET_BITS = HBM3_ADDR_BITS + HBM3_HOST_DATA_BITS;
    localparam int FIFO_BITS = HBM3_GEAR_RATIO + HBM3_GEAR_RATIO*PACKET_BITS;
    // verilator lint_off MULTIDRIVEN
    // Per-channel array partition: each generate instance drives only its own index.
    // Replicated reset buffers core_rst_fan[gch] reduce fanout on high-speed clocks.
    logic [PACKET_BITS-1:0] half_packet [0:HBM3_CHANNELS-1];
    logic [HBM3_CHANNELS-1:0] half_valid;
    // verilator lint_on MULTIDRIVEN
    logic [HBM3_CHANNELS-1:0] fifo_wr_valid, fifo_wr_ready;
    logic [HBM3_CHANNELS-1:0] fifo_rd_valid;
    logic [HBM3_CHANNELS*FIFO_BITS-1:0] fifo_wr_data, fifo_rd_data;
    integer ch;
    // ---- Reset Fanout Buffering ----
    // Distribute replicated reset signals per FIFO to eliminate high-fanout delay.
    // (* keep_hierarchy *) ensures all copies deassert synchronously on cycle 2.
    logic [HBM3_CHANNELS-1:0] core_rst_fan, phy_rst_fan;
    genvar grb;
    generate for (grb = 0; grb < HBM3_CHANNELS; grb = grb + 1) begin : g_rstbuf
        hbm3_800g_rst_buf u_crb (.clk(core_clk), .arst_n(core_rst_n),
                                 .rst_n_in(core_rst_n), .rst_n_out(core_rst_fan[grb]));
        hbm3_800g_rst_buf u_prb (.clk(phy_clk),  .arst_n(phy_rst_n),
                                 .rst_n_in(phy_rst_n),  .rst_n_out(phy_rst_fan[grb]));
    end endgenerate

    genvar gch;

    // Per-channel generate block: each channel uses dedicated reset buffer replica
    // to partition fanout and maintain timing closure across high-frequency domains.
    generate for (gch = 0; gch < HBM3_CHANNELS; gch = gch + 1) begin : g_half
        always_ff @(posedge core_clk or negedge core_rst_fan[gch]) begin
            if (!core_rst_fan[gch]) begin
                half_valid[gch]  <= 1'b0;
                half_packet[gch] <= '0;
            end else begin
                if (!half_valid[gch]) begin
                    if (core_valid[gch] && core_ready[gch]) begin
                        half_packet[gch] <= {
                            core_addr[gch*HBM3_ADDR_BITS +: HBM3_ADDR_BITS],
                            core_wdata[gch*HBM3_HOST_DATA_BITS +: HBM3_HOST_DATA_BITS]
                        };
                        half_valid[gch] <= 1'b1;
                    end
                end else if (fifo_wr_valid[gch] && fifo_wr_ready[gch]) begin
                    // Full pair or masked single-beat flush atomically committed to FIFO.
                    half_valid[gch] <= 1'b0;
                end
            end
        end
    end endgenerate

    generate for (gch = 0; gch < HBM3_CHANNELS; gch = gch + 1) begin : g_cdc
        // Keep ready structurally independent of valid. Besides enforcing the
        // streaming rule, this avoids a false procedural valid/ready loop in
        // event-driven simulators when the scheduler is connected upstream.
        // Gated with core_rst_fan to prevent spurious ready assertion during reset sequence.
        assign core_ready[gch] = core_rst_fan[gch] &&
                                 (!half_valid[gch] || fifo_wr_ready[gch]);
        assign fifo_wr_valid[gch] = half_valid[gch] &&
                                    (core_valid[gch] || core_flush[gch]);
        assign fifo_wr_data[gch*FIFO_BITS +: FIFO_BITS] = {
            core_valid[gch], 1'b1,
            core_addr[gch*HBM3_ADDR_BITS +: HBM3_ADDR_BITS],
            core_wdata[gch*HBM3_HOST_DATA_BITS +: HBM3_HOST_DATA_BITS],
            half_packet[gch]
        };
        wire [PACKET_BITS-1:0] beat0 =
            fifo_rd_data[gch*FIFO_BITS +: PACKET_BITS];
        wire [PACKET_BITS-1:0] beat1 =
            fifo_rd_data[gch*FIFO_BITS + PACKET_BITS +: PACKET_BITS];
        assign phy_mask[gch*HBM3_GEAR_RATIO +: HBM3_GEAR_RATIO] =
            fifo_rd_data[gch*FIFO_BITS + 2*PACKET_BITS +: HBM3_GEAR_RATIO];
        assign phy_addr[(gch*HBM3_GEAR_RATIO+0)*HBM3_ADDR_BITS +: HBM3_ADDR_BITS] =
            beat0[PACKET_BITS-1 -: HBM3_ADDR_BITS];
        assign phy_addr[(gch*HBM3_GEAR_RATIO+1)*HBM3_ADDR_BITS +: HBM3_ADDR_BITS] =
            beat1[PACKET_BITS-1 -: HBM3_ADDR_BITS];
        assign phy_wdata[gch*HBM3_PHY_DATA_BITS_PER_CHANNEL +: HBM3_HOST_DATA_BITS] =
            beat0[HBM3_HOST_DATA_BITS-1:0];
        assign phy_wdata[gch*HBM3_PHY_DATA_BITS_PER_CHANNEL + HBM3_HOST_DATA_BITS +: HBM3_HOST_DATA_BITS] =
            beat1[HBM3_HOST_DATA_BITS-1:0];
        assign phy_valid[gch] = fifo_rd_valid[gch] && phy_cal_done;

        hbm3_800g_async_fifo #(.DATA_BITS(FIFO_BITS), .ADDR_BITS(FIFO_ADDR_BITS)) fifo (
            .wr_clk(core_clk), .wr_rst_n(core_rst_fan[gch]),
            .wr_valid(fifo_wr_valid[gch]), .wr_ready(fifo_wr_ready[gch]),
            .wr_data(fifo_wr_data[gch*FIFO_BITS +: FIFO_BITS]),
            .rd_clk(phy_clk), .rd_rst_n(phy_rst_fan[gch]),
            .rd_valid(fifo_rd_valid[gch]),
            .rd_ready(phy_ready[gch] && phy_cal_done),
            .rd_data(fifo_rd_data[gch*FIFO_BITS +: FIFO_BITS])
        );
    end endgenerate
endmodule
