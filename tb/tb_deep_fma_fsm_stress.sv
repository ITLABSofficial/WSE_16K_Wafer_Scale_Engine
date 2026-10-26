// ============================================================================
// File: tb_deep_fma_fsm_stress.sv
// Description: Adversarial testbench attacking corner cases in FMA & Systolic FSM
// ============================================================================
`timescale 1ps/1ps

module tb_deep_fma_fsm_stress;
    logic clk = 0;
    always #250 clk = ~clk; // 2.0 GHz

    logic rst_n = 0;
    int error_count = 0;

    // DUT 1: ara_multicore_true_fma_6stage
    logic         fma_valid_i;
    wire          fma_ready_o;
    logic         fma_act_valid_i;
    wire          fma_act_ready_o;
    wire          fma_valid_o;
    logic         fma_ready_i;
    logic [2:0]   fma_data_fmt_i;
    logic [1:0]   fma_act_fn_i;
    logic [1:0]   fma_acc_op_i;
    logic         fma_mode_sel_i;
    logic         fma_flush_i;
    logic [255:0] fma_b_data_i;
    logic [255:0] fma_a_data_i;
    logic [511:0] fma_c_bias_i;
    wire  [511:0] fma_res_data_o;
    wire  [31:0]  fma_scalar_dot_o;
    wire  [3:0]   fma_status_flags_o;

    ara_multicore_true_fma_6stage #(
        .LANES(16), .DATA_W(256), .ACC_W(512)
    ) dut_fma (
        .clk(clk), .rst_n(rst_n),
        .valid_i(fma_valid_i), .ready_o(fma_ready_o),
        .act_valid_i(fma_act_valid_i), .act_ready_o(fma_act_ready_o),
        .valid_o(fma_valid_o), .ready_i(fma_ready_i),
        .data_fmt_i(fma_data_fmt_i), .act_fn_i(fma_act_fn_i),
        .acc_op_i(fma_acc_op_i), .mode_sel_i(fma_mode_sel_i),
        .flush_i(fma_flush_i),
        .b_data_i(fma_b_data_i), .a_data_i(fma_a_data_i), .c_bias_i(fma_c_bias_i),
        .res_data_o(fma_res_data_o), .scalar_dot_o(fma_scalar_dot_o),
        .status_flags_o(fma_status_flags_o), .fma_cg_en_o()
    );

    // DUT 2: ara_systolic_tensor_unit
    logic         sys_abort_i;
    logic         sys_cmd_valid_i;
    wire          sys_cmd_ready_o;
    logic [2:0]   sys_data_fmt_i;
    logic [1:0]   sys_act_fn_i;
    logic [1:0]   sys_tile_op_i;
    logic [7:0]   sys_k_len_i;
    wire          sys_tile_done_o;
    wire          sys_busy_o;
    logic         sys_act_valid_i;
    wire          sys_act_ready_o;
    logic [255:0] sys_act_data_i;
    logic         sys_wgt_valid_i;
    wire          sys_wgt_ready_o;
    logic [255:0] sys_wgt_data_i;
    wire          sys_res_valid_o;
    logic         sys_res_ready_i;
    wire  [511:0] sys_res_data_o;
    wire  [3:0]   sys_res_row_idx_o;
    wire  [3:0]   sys_status_flags_o;

    ara_systolic_tensor_unit #(
        .DIM_M(16), .DIM_N(16), .DATA_W(256), .ACC_W(512)
    ) dut_sys (
        .clk(clk), .rst_n(rst_n), .abort_i(sys_abort_i),
        .cmd_valid_i(sys_cmd_valid_i), .cmd_ready_o(sys_cmd_ready_o),
        .data_fmt_i(sys_data_fmt_i), .act_fn_i(sys_act_fn_i),
        .tile_op_i(sys_tile_op_i), .k_len_i(sys_k_len_i),
        .tile_done_o(sys_tile_done_o), .busy_o(sys_busy_o),
        .act_valid_i(sys_act_valid_i), .act_ready_o(sys_act_ready_o),
        .act_data_i(sys_act_data_i),
        .wgt_valid_i(sys_wgt_valid_i), .wgt_ready_o(sys_wgt_ready_o),
        .wgt_data_i(sys_wgt_data_i),
        .res_valid_o(sys_res_valid_o), .res_ready_i(sys_res_ready_i),
        .res_data_o(sys_res_data_o), .res_row_idx_o(sys_res_row_idx_o),
        .status_flags_o(sys_status_flags_o)
    );

    // DUT 3: ara_core_fp32_adder
    logic [31:0] add_op_a, add_op_b;
    wire  [31:0] add_res;
    ara_core_fp32_adder dut_adder (
        .op_a(add_op_a), .op_b(add_op_b), .res(add_res)
    );

    initial begin
        $display("===============================================================");
        $display("   ADVERSARIAL STRESS TESTBENCH START");
        $display("===============================================================");

        fma_valid_i = 0; fma_act_valid_i = 0; fma_ready_i = 1;
        fma_data_fmt_i = 3'b000; fma_act_fn_i = 2'b00; fma_acc_op_i = 2'b00;
        fma_mode_sel_i = 0; fma_flush_i = 0;
        fma_b_data_i = '0; fma_a_data_i = '0; fma_c_bias_i = '0;

        sys_abort_i = 0; sys_cmd_valid_i = 0; sys_data_fmt_i = 3'b000;
        sys_act_fn_i = 2'b00; sys_tile_op_i = 2'b00; sys_k_len_i = 8'd1;
        sys_act_valid_i = 0; sys_act_data_i = '0;
        sys_wgt_valid_i = 0; sys_wgt_data_i = '0;
        sys_res_ready_i = 1;

        add_op_a = 0; add_op_b = 0;

        #1000 rst_n = 1;
        @(posedge clk);
        #1;

        // -------------------------------------------------------------
        // TEST 1: Load Bias (acc_op = 2'b10) without activations in FMA
        // -------------------------------------------------------------
        $display("\n--- TEST 1: Load Bias (acc_op=2'b10) without act_valid_i ---");
        fma_valid_i     = 1'b1;
        fma_acc_op_i    = 2'b10; // Load Bias
        fma_act_valid_i = 1'b0;  // No activation provided!
        fma_c_bias_i    = {16{32'h40800000}}; // 4.0 FP32 bias

        @(posedge clk);
        #1;
        fma_valid_i = 1'b0;

        // Wait up to 10 cycles for valid_o
        begin : wait_load_bias
            int cycles;
            for (cycles = 0; cycles < 10; cycles++) begin
                @(posedge clk);
                #1;
                if (fma_valid_o) disable wait_load_bias;
            end
        end

        if (!fma_valid_o) begin
            $display("[FAIL BUG 1] Load Bias DEADLOCKED! valid_o did not assert within 10 cycles because act_req=1 required non-existent activation!");
            error_count++;
        end else begin
            $display("[PASS] Load Bias retired with res=%h", fma_res_data_o[31:0]);
        end

        // -------------------------------------------------------------
        // TEST 2: Idle Channel B with acc_op_i=2'b11 on bus blocks act_ready_o
        // -------------------------------------------------------------
        $display("\n--- TEST 2: Idle B with acc_op_i=2'b11 blocks act_ready_o ---");
        fma_valid_i  = 1'b0;
        fma_acc_op_i = 2'b11; // Bus line held at 2'b11 while valid_i=0
        @(posedge clk);
        #1;
        if (fma_act_ready_o == 1'b0) begin
            $display("[FAIL BUG 2] act_ready_o dropped to 0 while valid_i=0 and a_count=0 just because acc_op_i bus has 2'b11!");
            error_count++;
        end else begin
            $display("[PASS] act_ready_o correctly remains 1 while B is idle");
        end

        // -------------------------------------------------------------
        // TEST 3: Systolic skewed arrival (A arrives 1 cycle before B)
        // -------------------------------------------------------------
        $display("\n--- TEST 3: Systolic Skewed Arrival (act_valid at T, wgt_valid at T+1) ---");
        // Start Outer product GEMM
        sys_cmd_valid_i = 1'b1;
        sys_tile_op_i   = 2'b01; // Outer product
        sys_k_len_i     = 8'd1;
        @(posedge clk);
        #1;
        sys_cmd_valid_i = 1'b0;
        @(posedge clk); // S_COMPUTE_OUT
        #1;

        $display("State in S_COMPUTE_OUT: sys_act_ready_o=%b, sys_wgt_ready_o=%b", sys_act_ready_o, sys_wgt_ready_o);

        // Cycle T: act arrives alone
        sys_act_valid_i = 1'b1;
        sys_act_data_i  = {16{16'h3c00}}; // 1.0 FP16
        sys_wgt_valid_i = 1'b0;
        @(posedge clk);
        #1;

        // Cycle T+1: wgt arrives alone
        sys_act_valid_i = 1'b0;
        sys_wgt_valid_i = 1'b1;
        sys_wgt_data_i  = {16{16'h4000}}; // 2.0 FP16
        @(posedge clk);
        #1;
        sys_wgt_valid_i = 1'b0;

        // Wait up to 30 cycles to see if computation starts or hangs
        begin : wait_sys_drain
            int cycles;
            for (cycles = 0; cycles < 30; cycles++) begin
                @(posedge clk);
                #1;
                if (sys_tile_done_o) disable wait_sys_drain;
            end
        end

        if (!sys_tile_done_o) begin
            $display("[FAIL BUG 3] Systolic unit DEADLOCKED! Skewed A/B beats were dropped and GEMM never completed!");
            error_count++;
        end else begin
            $display("[PASS] Systolic unit gracefully handled skewed A/B beats!");
        end

        // -------------------------------------------------------------
        // TEST 4: PWL SiLU discontinuity at x = -0.5 vs -0.499999
        // -------------------------------------------------------------
        $display("\n--- TEST 4: PWL SiLU discontinuity at x = -0.5 ---");
        // We test via FMA stage 6
        // Inject x = -0.5 (0xBF000000)
        fma_valid_i     = 1'b1;
        fma_acc_op_i    = 2'b00; // Reset
        fma_data_fmt_i  = 3'b000;
        fma_act_fn_i    = 2'b11; // SiLU
        fma_act_valid_i = 1'b1;
        fma_a_data_i    = {16{16'hbc00}}; // -1.0
        fma_b_data_i    = {16{16'h3800}}; // +0.5 -> product = -0.5 FP32 (0xBF000000)
        fma_c_bias_i    = '0;
        @(posedge clk);
        #1;
        // Inject x = -0.499999
        // In FP16: -1.0 * 0.4995117 (0x37FF) = -0.4995117 FP32
        fma_a_data_i    = {16{16'hbc00}}; // -1.0
        fma_b_data_i    = {16{16'h37ff}}; // 0.4995117 FP16
        @(posedge clk);
        #1;
        fma_valid_i     = 1'b0;
        fma_act_valid_i = 1'b0;

        repeat (5) @(posedge clk);
        @(posedge clk); #1;
        $display("SiLU(-0.5)      output: 0x%h", fma_res_data_o[31:0]);
        @(posedge clk); #1;
        $display("SiLU(-0.49951)  output: 0x%h", fma_res_data_o[31:0]);
        // If SiLU(-0.5) is 0xbe800000 (-0.25) and SiLU(-0.4995) is ~0xbe000000 (-0.125), that's a 2x jump!

        // -------------------------------------------------------------
        // TEST 5: Negative underflow sign destruction in adder
        // -------------------------------------------------------------
        $display("\n--- TEST 5: Negative underflow sign in fp32_adder ---");
        // -1.0e-40 (0x80000001 subnormal) + -1.0e-40
        add_op_a = 32'h80000001;
        add_op_b = 32'h80000001;
        #10;
        $display("add_res(-subnormal + -subnormal) = 0x%h (Expected: 0x80000000, Actual: 0x%h)", add_res, add_res);
        if (add_res != 32'h80000000) begin
            $display("[FAIL BUG 5] Negative underflow produced positive 0x00000000 instead of 0x80000000!");
            error_count++;
        end

        // Subnormal bypass when op_b = 0
        add_op_a = 32'h00000001; // subnormal
        add_op_b = 32'h00000000;
        #10;
        $display("add_res(subnormal + 0.0) = 0x%h (Expected FTZ: 0x00000000, Actual: 0x%h)", add_res, add_res);
        if (add_res != 32'h00000000) begin
            $display("[FAIL BUG 6] Subnormal input bypassed FTZ and returned raw 0x00000001!");
            error_count++;
        end

        $display("\n===============================================================");
        $display("   ADVERSARIAL STRESS TESTBENCH FINISHED. TOTAL FAILS: %0d", error_count);
        $display("===============================================================");
        $finish;
    end
endmodule
