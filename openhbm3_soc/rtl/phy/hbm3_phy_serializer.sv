// ============================================================================
// File: hbm3_phy_serializer.sv
// Project: Open_HBM3_Controller
// Description:
//   Single-lane N:1 serializer with DDR output (dq_rise, dq_fall).
//   Takes an 8-bit parallel word at beat boundary and shifts out 2 bits per WCK
//   cycle (one for rising edge, one for falling edge).
// ============================================================================

module hbm3_phy_serializer #(
    parameter int SER_RATIO = 8            // must be even (DDR)
)(
    input  logic                 wck,
    input  logic                 rst_n,
    input  logic                 load,     // parallel data capture pulse
    input  logic [SER_RATIO-1:0] pdata,    // parallel payload
    output logic                 dq_rise,  // driven on WCK rising edge
    output logic                 dq_fall   // driven on WCK falling edge
);
    initial
        if (SER_RATIO % 2 != 0)
            $fatal(1, "hbm3_phy_serializer: SER_RATIO must be even (%0d)", SER_RATIO);

    // Shift register: consumes 2 bits per WCK cycle (DDR)
    logic [SER_RATIO-1:0] shift;

    always_ff @(posedge wck or negedge rst_n) begin
        if (!rst_n)
            shift <= '0;
        else if (load)
            shift <= pdata;
        else
            shift <= {2'b00, shift[SER_RATIO-1:2]};
    end

    // Direct registered outputs without additional combinational depth
    assign dq_rise = shift[0];
    assign dq_fall = shift[1];
endmodule
