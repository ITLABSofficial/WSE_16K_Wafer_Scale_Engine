// ============================================================================
// File: hbm3_phy_rst_buf.sv
// Project: Open_HBM3_PHY
// Technology: ASAP7 7nm FinFET Predictive PDK
// Description:
//   Reset distribution buffer preventing Yosys opt_merge optimization from
//   collapsing high-fanout reset replication into a single driver.
//   Marked with (* keep_hierarchy *) to guarantee separate cell preservation.
// ============================================================================

(* keep_hierarchy *)
module hbm3_phy_rst_buf (
    input  logic clk,
    input  logic arst_n,      // Asynchronous primary reset source
    input  logic rst_n_in,    // Synchronized release input
    output logic rst_n_out    // Replicated buffer output
);
    always_ff @(posedge clk or negedge arst_n) begin
        if (!arst_n) begin
            rst_n_out <= 1'b0;
        end else begin
            rst_n_out <= rst_n_in;
        end
    end
endmodule
