// ============================================================================
// File: hbm3_phy_tx_channel.sv
// Project: Open_HBM3_Controller
// Description:
//   Physical channel PHY transmitter (TX) front-end: 512 bits -> 64 DQ lanes.
//   Synthesizable digital standard-cell logic.
//   Clock relation: wck is mesochronous with phy_clk (wck = 4 * phy_clk).
//   A local counter generates the beat boundary load pulse.
// ============================================================================
`include "hbm3_800g_defs.svh"

module hbm3_phy_tx_channel #(
    parameter int DQ_LANES  = HBM3_DQ_BITS_PER_CHANNEL,   // 64
    parameter int SER_RATIO = HBM3_PHY_DATA_BITS_PER_CHANNEL / HBM3_DQ_BITS_PER_CHANNEL  // 8
)(
    input  logic wck,
    input  logic rst_n,

    // parallel interface -- par_ready is asserted only on beat boundary
    input  logic                           par_valid,
    output logic                           par_ready,
    input  logic [DQ_LANES*SER_RATIO-1:0]  par_data,

    // serial interface -- DDR: rise driven on WCK posedge, fall on WCK negedge
    output logic [DQ_LANES-1:0]            dq_rise,
    output logic [DQ_LANES-1:0]            dq_fall,
    output logic                           dq_active,   // active data payload
    output logic                           beat_start   // training / alignment strobe
);
    localparam int HALF     = SER_RATIO / 2;
    localparam int CNT_BITS = (HALF > 1) ? $clog2(HALF) : 1;

    initial begin
        if (SER_RATIO % 2 != 0)
            $fatal(1, "hbm3_phy_tx_channel: SER_RATIO must be even (%0d)", SER_RATIO);
        if (DQ_LANES * SER_RATIO != HBM3_PHY_DATA_BITS_PER_CHANNEL)
            $fatal(1, "hbm3_phy_tx_channel: %0d lanes x %0d = %0d, expected %0d",
                   DQ_LANES, SER_RATIO, DQ_LANES*SER_RATIO,
                   HBM3_PHY_DATA_BITS_PER_CHANNEL);
    end

    logic [CNT_BITS-1:0] cnt;
    logic                load;

    always_ff @(posedge wck or negedge rst_n)
        if (!rst_n) cnt <= '0;
        else        cnt <= (cnt == CNT_BITS'(HALF - 1)) ? '0 : cnt + 1'b1;

    // load signal drives 64 lanes x SER_RATIO = 512 flip-flops.
    // Registered one cycle early to distribute cleanly without combinational fanout delay.
    always_ff @(posedge wck or negedge rst_n)
        if (!rst_n) load <= 1'b1;      // First cycle post-reset is beat boundary
        else        load <= (cnt == CNT_BITS'(HALF - 1));

    assign par_ready  = load;          // Accept only at beat boundary
    assign beat_start = load;

    // Idle beat: drive zeros and keep dq_active low when no valid payload is present
    logic [DQ_LANES*SER_RATIO-1:0] beat_data;
    always_comb beat_data = (par_valid) ? par_data : '0;

    always_ff @(posedge wck or negedge rst_n)
        if (!rst_n)     dq_active <= 1'b0;
        else if (load)  dq_active <= par_valid;

    genvar l;
    generate
        for (l = 0; l < DQ_LANES; l = l + 1) begin : g_lane
            hbm3_phy_serializer #(.SER_RATIO(SER_RATIO)) u_ser (
                .wck, .rst_n, .load,
                .pdata   (beat_data[l*SER_RATIO +: SER_RATIO]),
                .dq_rise (dq_rise[l]),
                .dq_fall (dq_fall[l])
            );
        end
    endgenerate
endmodule
