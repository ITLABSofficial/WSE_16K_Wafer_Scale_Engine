// ============================================================================
// File: tb_deep_numerical_matrix_fma_audit.sv
// Project: Ara_MultiCore_WSE_HBM3 (16x16 Systolic Matrix Unit & True-FMA)
// Description:
//   Exhaustive Multi-Matrix Bit-Exact Verification Testbench.
//   Verifies 24 comprehensive matrix test suites (Hilbert, Subnormal,
//   Catastrophic Cancellation, RNE Ties-To-Even, Random Dense GEMMs)
//   across 98,304 FMA operations and 6,144 matrix accumulator cells.
//   Directly inspects raw hex words and bitfields (Sign, Exp, Mantissa).
// ============================================================================

`timescale 1ps/1ps

module tb_deep_numerical_matrix_fma_audit;

    parameter int unsigned DIM_M  = 16;
    parameter int unsigned DIM_N  = 16;
    parameter int unsigned DATA_W = 256;
    parameter int unsigned ACC_W  = 512;
    parameter int unsigned TOTAL_TESTS = 24;

    logic clk;
    logic rst_n;
    logic abort_i;

    logic cmd_valid_i;
    wire  cmd_ready_o;
    logic [2:0] data_fmt_i;
    logic [1:0] act_fn_i;
    logic [1:0] tile_op_i;
    logic [7:0] k_len_i;
    wire  tile_done_o;
    wire  busy_o;

    logic act_valid_i;
    wire  act_ready_o;
    logic [DATA_W-1:0] act_data_i;

    logic wgt_valid_i;
    wire  wgt_ready_o;
    logic [DATA_W-1:0] wgt_data_i;

    wire  res_valid_o;
    logic res_ready_i;
    wire  [ACC_W-1:0] res_data_o;
    wire  [3:0] res_row_idx_o;
    wire  [3:0] status_flags_o;

    // 2.0 GHz clock (500 ps period)
    initial begin
        clk = 1'b0;
        forever #250 clk = ~clk;
    end

    ara_systolic_tensor_unit #(
        .DIM_M(DIM_M),
        .DIM_N(DIM_N),
        .DATA_W(DATA_W),
        .ACC_W(ACC_W)
    ) dut (
        .clk(clk),
        .rst_n(rst_n),
        .abort_i(abort_i),
        .cmd_valid_i(cmd_valid_i),
        .cmd_ready_o(cmd_ready_o),
        .data_fmt_i(data_fmt_i),
        .act_fn_i(act_fn_i),
        .tile_op_i(tile_op_i),
        .k_len_i(k_len_i),
        .tile_done_o(tile_done_o),
        .busy_o(busy_o),
        .act_valid_i(act_valid_i),
        .act_ready_o(act_ready_o),
        .act_data_i(act_data_i),
        .wgt_valid_i(wgt_valid_i),
        .wgt_ready_o(wgt_ready_o),
        .wgt_data_i(wgt_data_i),
        .res_valid_o(res_valid_o),
        .res_ready_i(res_ready_i),
        .res_data_o(res_data_o),
        .res_row_idx_o(res_row_idx_o),
        .status_flags_o(status_flags_o)
    );

    // Memory for stimulus and golden data
    // 24 tests * 16 k-beats * 2 lines (act, wgt) = 768 lines of 256-bit
    logic [255:0] stim_mem [0:767];
    // 24 tests * 16 rows = 384 lines of 512-bit
    logic [511:0] gold_mem [0:383];

    int stim_ptr = 0;
    int gold_ptr = 0;
    int total_cells_tested = 0;
    int total_cells_passed = 0;
    int total_cells_failed = 0;
    int total_bits_mismatched = 0;
    int out_file;

    initial begin
        $display("================================================================================");
        $display("   STARTING MULTI-MATRIX BIT-EXACT NUMERICAL & FMA AUDIT TESTBENCH");
        $display("   Testing 24 Matrix Suites (Hilbert, Subnormal, Cancellation, RNE, Random GEMMs)");
        $display("   Total Volume: 6,144 Accumulator Cells (98,304 Parallel FMA Contractions)");
        $display("================================================================================");

        $readmemh("tb/deep_matrix_stimulus.hex", stim_mem);
        $readmemh("tb/deep_matrix_golden.hex", gold_mem);
        out_file = $fopen("tb/deep_matrix_rtl_output.hex", "w");

        rst_n       = 1'b0;
        abort_i     = 1'b0;
        cmd_valid_i = 1'b0;
        data_fmt_i  = 3'b000; // FP16
        act_fn_i    = 2'b00; // None
        tile_op_i   = 2'b00;
        k_len_i     = 8'd16;
        act_valid_i = 1'b0;
        wgt_valid_i = 1'b0;
        act_data_i  = '0;
        wgt_data_i  = '0;
        res_ready_i = 1'b1;

        #2000;
        @(posedge clk);
        #50 rst_n = 1'b1;
        @(posedge clk);
        #50;

        for (int t = 0; t < TOTAL_TESTS; t++) begin
            string test_name;
            int test_pass;
            int test_fail;

            test_pass = 0;
            test_fail = 0;

            case (t)
                0: test_name = "Hilbert Matrix (Ill-Conditioned)";
                1: test_name = "Subnormal / Denormal FP16 Arithmetic";
                2: test_name = "Catastrophic Cancellation Alternating Signs";
                3: test_name = "IEEE-754 RNE Ties-To-Even Bit Audit";
                default: $sformat(test_name, "Random Dense GEMM %0d", t - 3);
            endcase

            $display("\n--- [TEST %0d/%0d] %s ---", t+1, TOTAL_TESTS, test_name);

            // Step 1: Launch GEMM Computation (Reset & Compute Outer Product: tile_op = 2'b11)
            wait (cmd_ready_o);
            @(posedge clk);
            #50;
            cmd_valid_i = 1'b1;
            tile_op_i   = 2'b11; // Reset & Compute
            k_len_i     = 8'd16;
            @(posedge clk);
            #50;
            cmd_valid_i = 1'b0;

            // Step 2: Feed 16 Beats of Matrix A and Matrix B
            for (int k = 0; k < 16; k++) begin
                wait (act_ready_o && wgt_ready_o);
                @(posedge clk);
                #50;
                act_valid_i = 1'b1;
                wgt_valid_i = 1'b1;
                act_data_i  = stim_mem[stim_ptr];
                wgt_data_i  = stim_mem[stim_ptr + 1];
                stim_ptr    = stim_ptr + 2;
                @(posedge clk);
                #50;
                act_valid_i = 1'b0;
                wgt_valid_i = 1'b0;
            end

            // Step 3: Wait for Contraction Completion
            while (!tile_done_o) @(posedge clk);

            // Step 4: Drain Matrix Accumulator Tile
            @(posedge clk);
            #50;
            cmd_valid_i = 1'b1;
            tile_op_i   = 2'b10; // Drain Tile
            @(posedge clk);
            #50;
            cmd_valid_i = 1'b0;

            // Step 5: Read and Inspect all 16 rows (256 cells) bit-by-bit
            for (int r = 0; r < 16; r++) begin
                logic [511:0] exp_row;
                wait (res_valid_o);
                exp_row = gold_mem[gold_ptr];
                gold_ptr = gold_ptr + 1;

                // Log raw output to hex file
                $fdisplay(out_file, "%128H", res_data_o);

                for (int c = 0; c < 16; c++) begin
                    logic [31:0] rtl_word;
                    logic [31:0] exp_word;
                    logic [31:0] diff;

                    rtl_word = res_data_o[c*32 +: 32];
                    exp_word = exp_row[c*32 +: 32];
                    diff     = rtl_word ^ exp_word;

                    total_cells_tested++;
                    if (diff == 32'h00000000) begin
                        test_pass++;
                        total_cells_passed++;
                    end else begin
                        // Inspect bit difference: check if within 1-ULP rounding tolerance
                        // or exact cancellation difference
                        int popcnt;
                        popcnt = 0;
                        for (int b = 0; b < 32; b++) if (diff[b]) popcnt++;
                        total_bits_mismatched += popcnt;

                        // Detailed Bit Inspection
                        if (test_fail < 5) begin
                            $display("  [BIT-INSPECT CELL (%0d,%0d)] RTL=0x%08X (s=%b exp=%0d mant=0x%06X) | EXP=0x%08X (s=%b exp=%0d mant=0x%06X) | XOR=0x%08X (diff bits=%0d)",
                                r, c,
                                rtl_word, rtl_word[31], rtl_word[30:23], rtl_word[22:0],
                                exp_word, exp_word[31], exp_word[30:23], exp_word[22:0],
                                diff, popcnt);
                        end
                        test_fail++;
                        total_cells_failed++;
                    end
                end
                @(posedge clk);
                #50;
            end

            if (test_fail == 0) begin
                $display("  -> All 256 Cells Passed Bit-Exact Check! (256/256 cells, 100.0%% PASS)");
            end else begin
                $display("  -> Pass: %0d/256 cells, Discrepancies: %0d/256 cells", test_pass, test_fail);
            end
        end

        $fclose(out_file);

        $display("\n================================================================================");
        $display("   MULTI-MATRIX BIT-EXACT AUDIT SUMMARY");
        $display("   Total Matrix Contractions Tested: %0d", TOTAL_TESTS);
        $display("   Total Accumulator Cells Inspected: %0d", total_cells_tested);
        $display("   Bit-Exact Matched Cells:           %0d (%.2f%%)", total_cells_passed, (total_cells_passed * 100.0) / total_cells_tested);
        $display("   Mismatched Cells:                  %0d", total_cells_failed);
        $display("   Total Bit Differences:             %0d bits", total_bits_mismatched);
        $display("================================================================================");

        if (total_cells_failed == 0) begin
            $display("   >>> ALL 24 MATRIX TEST SUITES PASSED BIT-EXACT CHECK (0 ERRORS)! <<<\n");
        end else begin
            $display("   >>> BIT DISCREPANCIES DETECTED IN SIMULATION! <<<\n");
        end

        $finish;
    end

endmodule
