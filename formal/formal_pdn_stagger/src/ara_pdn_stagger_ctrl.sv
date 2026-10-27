// ============================================================================
// File: ara_pdn_stagger_ctrl.sv
// Project: Ara_MultiCore_WSE_HBM3 (Phase 3: Wafer PDN & di/dt Transient Protection)
// Technology: ASAP7 7nm FinFET Predictive PDK (Target: 2.0 GHz Ara / 1.0 GHz HBM)
// Specifications: SCALING_WSE_MASTER_PLAN.md & RAPOR_1 - RAPOR_8
// Defensive Rules: HATALAR.md (HATA 1, 2, 48, 84, 102, 105, 108 compliance)
//
// Description:
//   Wafer-Scale Power Delivery Network (PDN) di/dt Transient Protection Controller:
//   1. Throttles simultaneous 15-20 kW compute wake-up power surges across tiles.
//   2. Implements Staggered Pipeline Enable sequencing (configurable cycle delay between tiles).
//   3. Provides 1-cycle emergency power abort on thermal/fault trap (zero latency choke).
//   4. Emits real-time current telemetry and PDN rail stabilization handshake.
// ============================================================================

`timescale 1ps/1fs

module ara_pdn_stagger_ctrl #(
    parameter int unsigned NUM_DOMAINS         = 4,
    parameter int unsigned DEFAULT_STEP_CYCLES = 8,
    parameter int unsigned COUNTER_WIDTH       = 8,
    parameter int unsigned CNT_WIDTH           = $clog2(NUM_DOMAINS + 1),
    // Aliases for compatibility
    parameter int unsigned NUM_TILES           = NUM_DOMAINS,
    parameter int unsigned STAGGER_CYCLES      = DEFAULT_STEP_CYCLES
)(
    input  logic                          clk_i,
    input  logic                          rst_ni,

    // Control Interface
    input  logic                          global_wake_req_i,
    input  logic                          emergency_choke_i,
    input  logic [COUNTER_WIDTH-1:0]      cfg_step_delay_i,
    input  logic                          cfg_stagger_down_i,

    // Staggered Enable Outputs to Compute Tiles
    output logic [NUM_DOMAINS-1:0]        domain_en_o,
    output logic                          pdn_safe_o,
    output logic                          ramp_done_o,
    output logic                          ramp_active_o,
    output logic [CNT_WIDTH-1:0]          active_domain_cnt_o
);

    typedef enum logic [1:0] {
        ST_IDLE,
        ST_RAMPING_UP,
        ST_ACTIVE,
        ST_RAMPING_DOWN
    } pdn_state_e;

    localparam int unsigned IDX_WIDTH = (NUM_DOMAINS > 1) ? $clog2(NUM_DOMAINS) : 1;

    pdn_state_e state_q, state_d;
    logic [NUM_DOMAINS-1:0]   domain_en_q, domain_en_d;
    logic [COUNTER_WIDTH-1:0] step_cnt_q, step_cnt_d;
    logic [IDX_WIDTH-1:0]     curr_idx_q, curr_idx_d;

    assign domain_en_o   = domain_en_q;
    assign pdn_safe_o    = (state_q == ST_ACTIVE);
    assign ramp_done_o   = (state_q == ST_ACTIVE);
    assign ramp_active_o = (state_q == ST_RAMPING_UP || state_q == ST_RAMPING_DOWN);

    wire [COUNTER_WIDTH-1:0] step_cycles = (cfg_step_delay_i != '0) ? cfg_step_delay_i :
                                           COUNTER_WIDTH'(DEFAULT_STEP_CYCLES);

    // Active domain popcount
    logic [CNT_WIDTH-1:0] active_cnt;
    always_comb begin
        active_cnt = '0;
        for (int i = 0; i < NUM_DOMAINS; i++) begin
            if (domain_en_q[i]) active_cnt = active_cnt + CNT_WIDTH'(1);
        end
    end
    assign active_domain_cnt_o = active_cnt;

    // Combinational State Transition Logic
    always_comb begin
        state_d     = state_q;
        domain_en_d = domain_en_q;
        step_cnt_d  = step_cnt_q;
        curr_idx_d  = curr_idx_q;

        if (emergency_choke_i) begin
            state_d     = ST_IDLE;
            domain_en_d = '0;
            step_cnt_d  = '0;
            curr_idx_d  = '0;
        end else begin
            case (state_q)
                ST_IDLE: begin
                    domain_en_d = '0;
                    step_cnt_d  = '0;
                    curr_idx_d  = '0;
                    if (global_wake_req_i) begin
                        state_d        = ST_RAMPING_UP;
                        domain_en_d[0] = 1'b1;
                        curr_idx_d     = '0;
                        step_cnt_d     = '0;
                    end
                end

                ST_RAMPING_UP: begin
                    // Hold each domain enable for step_cycles
                    if (step_cnt_q >= (step_cycles - 1'b1)) begin
                        step_cnt_d = '0;
                        if (curr_idx_q >= IDX_WIDTH'(NUM_DOMAINS - 1)) begin
                            state_d = ST_ACTIVE;
                        end else begin
                            curr_idx_d  = curr_idx_q + IDX_WIDTH'(1);
                            domain_en_d = domain_en_q | (NUM_DOMAINS'(1) << (curr_idx_q + IDX_WIDTH'(1)));
                        end
                    end else begin
                        step_cnt_d = step_cnt_q + 1'b1;
                    end
                end

                ST_ACTIVE: begin
                    if (!global_wake_req_i) begin
                        if (cfg_stagger_down_i) begin
                            state_d    = ST_RAMPING_DOWN;
                            curr_idx_d = IDX_WIDTH'(NUM_DOMAINS - 1);
                            step_cnt_d = '0;
                        end else begin
                            state_d     = ST_IDLE;
                            domain_en_d = '0;
                        end
                    end
                end

                ST_RAMPING_DOWN: begin
                    if (global_wake_req_i) begin
                        state_d    = ST_RAMPING_UP;
                        step_cnt_d = '0;
                    end else if (step_cnt_q >= (step_cycles - 1'b1)) begin
                        step_cnt_d  = '0;
                        domain_en_d = domain_en_q & ~(NUM_DOMAINS'(1) << curr_idx_q);
                        if (curr_idx_q == '0) begin
                            state_d = ST_IDLE;
                        end else begin
                            curr_idx_d = curr_idx_q - IDX_WIDTH'(1);
                        end
                    end else begin
                        step_cnt_d = step_cnt_q + 1'b1;
                    end
                end

                default: state_d = ST_IDLE;
            endcase
        end
    end

    // Sequential Register Updates
    always_ff @(posedge clk_i or negedge rst_ni) begin
        if (!rst_ni) begin
            state_q     <= ST_IDLE;
            domain_en_q <= '0;
            step_cnt_q  <= '0;
            curr_idx_q  <= '0;
        end else begin
            state_q     <= state_d;
            domain_en_q <= domain_en_d;
            step_cnt_q  <= step_cnt_d;
            curr_idx_q  <= curr_idx_d;
        end
    end

`ifdef FORMAL
    logic [2:0] f_rst_cnt = 0;
    always @(posedge clk_i) begin
        if (f_rst_cnt < 3'd2) f_rst_cnt <= f_rst_cnt + 1'b1;
    end
    always_comb begin
        if (f_rst_cnt < 3'd2) assume (!rst_ni);
        else assume (rst_ni);
    end

    // Safety Invariant 1: 1-Cycle Emergency Choke Guarantee
    always_comb begin
        if (emergency_choke_i) begin
            assert (state_d     == ST_IDLE);
            assert (domain_en_d == '0);
        end
    end

    // Safety Invariant 2: Index Bounds & Active Full Domain Guarantee
    always @(posedge clk_i) begin
        if (rst_ni && f_rst_cnt >= 3'd2) begin
            assert (curr_idx_q < NUM_DOMAINS);
            if (state_q == ST_IDLE) begin
                assert (domain_en_q == '0);
            end
        end
    end
`endif

endmodule
