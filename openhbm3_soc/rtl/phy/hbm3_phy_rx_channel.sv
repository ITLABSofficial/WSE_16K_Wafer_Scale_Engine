// ============================================================================
// File: hbm3_phy_rx_channel.sv
// Project: Open_HBM3_Controller
// Description:
//   Physical channel PHY receiver (RX) front-end: 64 DQ lanes -> 512 bits.
//   Instantiates per-lane deserializers. bitslip is per-lane for deskew,
//   align is global across all lanes for unified beat boundaries.
// ============================================================================
`include "hbm3_800g_defs.svh"

module hbm3_phy_rx_channel #(
    parameter int DQ_LANES  = HBM3_DQ_BITS_PER_CHANNEL,
    parameter int SER_RATIO = HBM3_PHY_DATA_BITS_PER_CHANNEL / HBM3_DQ_BITS_PER_CHANNEL
)(
    input  logic wck,
    input  logic rst_n,
    input  logic [DQ_LANES-1:0] dq_rise,
    input  logic [DQ_LANES-1:0] dq_fall,
    input  logic                align,        // establish beat boundary (global)
    input  logic [DQ_LANES-1:0] bitslip,      // per-lane bitslip shift
    output logic [DQ_LANES*SER_RATIO-1:0] par_data,
    output logic                par_valid     // lane 0 representative valid pulse
);
    logic [DQ_LANES-1:0] lane_valid;

    genvar l;
    generate
        for (l = 0; l < DQ_LANES; l = l + 1) begin : g_lane
            hbm3_phy_deserializer #(.SER_RATIO(SER_RATIO)) u_des (
                .wck, .rst_n,
                .dq_rise (dq_rise[l]),
                .dq_fall (dq_fall[l]),
                .align,
                .bitslip (bitslip[l]),
                .pdata   (par_data[l*SER_RATIO +: SER_RATIO]),
                .pvalid  (lane_valid[l])
            );
        end
    endgenerate

    // All lanes share the same align pulse and counter phase; lane 0 represents valid
    assign par_valid = lane_valid[0];
endmodule
