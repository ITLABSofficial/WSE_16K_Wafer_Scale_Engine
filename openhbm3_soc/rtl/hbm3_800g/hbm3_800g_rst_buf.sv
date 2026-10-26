// ============================================================================
// File: hbm3_800g_rst_buf.sv
// Project: Open_HBM3_Controller
// Description:
//   Reset distribution buffer to mitigate high fanout without multi-cycle skew.
//   Marked with (* keep_hierarchy *) to prevent Yosys opt_merge from merging
//   replicated reset distribution buffers, ensuring synchronous deassertion
//   on the exact same clock cycle across all consumers.
// ============================================================================
(* keep_hierarchy *)
module hbm3_800g_rst_buf (
    input  logic clk,
    input  logic arst_n,      // Asynchronous reset source
    input  logic rst_n_in,    // Synchronized release signal
    output logic rst_n_out
);
    always_ff @(posedge clk or negedge arst_n)
        if (!arst_n) rst_n_out <= 1'b0;
        else         rst_n_out <= rst_n_in;
endmodule
