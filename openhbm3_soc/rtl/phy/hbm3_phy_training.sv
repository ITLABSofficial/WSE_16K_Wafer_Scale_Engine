// ============================================================================
// File: hbm3_phy_training.sv
// Project: Open_HBM3_Controller
// Description:
//   PHY link training engine -- per-lane bit alignment search.
//   Dual-beat sequence pattern matching (TRAIN_PAT_A, TRAIN_PAT_B) to prevent
//   false locking on full-beat offsets.
//   Per-lane bit-slip rotation with pipeline settle cycles.
// ============================================================================
`include "hbm3_800g_defs.svh"

module hbm3_phy_training #(
    parameter int DQ_LANES  = HBM3_DQ_BITS_PER_CHANNEL,
    parameter int SER_RATIO = HBM3_PHY_DATA_BITS_PER_CHANNEL / HBM3_DQ_BITS_PER_CHANNEL,
    parameter logic [7:0] TRAIN_PAT_A = 8'hA5,   // even beat
    parameter logic [7:0] TRAIN_PAT_B = 8'h39,   // odd beat
    parameter int SETTLE   = 3                    // settle cycles post-shift
)(
    input  logic wck,
    input  logic rst_n,
    input  logic start,                            // initiate training pulse
    input  logic rx_valid,                         // valid beat from receiver
    input  logic [DQ_LANES*SER_RATIO-1:0] rx_data,
    output logic                align,             // global beat boundary reset
    output logic [DQ_LANES-1:0] bitslip,           // per-lane bitslip pulses
    output logic                tx_pattern_en,     // transmitter pattern enable
    output logic                done,
    output logic                ok,                // all lanes locked successfully
    output logic [DQ_LANES-1:0] locked             // per-lane lock status
);
    localparam int MAX_TRY   = 3 * SER_RATIO + 1;
    localparam int TRY_BITS  = $clog2(MAX_TRY + 1);
    localparam int SET_BITS  = $clog2(SETTLE + 1);

    typedef enum logic [2:0] {
        S_IDLE, S_ALIGN, S_SETTLE, S_CHECK, S_SLIP, S_DONE
    } state_t;
    state_t st;

    logic [TRY_BITS-1:0] tries [0:DQ_LANES-1];
    logic [SET_BITS-1:0] settle_cnt;
    logic [DQ_LANES-1:0] mismatch;
    logic                any_over;
    logic                phase_try;
    integer i;

    wire [SER_RATIO-1:0] exp_a = SER_RATIO'(TRAIN_PAT_A);
    wire [SER_RATIO-1:0] exp_b = SER_RATIO'(TRAIN_PAT_B);

    // Previous valid beat stored to evaluate consecutive (A, B) pattern sequence
    logic [SER_RATIO-1:0] prev_beat [0:DQ_LANES-1];
    logic [DQ_LANES-1:0]  seq_hit;

    always_comb begin
        for (i = 0; i < DQ_LANES; i = i + 1) begin
            seq_hit[i]  = (prev_beat[i] === exp_a) &&
                          (rx_data[i*SER_RATIO +: SER_RATIO] === exp_b);
            mismatch[i] = !locked[i] && !seq_hit[i];
        end
    end

    always_comb begin
        any_over = 1'b0;
        for (i = 0; i < DQ_LANES; i = i + 1)
            if (!locked[i] && tries[i] >= TRY_BITS'(MAX_TRY)) any_over = 1'b1;
    end

    always_ff @(posedge wck or negedge rst_n) begin
        if (!rst_n) begin
            st            <= S_IDLE;
            locked        <= '0;
            bitslip       <= '0;
            align         <= 1'b0;
            tx_pattern_en <= 1'b0;
            done          <= 1'b0;
            ok            <= 1'b0;
            settle_cnt    <= '0;
            phase_try     <= 1'b0;
            for (i = 0; i < DQ_LANES; i = i + 1) begin
                tries[i] <= '0; prev_beat[i] <= '0;
            end
        end else begin
            bitslip <= '0;                 // default: single-cycle pulse
            align   <= 1'b0;
            case (st)
                S_IDLE: begin
                    done <= 1'b0; ok <= 1'b0;
                    if (start) begin
                        locked        <= '0;
                        tx_pattern_en <= 1'b1;
                        for (i = 0; i < DQ_LANES; i = i + 1) tries[i] <= '0;
                        st <= S_ALIGN;
                    end
                end
                S_ALIGN: begin
                    align      <= 1'b1;    // establish beat boundary
                    settle_cnt <= '0;
                    phase_try  <= 1'b0;
                    st         <= S_SETTLE;
                end
                S_SETTLE: begin
                    // Wait for bitslip shift to propagate through pipeline.
                    // prev_beat is updated here to ensure fresh comparison in S_CHECK.
                    if (rx_valid) begin
                        for (i = 0; i < DQ_LANES; i = i + 1)
                            prev_beat[i] <= rx_data[i*SER_RATIO +: SER_RATIO];
                        if (settle_cnt == SET_BITS'(SETTLE)) st <= S_CHECK;
                        else settle_cnt <= settle_cnt + 1'b1;
                    end
                end
                S_CHECK: begin
                    if (rx_valid) begin
                        for (i = 0; i < DQ_LANES; i = i + 1) begin
                            prev_beat[i] <= rx_data[i*SER_RATIO +: SER_RATIO];
                            if (!locked[i] && seq_hit[i]) locked[i] <= 1'b1;
                        end
                        if (mismatch == '0) begin
                            st <= S_DONE; ok <= 1'b1;
                        end else if (any_over) begin
                            st <= S_DONE; ok <= 1'b0;
                        end else begin
                            // Evaluate both phases before applying bitslip
                            if (phase_try == 1'b1) begin
                                phase_try <= 1'b0;
                                st        <= S_SLIP;
                            end else begin
                                phase_try <= 1'b1;
                            end
                        end
                    end
                end
                S_SLIP: begin
                    // Shift only unlocked lanes
                    bitslip <= mismatch;
                    for (i = 0; i < DQ_LANES; i = i + 1)
                        if (mismatch[i]) tries[i] <= tries[i] + 1'b1;
                    settle_cnt <= '0;
                    phase_try  <= 1'b0;
                    st         <= S_SETTLE;
                end
                S_DONE: begin
                    done          <= 1'b1;
                    tx_pattern_en <= 1'b0;
                    if (start) st <= S_IDLE;   // re-train request
                end
                default: st <= S_IDLE;
            endcase
        end
    end
endmodule
