// ============================================================================
// File: wck_div.sv
// Project: Open_HBM3_Controller
// Description:
//   WCK clock divider: 1:2 frequency relationship relative to CK.
// ============================================================================
`timescale 1ns/1ps

module wck_div (
    input  logic clk,
    input  logic rst_n,
    output logic wck,
    output logic wck_ce      // Clock enable strobe for data beat alignment
);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) wck <= 0;
        else wck <= ~wck;
    end
    assign wck_ce = 1'b1; // Behavioral model: one beat per CK cycle
endmodule
