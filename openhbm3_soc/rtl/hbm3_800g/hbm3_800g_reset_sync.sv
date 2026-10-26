// ============================================================================
// File: hbm3_800g_reset_sync.sv
// Project: Open_HBM3_Controller
// Description:
//   Asynchronous assertion, synchronous deassertion reset conditioner.
//   Each clock domain must use its own instance.
//   Guarantees that all fanout replicas release synchronously on cycle 2.
// ============================================================================
module hbm3_800g_reset_sync #(
    parameter int FANOUT = 1
)(
    input  logic clk,
    input  logic async_rst_n,
    output logic sync_rst_n,                   // Primary release signal
    output logic [FANOUT-1:0] sync_rst_n_fan   // Registered fanout replicas
);
    (* ASYNC_REG = "TRUE" *) logic [1:0] release_pipe;

    always_ff @(posedge clk or negedge async_rst_n) begin
        if (!async_rst_n)
            release_pipe <= 2'b00;
        else
            release_pipe <= {release_pipe[0], 1'b1};
    end

    assign sync_rst_n = release_pipe[1];

    // fan_q captures release_pipe[0] on the same clock edge that release_pipe[1]
    // is updated, ensuring that sync_rst_n and all sync_rst_n_fan replicas
    // deassert synchronously on the EXACT SAME clock cycle (cycle 2).
    logic [FANOUT-1:0] fan_q;
    always_ff @(posedge clk or negedge async_rst_n) begin
        if (!async_rst_n) fan_q <= '0;
        else              fan_q <= {FANOUT{release_pipe[0]}};
    end

    assign sync_rst_n_fan = fan_q;
endmodule
