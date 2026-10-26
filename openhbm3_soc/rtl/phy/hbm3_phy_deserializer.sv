// ============================================================================
// File: hbm3_phy_deserializer.sv
// Project: Open_HBM3_Controller
// Description:
//   Single-lane N:1 deserializer with DDR input and bit-slip alignment.
//   Dual-mechanism alignment architecture:
//     align   -- establishes beat boundary (cycle interval)
//     bitslip -- shifts sampling window by one bit
//   Window architecture: WIN = 4*SER_RATIO, selection range 0..3*SER_RATIO.
// ============================================================================

module hbm3_phy_deserializer #(
    parameter int SER_RATIO = 8
)(
    input  logic                 wck,
    input  logic                 rst_n,
    input  logic                 dq_rise,
    input  logic                 dq_fall,
    input  logic                 align,     // establish beat boundary pulse
    input  logic                 bitslip,   // shift window by 1 bit
    output logic [SER_RATIO-1:0] pdata,
    output logic                 pvalid
);
    localparam int HALF     = SER_RATIO / 2;
    localparam int WIN      = 4 * SER_RATIO;
    localparam int CNT_BITS = (HALF > 1) ? $clog2(HALF) : 1;
    localparam int SEL_MAX  = WIN - SER_RATIO;   // = 3*SER_RATIO
    localparam int SEL_BITS = $clog2(SEL_MAX + 1);

    logic [WIN-1:0]      window;
    logic [CNT_BITS-1:0] cnt;
    logic [SEL_BITS-1:0] sel;
    logic [WIN-1:0]      window_nxt;

    // Window incorporating the 2 bits arriving in the current WCK cycle
    assign window_nxt = {dq_fall, dq_rise, window[WIN-1:2]};

    always_ff @(posedge wck or negedge rst_n) begin
        if (!rst_n) begin
            window <= '0;
            cnt    <= '0;
            sel    <= SEL_BITS'(SEL_MAX);
            pdata  <= '0;
            pvalid <= 1'b0;
        end else begin
            window <= window_nxt;

            if (bitslip)
                sel <= (sel == '0) ? SEL_BITS'(SEL_MAX) : (sel - 1'b1);

            if (align) begin
                cnt    <= '0;
                pvalid <= 1'b0;
            end else if (cnt == CNT_BITS'(HALF - 1)) begin
                cnt    <= '0;
                pvalid <= 1'b1;
                pdata  <= window_nxt[sel +: SER_RATIO];
            end else begin
                cnt    <= cnt + 1'b1;
                pvalid <= 1'b0;
            end
        end
    end
endmodule
