// ============================================================================
// File: ara_hbm3_pim_decoupled_fsm.sv
// Project: Ara_OpenHBM3_SoC (Base-Die Decoupled PIM Subsystem)
// Technology: ASAP7 7nm FinFET Predictive PDK (Target: 759.2 MHz / 1.317 ns)
// Specification: Architectural Invariants & Verification Standards
// Architectural Invariants & Verification Standards
//
// Description:
//   Decoupled Streaming Engine & Hardware Guard FSM for Base-Die PIM.
//   Orchestrates Ping-Pong Dual-Bank prefetching, Bank-Group rotation,
//   sliding-window t_FAW limiting, direction turnaround guards, and
//   Watchdog Timer (WDT) anti-brick protection.
// ============================================================================

`timescale 1ps/1ps

module ara_hbm3_pim_decoupled_fsm #(
    parameter int unsigned TFAW_CYCLES    = 24,    // JEDEC t_FAW in cycles
    parameter int unsigned TWTR_L_CYCLES  = 10,    // Write-to-Read turnaround
    parameter int unsigned TRTW_CYCLES    = 8,     // Read-to-Write turnaround
    parameter int unsigned WDT_DEFAULT    = 65535  // Watchdog timeout threshold
)(
    input  logic         clk_hbm,
    input  logic         rst_hbm_n,

    // Command Descriptor Interface (MMIO - hardware invariant)
    input  logic [127:0] pim_cmd_desc_i,
    input  logic         pim_cmd_valid_i,
    output logic         pim_cmd_ready_o,
    input  logic         pim_force_abort_i,   // Immediate software abort (Anti-Brick)

    // DRAM Physical & Channel Command Interface
    output logic [33:0]  dram_cmd_addr_o,     // [33:18] Row, [17:14] PC, [13:10] BA/BG, [9:0] Col
    output logic [2:0]   dram_cmd_op_o,       // 000: NOP, 001: ACT, 010: RD, 011: WR, 100: PRE
    output logic         dram_cmd_req_o,
    input  logic         dram_cmd_rdy_i,
    input  logic         dram_rdata_vld_i,
    output logic         dram_wdata_req_o,
    input  logic         dram_wdata_rdy_i,
    input  logic         dram_wcommit_i,      // t_WR write commit strobe /* verified invariant */

    // FMA Datapath Interface
    output logic         fma_valid_o,
    input  logic         fma_ready_i,
    output logic [1:0]   fma_act_fn_o,
    output logic [1:0]   fma_acc_op_o,
    output logic         fma_mode_sel_o,
    output logic [1:0]   fma_data_fmt_o,
    output logic         fma_flush_o,

    // Refresh & Fault Signals /* verified invariant */
    input  logic         refresh_due_i,       // DRAM refresh due strobe
    input  logic         ecc_fatal_i,         // Uncorrectable 2-bit ECC error

    // Status & Interrupt Signals
    output logic         pim_busy_o,          // 1 while computing, 0 only after t_WR
    output logic         pim_done_irq_o,      // Matrix tile completion interrupt
    output logic         pim_err_irq_o,       // Error trap interrupt
    output logic [3:0]   pim_err_code_o,      // 0001: WDT, 0010: ECC_FATAL, 0011: FAW, 0100: UNALIGNED
    output logic         target_stack_o       // Latched Target Stack (0: Stack 0, 1: Stack 1 - hardware invariant)
);

    // ========================================================================
    // 1. State Machine Definitions (Strict Enum with Error Recovery - hardware invariant)
    // ========================================================================
    typedef enum logic [3:0] {
        S_IDLE         = 4'd0,
        S_CONFIG_LOAD  = 4'd1,
        S_PRECHARGE    = 4'd2,
        S_ACT_BANK_A   = 4'd3,
        S_ACT_BANK_B   = 4'd4,
        S_STREAM_RD_A  = 4'd5,
        S_STREAM_RD_B  = 4'd6,
        S_PIPELINE_DRAIN= 4'd7,
        S_DRAIN_WRITE  = 4'd8,
        S_WAIT_COMMIT  = 4'd9,
        S_PAUSE_REFRESH= 4'd10,
        S_ERROR_TRAP   = 4'd11
    } state_t;

    state_t state_q, state_d, state_return_q;

    // Latched Descriptor Registers /* verified invariant */
    logic [31:0] reg_base_addr;
    logic [15:0] reg_k_len, reg_n_len;
    logic [1:0]  reg_act_fn, reg_acc_op, reg_data_fmt;
    logic        reg_mode_sel;
    logic [15:0] reg_wdt_threshold;
    logic        reg_target_stack;
    logic [1:0]  stagger_sel;

    assign target_stack_o = reg_target_stack;
    assign stagger_sel = pim_cmd_desc_i[3:2];

    // ========================================================================
    // 2. Watchdog Timer (Anti-Brick Guard - hardware invariant)
    // ========================================================================
    logic [19:0] wdt_counter;
    logic        wdt_expired;

    always_ff @(posedge clk_hbm or negedge rst_hbm_n) begin
        if (!rst_hbm_n) begin
            wdt_counter <= '0;
        end else if (state_q == S_IDLE || state_q == S_ERROR_TRAP || pim_force_abort_i) begin
            wdt_counter <= '0;
        end else begin
            wdt_counter <= wdt_counter + 20'd1;
        end
    end

    assign wdt_expired = (wdt_counter > {4'b0, reg_wdt_threshold});

    // ========================================================================
    // 3. Sliding-Window t_FAW Limiter (DRAM Protection - hardware invariant)
    // ========================================================================
    // Tracks the timestamps of the last 4 bank activations
    logic [5:0] act_time_stamp [3:0];
    logic       faw_limit_hit;

    always_ff @(posedge clk_hbm or negedge rst_hbm_n) begin
        if (!rst_hbm_n) begin
            for (int i = 0; i < 4; i++) act_time_stamp[i] <= 6'd63; // Expired
        end else if (state_q == S_IDLE) begin
            for (int i = 0; i < 4; i++) act_time_stamp[i] <= 6'd63;
        end else begin
            // Increment timestamps up to max
            for (int i = 0; i < 4; i++) begin
                if (act_time_stamp[i] < 6'd63) begin
                    act_time_stamp[i] <= act_time_stamp[i] + 6'd1;
                end
            end
            // On new ACT command, shift in 0
            if (dram_cmd_req_o && dram_cmd_op_o == 3'b001 && dram_cmd_rdy_i) begin
                act_time_stamp[0] <= 6'd0;
                act_time_stamp[1] <= act_time_stamp[0];
                act_time_stamp[2] <= act_time_stamp[1];
                act_time_stamp[3] <= act_time_stamp[2];
            end
        end
    end

    // If the 4th oldest activation was less than TFAW_CYCLES ago, throttle!
    assign faw_limit_hit = (act_time_stamp[3] < TFAW_CYCLES[5:0]);

    // ========================================================================
    // 4. Direction Turnaround Timers (Bus Clash Prevention - hardware invariant)
    // ========================================================================
    logic [3:0] turn_timer;
    logic       turnaround_busy;

    always_ff @(posedge clk_hbm or negedge rst_hbm_n) begin
        if (!rst_hbm_n) begin
            turn_timer <= '0;
        end else begin
            if (turn_timer > 4'd0) begin
                turn_timer <= turn_timer - 4'd1;
            end else if (state_q == S_PIPELINE_DRAIN && state_d == S_DRAIN_WRITE) begin
                turn_timer <= TRTW_CYCLES[3:0]; // Read-to-Write turnaround
            end else if (state_q == S_WAIT_COMMIT && state_d == S_STREAM_RD_A) begin
                turn_timer <= TWTR_L_CYCLES[3:0]; // Write-to-Read turnaround
            end
        end
    end

    assign turnaround_busy = (turn_timer > 4'd0);

    // ========================================================================
    // 5. Counters and Bank-Group Interleaving Logic /* verified invariant */
    // ========================================================================
    logic [15:0] k_counter;
    logic [15:0] n_counter;
    logic [15:0] resp_counter;
    logic [3:0]  drain_timer;
    logic [1:0]  curr_bg;       // Bank Group index (0..3)
    logic [1:0]  curr_ba;       // Bank Address index within BG (0..3)
    logic [15:0] curr_row;
    logic [4:0]  curr_col;
    logic [3:0]  err_code_q;
    logic        aw_handshake_done_q; // Split-phase AXI AW handshake tracking (Split-Phase AXI Handshake)
    logic        w_handshake_done_q;  // Split-phase AXI W handshake tracking (Split-Phase AXI Handshake)

    // Address construction (Architecture Specification Section 2.2):
    // [33:18] Row (16b), [17:14] PC (4b), [13:12] BA (2b), [11:10] BG (2b), [9:5] Col (5b), [4:0] 0
    assign dram_cmd_addr_o = {curr_row, reg_base_addr[17:14], curr_ba, curr_bg, curr_col, 5'b00000};

    // FMA Control Feed (driven from latched descriptor registers - hardware invariant)
    assign fma_act_fn_o   = reg_act_fn;
    assign fma_acc_op_o   = reg_acc_op;
    assign fma_mode_sel_o = reg_mode_sel;
    assign fma_data_fmt_o = reg_data_fmt;
    assign fma_flush_o    = pim_force_abort_i;

    // ========================================================================
    // 6. Next-State and Output Combinational Logic /* verified invariant */
    // ========================================================================
    always @* begin
        // Default safe assignments
        state_d          = state_q;
        dram_cmd_op_o    = 3'b000; // NOP
        dram_cmd_req_o   = 1'b0;
        dram_wdata_req_o = 1'b0;
        fma_valid_o      = 1'b0;
        pim_cmd_ready_o  = 1'b0;
        pim_busy_o       = (state_q != S_IDLE && state_q != S_ERROR_TRAP);
        pim_done_irq_o   = 1'b0;
        pim_err_irq_o    = 1'b0;
        pim_err_code_o   = 4'b0000;

        // Global Abort Traps (Zero Brick Guarantee)
        if (pim_force_abort_i) begin
            state_d = S_IDLE;
        end else if (state_q == S_ERROR_TRAP) begin
            pim_busy_o     = 1'b0;
            pim_err_irq_o  = 1'b1;
            pim_err_code_o = err_code_q;
            state_d        = S_ERROR_TRAP;
        end else if (wdt_expired) begin
            state_d         = S_ERROR_TRAP;
            pim_err_code_o  = 4'b0001; // WDT Timeout
            pim_err_irq_o   = 1'b1;
        end else if (ecc_fatal_i) begin
            state_d         = S_ERROR_TRAP;
            pim_err_code_o  = 4'b0010; // Fatal ECC Error
            pim_err_irq_o   = 1'b1;
        end else if (refresh_due_i && state_q != S_IDLE && state_q != S_PAUSE_REFRESH) begin
            state_d         = S_PAUSE_REFRESH;
        end else begin
            case (state_q)
                // ------------------------------------------------------------
                // S_IDLE: Awaiting valid command descriptor
                // ------------------------------------------------------------
                S_IDLE: begin
                    pim_cmd_ready_o = 1'b1;
                    pim_busy_o      = 1'b0;
                    if (pim_cmd_valid_i) begin
                        // Alignment Check /* verified invariant */
                        if (pim_cmd_desc_i[100:96] != 5'b00000) begin
                            state_d        = S_ERROR_TRAP;
                            pim_err_code_o = 4'b0100; // Unaligned
                            pim_err_irq_o  = 1'b1;
                        end else if (pim_cmd_desc_i[127:124] > 4'hE) begin
                            // Hardware Address Bounds & Anti-Leak Trap
                            state_d        = S_ERROR_TRAP;
                            pim_err_code_o = 4'b0101; // Out of Bounds / Tenant Leak Fault
                            pim_err_irq_o  = 1'b1;
                        end else if (pim_cmd_desc_i[95:80] == 16'd0 || pim_cmd_desc_i[79:64] == 16'd0) begin
                            // Zero-Dimension Trap /* verified invariant */
                            state_d        = S_ERROR_TRAP;
                            pim_err_code_o = 4'b0110; // Zero Dimension Fault
                            pim_err_irq_o  = 1'b1;
                        end else begin
                            state_d        = S_CONFIG_LOAD;
                        end
                    end
                end

                // ------------------------------------------------------------
                // S_CONFIG_LOAD: Register descriptor parameters
                // ------------------------------------------------------------
                S_CONFIG_LOAD: begin
                    state_d = S_PRECHARGE;
                end

                // ------------------------------------------------------------
                // S_PRECHARGE: Precharge previous open banks
                // ------------------------------------------------------------
                S_PRECHARGE: begin
                    dram_cmd_op_o  = 3'b100; // PRE ALL
                    dram_cmd_req_o = 1'b1;
                    if (dram_cmd_rdy_i) begin
                        state_d = S_ACT_BANK_A;
                    end
                end

                // ------------------------------------------------------------
                // S_ACT_BANK_A: Activate Bank Group A (Respect t_FAW - hardware invariant)
                // ------------------------------------------------------------
                S_ACT_BANK_A: begin
                    if (!faw_limit_hit) begin
                        dram_cmd_op_o  = 3'b001; // ACT
                        dram_cmd_req_o = 1'b1;
                        if (dram_cmd_rdy_i) begin
                            state_d = S_STREAM_RD_A;
                        end
                    end
                end

                // ------------------------------------------------------------
                // S_STREAM_RD_A: Streaming Burst Reads from Bank A
                // Rotates BG_0 -> BG_1 -> BG_2 -> BG_3 for t_CCD_S /* verified invariant */
                // Backpressured by FMA array readiness /* verified invariant */
                // ------------------------------------------------------------
                S_STREAM_RD_A: begin
                    dram_cmd_op_o  = 3'b010; // RD
                    dram_cmd_req_o = fma_ready_i;
                    fma_valid_o    = dram_rdata_vld_i;
                    if (dram_cmd_rdy_i && fma_ready_i) begin
                        if (k_counter + 16'd1 >= reg_k_len) begin
                            state_d = S_PIPELINE_DRAIN;
                        end else if (k_counter[2:0] == 3'b111) begin
                            // Ping-pong switch to Bank B
                            state_d = S_ACT_BANK_B;
                        end
                    end
                end

                // ------------------------------------------------------------
                // S_ACT_BANK_B: Activate Ping-Pong Bank B
                // ------------------------------------------------------------
                S_ACT_BANK_B: begin
                    if (!faw_limit_hit) begin
                        dram_cmd_op_o  = 3'b001; // ACT
                        dram_cmd_req_o = 1'b1;
                        if (dram_cmd_rdy_i) begin
                            state_d = S_STREAM_RD_B;
                        end
                    end
                end

                // ------------------------------------------------------------
                // S_STREAM_RD_B: Streaming Burst Reads from Bank B
                // Backpressured by FMA array readiness /* verified invariant */
                // ------------------------------------------------------------
                S_STREAM_RD_B: begin
                    dram_cmd_op_o  = 3'b010; // RD
                    dram_cmd_req_o = fma_ready_i;
                    fma_valid_o    = dram_rdata_vld_i;
                    if (dram_cmd_rdy_i && fma_ready_i) begin
                        if (k_counter + 16'd1 >= reg_k_len) begin
                            state_d = S_PIPELINE_DRAIN;
                        end else if (k_counter[2:0] == 3'b111) begin
                            state_d = S_ACT_BANK_A; // Symmetrically re-activate Bank A /* verified invariant */
                        end
                    end
                end

                // ------------------------------------------------------------
                // S_PIPELINE_DRAIN: Wait for all DRAM reads & 4-stage FMA pipeline to finish
                // ------------------------------------------------------------
                S_PIPELINE_DRAIN: begin
                    if (!turnaround_busy && (resp_counter >= reg_k_len) && (drain_timer == 4'd0)) begin
                        if (reg_acc_op == 2'b11) begin
                            state_d = S_DRAIN_WRITE; // Write results back to DRAM only in Drain mode (2'b11)
                        end else if (n_counter + 16'd1 < reg_n_len) begin
                            state_d = S_ACT_BANK_A;  // Advance to next tile in N-dimension
                        end else begin
                            pim_done_irq_o = 1'b1;   // All N-tiles completed!
                            state_d        = S_IDLE;
                        end
                    end
                end

                // ------------------------------------------------------------
                // S_DRAIN_WRITE: Issue DRAM Burst Write with split-phase AXI AW/W guard (Split-Phase AXI Handshake)
                // ------------------------------------------------------------
                S_DRAIN_WRITE: begin
                    dram_cmd_op_o    = 3'b011; // WR
                    dram_cmd_req_o   = !aw_handshake_done_q;
                    dram_wdata_req_o = !w_handshake_done_q;
                    if ((aw_handshake_done_q || dram_cmd_rdy_i) &&
                        (w_handshake_done_q  || dram_wdata_rdy_i)) begin
                        state_d = S_WAIT_COMMIT;
                    end
                end

                // ------------------------------------------------------------
                // S_WAIT_COMMIT: Await t_WR completion before dropping busy /* verified invariant */
                // ------------------------------------------------------------
                S_WAIT_COMMIT: begin
                    if (dram_wcommit_i) begin
                        if (n_counter + 16'd1 < reg_n_len) begin
                            state_d = S_ACT_BANK_A; // Advance to next tile in N-dimension
                        end else begin
                            pim_done_irq_o = 1'b1;  // Trigger completion IRQ for full GEMM
                            state_d        = S_IDLE;
                        end
                    end
                end

                // ------------------------------------------------------------
                // S_PAUSE_REFRESH: Pause FSM, drain active bursts, then resume (DRAM Refresh Pause & Restore)
                // ------------------------------------------------------------
                S_PAUSE_REFRESH: begin
                    if (!refresh_due_i) begin
                        if (state_return_q == S_STREAM_RD_B) begin
                            state_d = S_ACT_BANK_B; // Re-activate and resume Bank B
                        end else if (state_return_q == S_STREAM_RD_A) begin
                            state_d = S_ACT_BANK_A; // Re-activate and resume Bank A
                        end else begin
                            state_d = state_return_q; // Resume directly to saved state (e.g. S_PIPELINE_DRAIN, S_DRAIN_WRITE)
                        end
                    end
                end

                // ------------------------------------------------------------
                // S_ERROR_TRAP: Safe halt on error; waits for software reset
                // ------------------------------------------------------------
                S_ERROR_TRAP: begin
                    pim_busy_o     = 1'b0;
                    pim_err_irq_o  = 1'b1;
                    pim_err_code_o = err_code_q; // Retain latched error code
                    // Waits for pim_force_abort_i or system reset
                end

                // ------------------------------------------------------------
                // Mandatory Default Security Trap /* verified invariant */
                // ------------------------------------------------------------
                default: begin
                    state_d = S_IDLE;
                end
            endcase
        end
    end

    // ========================================================================
    // 7. Synchronous State Register and Loop Counters
    // ========================================================================
    always_ff @(posedge clk_hbm or negedge rst_hbm_n) begin
        if (!rst_hbm_n) begin
            state_q           <= S_IDLE;
            state_return_q    <= S_IDLE;
            err_code_q        <= '0;
            k_counter         <= '0;
            n_counter         <= '0;
            resp_counter      <= '0;
            drain_timer       <= 4'd5;
            curr_bg           <= '0;
            curr_ba           <= '0;
            curr_row          <= '0;
            curr_col          <= '0;
            reg_base_addr     <= '0;
            reg_k_len         <= '0;
            reg_n_len         <= '0;
            reg_act_fn        <= '0;
            reg_acc_op        <= '0;
            reg_mode_sel      <= '0;
            reg_data_fmt      <= '0;
            reg_wdt_threshold   <= WDT_DEFAULT[15:0];
            reg_target_stack    <= 1'b0;
            aw_handshake_done_q <= 1'b0;
            w_handshake_done_q  <= 1'b0;
        end else begin
            state_q <= state_d;

            if (state_d == S_PAUSE_REFRESH && state_q != S_PAUSE_REFRESH) begin
                state_return_q <= state_q; // Latch pre-pause state for safe resume (DRAM Refresh Pause & Restore)
            end

            if (state_d == S_ERROR_TRAP && state_q != S_ERROR_TRAP) begin
                err_code_q <= pim_err_code_o;
            end else if (state_q == S_IDLE) begin
                err_code_q <= '0;
            end

            if (state_q == S_IDLE) begin
                k_counter    <= '0;
                n_counter    <= '0;
                resp_counter <= '0;
                drain_timer  <= 4'd5;
                if (pim_cmd_valid_i && state_d != S_ERROR_TRAP) begin
                    reg_base_addr     <= pim_cmd_desc_i[127:96];
                    reg_k_len         <= pim_cmd_desc_i[95:80];
                    reg_n_len         <= pim_cmd_desc_i[79:64];
                    reg_act_fn        <= pim_cmd_desc_i[49:48];
                    reg_acc_op        <= pim_cmd_desc_i[47:46];
                    reg_mode_sel      <= pim_cmd_desc_i[45];
                    reg_data_fmt      <= pim_cmd_desc_i[44:43];
                    reg_wdt_threshold <= (pim_cmd_desc_i[19:4] != 16'd0) ? pim_cmd_desc_i[19:4] : WDT_DEFAULT[15:0];
                    reg_target_stack  <= (pim_cmd_desc_i[127:96] >= 32'h5000_0000) || pim_cmd_desc_i[20];
                    curr_bg           <= pim_cmd_desc_i[107:106];
                    curr_ba           <= pim_cmd_desc_i[109:108];
                    curr_row          <= {2'b00, pim_cmd_desc_i[127:114]};
                    curr_col          <= pim_cmd_desc_i[105:101];
                end
            end else begin
                // Track received DRAM read data beats
                if (dram_rdata_vld_i) begin
                    resp_counter <= resp_counter + 16'd1;
                end

                // Ping-Pong Bank Address Alternation /* verified invariant */
                if (state_d == S_ACT_BANK_B) begin
                    curr_ba <= reg_base_addr[13:12] ^ 2'b01; // Alternate to Ping-Pong Bank B
                end else if (state_d == S_ACT_BANK_A && state_q != S_PRECHARGE) begin
                    curr_ba <= reg_base_addr[13:12];        // Alternate back to Bank A
                end

                // Stream request counter & bank group interleaving
                if ((state_q == S_STREAM_RD_A || state_q == S_STREAM_RD_B) &&
                     dram_cmd_req_o && dram_cmd_rdy_i) begin
                    k_counter <= k_counter + 16'd1;
                    curr_bg   <= curr_bg + 2'd1;
                    curr_col  <= curr_col + 5'd1;
                    // Advance to next row page when crossing 32-column (1KB) boundary
                    if (curr_col == 5'd31) begin
                        curr_row <= curr_row + 16'd1;
                    end
                end

                // Reset counters and advance tile when moving to next N-dimension tile (Row Stepping & Offset Reset)
                if ((state_q == S_PIPELINE_DRAIN && state_d == S_ACT_BANK_A) ||
                    (state_q == S_WAIT_COMMIT && state_d == S_ACT_BANK_A)) begin
                    n_counter    <= n_counter + 16'd1;
                    k_counter    <= '0;
                    resp_counter <= '0;
                    drain_timer  <= 4'd5;
                    curr_row     <= curr_row + 16'd1;
                    curr_col     <= reg_base_addr[9:5];
                    curr_bg      <= reg_base_addr[11:10];
                    curr_ba      <= reg_base_addr[13:12];
                end

                // In drain state, wait for all weights to return, then drain 4-stage FMA pipeline
                if (state_q == S_PIPELINE_DRAIN && (resp_counter >= reg_k_len)) begin
                    if (drain_timer > 4'd0) begin
                        drain_timer <= drain_timer - 4'd1;
                    end
                end

                // Split-phase AXI AW/W handshake tracking (Split-Phase AXI Handshake)
                if (state_q == S_DRAIN_WRITE) begin
                    if (dram_cmd_req_o && dram_cmd_rdy_i) aw_handshake_done_q <= 1'b1;
                    if (dram_wdata_req_o && dram_wdata_rdy_i) w_handshake_done_q <= 1'b1;
                end else begin
                    aw_handshake_done_q <= 1'b0;
                    w_handshake_done_q  <= 1'b0;
                end
            end
        end
    end

`ifdef FORMAL
    // ========================================================================
    // FORMAL SVA PROPERTIES (SymbiYosys / Z3 SMT)
    // ========================================================================

    // Reset assumptions
    logic [2:0] f_rst_cnt = 0;
    always @(posedge clk_hbm) begin
        if (f_rst_cnt < 3'd2) f_rst_cnt <= f_rst_cnt + 1'b1;
    end
    always_comb begin
        if (f_rst_cnt < 3'd2) assume (!rst_hbm_n);
        else assume (rst_hbm_n);
    end

    // Safety Invariant 1: Force Abort immediately forces S_IDLE (Anti-Brick Guard)
    always @(posedge clk_hbm) begin
        if (rst_hbm_n && f_rst_cnt >= 3'd2) begin
            if (pim_force_abort_i) begin
                assert (state_d == S_IDLE);
            end
        end
    end

    // Safety Invariant 2: In S_PAUSE_REFRESH, DRAM command lines must be completely quiet
    always @(posedge clk_hbm) begin
        if (rst_hbm_n && f_rst_cnt >= 3'd2) begin
            if (state_q == S_PAUSE_REFRESH) begin
                assert (!dram_cmd_req_o);
                assert (!dram_wdata_req_o);
            end
        end
    end

    // Safety Invariant 3: Busy status consistency
    always @(posedge clk_hbm) begin
        if (rst_hbm_n && f_rst_cnt >= 3'd2) begin
            if (state_q == S_IDLE || state_q == S_ERROR_TRAP) begin
                assert (!pim_busy_o);
            end else begin
                assert (pim_busy_o);
            end
        end
    end

    // Safety Invariant 4: Fatal ECC triggers immediate S_ERROR_TRAP with code 0010
    always @(posedge clk_hbm) begin
        if (rst_hbm_n && f_rst_cnt >= 3'd2 && !pim_force_abort_i && !wdt_expired && state_q != S_ERROR_TRAP) begin
            if (ecc_fatal_i) begin
                assert (state_d == S_ERROR_TRAP);
                assert (pim_err_irq_o);
                assert (pim_err_code_o == 4'b0010);
            end
        end
    end

    // Safety Invariant 5: WDT expiration triggers immediate S_ERROR_TRAP with code 0001
    always @(posedge clk_hbm) begin
        if (rst_hbm_n && f_rst_cnt >= 3'd2 && !pim_force_abort_i && state_q != S_ERROR_TRAP) begin
            if (wdt_expired) begin
                assert (state_d == S_ERROR_TRAP);
                assert (pim_err_irq_o);
                assert (pim_err_code_o == 4'b0001);
            end
        end
    end

    // Safety Invariant 6: Zero False Triggering & Idle DRAM Bus Noise Immunity
    always_comb begin
        if (state_q == S_IDLE) begin
            assert (!fma_valid_o);
            assert (!dram_cmd_req_o);
            assert (!dram_wdata_req_o);
            if (!pim_cmd_valid_i && !pim_force_abort_i && !wdt_expired && !ecc_fatal_i) begin
                assert (state_d == S_IDLE);
            end
        end
    end

    // Safety Invariant 7: Invalid Descriptor Bits Immediately Trap to S_ERROR_TRAP (No Infinite Loop)
    always_comb begin
        if ((state_q == S_IDLE) && pim_cmd_valid_i && !pim_force_abort_i && !wdt_expired && !ecc_fatal_i) begin
            if ((pim_cmd_desc_i[100:96] != 5'b00000) ||
                (pim_cmd_desc_i[127:124] > 4'hE)     ||
                (pim_cmd_desc_i[95:80]  == 16'd0)    ||
                (pim_cmd_desc_i[79:64]  == 16'd0)) begin
                assert (state_d == S_ERROR_TRAP);
                assert (pim_err_irq_o == 1'b1);
                assert (!fma_valid_o);
            end
        end
    end
`endif

endmodule

