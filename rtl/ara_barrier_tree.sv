// ============================================================================
// File: ara_barrier_tree.sv
// Project: Ara_MultiCore_WSE_HBM3 (Global Hardware Barrier Tree)
// Technology: ASAP7 7nm FinFET Predictive PDK (Target: 2.0 GHz / 500 ps cycle)
// Specification: Architectural Invariants & Verification Standards
// Architectural Invariants & Verification Standards
//
// Description:
//   Zero-latency hardware synchronization tree barrier for multi-core Ara
//   clusters and dual HBM3 PIM stacks. Eliminates software spinlocks.
//   Registers core arrival pulses and broadcasts single-cycle barrier release.
// ============================================================================

`timescale 1ps/1ps

module ara_barrier_tree #(
    parameter int unsigned NUM_CORES  = 4,
    parameter int unsigned NUM_STACKS = 4
)(
    input  logic                    clk,
    input  logic                    rst_n,

    // Arrival Request Pulses
    input  logic [NUM_CORES-1:0]    core_barrier_req_i,
    input  logic [NUM_STACKS-1:0]   stack_barrier_req_i,
    input  logic                    host_barrier_req_i,

    // Mask for Active Participants (1: participant enabled, 0: bypassed)
    input  logic [NUM_CORES-1:0]    core_mask_i,
    input  logic [NUM_STACKS-1:0]   stack_mask_i,
    input  logic                    host_mask_i,

    // Synchronization Release Broadcast
    output logic                    barrier_release_o,
    output logic                    barrier_busy_o
);

    logic [NUM_CORES-1:0]  core_arrived_q;
    logic [NUM_STACKS-1:0] stack_arrived_q;
    logic                  host_arrived_q;

    wire [NUM_CORES-1:0]  core_target  = core_mask_i;
    wire [NUM_STACKS-1:0] stack_target = stack_mask_i;
    wire                  host_target  = host_mask_i;

    wire all_cores_done  = &( (~core_target)  | (core_arrived_q  | core_barrier_req_i) );
    wire all_stacks_done = &( (~stack_target) | (stack_arrived_q | stack_barrier_req_i) );
    wire host_done       = ( (~host_target)   | (host_arrived_q  | host_barrier_req_i) );

    wire barrier_fired   = all_cores_done && all_stacks_done && host_done &&
                           (|core_target || |stack_target || host_target);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            core_arrived_q    <= '0;
            stack_arrived_q   <= '0;
            host_arrived_q    <= 1'b0;
            barrier_release_o <= 1'b0;
        end else begin
            if (barrier_fired) begin
                core_arrived_q    <= '0;
                stack_arrived_q   <= '0;
                host_arrived_q    <= 1'b0;
                barrier_release_o <= 1'b1;
            end else begin
                core_arrived_q    <= core_arrived_q  | (core_barrier_req_i  & core_target);
                stack_arrived_q   <= stack_arrived_q | (stack_barrier_req_i & stack_target);
                host_arrived_q    <= host_arrived_q  | (host_barrier_req_i  & host_target);
                barrier_release_o <= 1'b0;
            end
        end
    end

    assign barrier_busy_o = (|core_arrived_q) || (|stack_arrived_q) || host_arrived_q;

`ifdef FORMAL
    // ========================================================================
    // FORMAL VERIFICATION & SVA PROPERTIES (SymbiYosys / Z3 SMT)
    // ========================================================================

    // Assume reset behavior: start with reset for at least 1 cycle
    logic [3:0] f_rst_cnt = 0;
    always @(posedge clk) begin
        if (f_rst_cnt < 4'd2) f_rst_cnt <= f_rst_cnt + 1'b1;
    end
    always_comb begin
        if (f_rst_cnt < 4'd2) assume (!rst_n);
        else assume (rst_n);
    end

    // Safety Invariant 1: barrier_release_o is asserted iff barrier_fired on previous cycle
    logic f_past_valid;
    logic f_past_barrier_fired;
    always @(posedge clk) begin
        f_past_valid         <= rst_n;
        f_past_barrier_fired <= barrier_fired;

        if (rst_n && f_past_valid) begin
            assert (barrier_release_o == f_past_barrier_fired);

            // On the cycle immediately following a release, internal state is clean
            if (barrier_release_o) begin
                assert (core_arrived_q == '0);
                assert (stack_arrived_q == '0);
                assert (host_arrived_q == 1'b0);
            end
        end
    end

    // Safety Invariant 2: Missing participant forbids barrier from firing
    always @(posedge clk) begin
        if (rst_n) begin
            for (int c = 0; c < NUM_CORES; c++) begin
                if (core_target[c] && !core_arrived_q[c] && !core_barrier_req_i[c]) begin
                    assert (!barrier_fired);
                end
            end
            for (int s = 0; s < NUM_STACKS; s++) begin
                if (stack_target[s] && !stack_arrived_q[s] && !stack_barrier_req_i[s]) begin
                    assert (!barrier_fired);
                end
            end
            if (host_target && !host_arrived_q && !host_barrier_req_i) begin
                assert (!barrier_fired);
            end
        end
    end

    // Safety Invariant 3: Zero active participants prevents spurious fire
    always @(posedge clk) begin
        if (rst_n && !(|core_target || |stack_target || host_target)) begin
            assert (!barrier_fired);
        end
    end

    // Safety Invariant 4: Busy signal strictly reflects waiting participants
    always @(posedge clk) begin
        if (rst_n) begin
            assert (barrier_busy_o == ((|core_arrived_q) || (|stack_arrived_q) || host_arrived_q));
        end
    end

    // Cover: Barrier release is reachable with all participants active
    always @(posedge clk) begin
        if (rst_n) begin
            cover (barrier_release_o && &core_target && &stack_target && host_target);
        end
    end
`endif

endmodule

