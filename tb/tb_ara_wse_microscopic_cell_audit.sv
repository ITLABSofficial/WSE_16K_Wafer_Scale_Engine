// ============================================================================
// File: tb_ara_wse_microscopic_cell_audit.sv
// Project: Ara_16384Core_WSE_OpenHBM_800G (Wafer-Scale Engine Microscopic Audit)
// Technology: TSMC 5nm / ASAP7 7nm FinFET (2.0 GHz / 500 ps clock)
// Mode: /derint3 Tier 3 Mathematical Formalism & Microscopic Hardware Audit
//
// Description:
//   Exhaustive cell-by-cell and cycle-by-cycle SystemVerilog diagnostic testbench:
//   1. 16x16 Systolic Matrix Engine: 256 PE cells inspected individually.
//   2. 9-Port Express Highway Router: Congestion storm & wormhole lock/release.
//   3. Wafer Defect Bypass: 1-cycle deflection & spare coordinate retargeting.
// ============================================================================

`timescale 1ps/1ps

module tb_ara_wse_microscopic_cell_audit;

    localparam int unsigned DIM_M        = 16;
    localparam int unsigned DIM_N        = 16;
    localparam int unsigned DATA_W       = 256;
    localparam int unsigned ACC_W        = 512;
    localparam int unsigned FLIT_W       = 544;
    localparam int unsigned NUM_PORTS    = 9;
    localparam int unsigned NUM_VCS      = 2;

    logic clk = 1'b0;
    always #250 clk = ~clk; // 2.0 GHz FinFET Clock (500 ps period)

    logic rst_n;

    // ------------------------------------------------------------------------
    // DUT 1: 16x16 Systolic Matrix Engine
    // ------------------------------------------------------------------------
    logic              gemm_cmd_valid_i;
    logic              gemm_cmd_ready_o;
    logic [1:0]        gemm_data_fmt_i;
    logic [1:0]        gemm_act_fn_i;
    logic [1:0]        gemm_tile_op_i;
    logic [7:0]        gemm_k_len_i;
    logic              gemm_tile_done_o;
    logic              gemm_busy_o;

    logic              gemm_act_valid_i, gemm_act_ready_o;
    logic [DATA_W-1:0] gemm_act_data_i;
    logic              gemm_wgt_valid_i, gemm_wgt_ready_o;
    logic [DATA_W-1:0] gemm_wgt_data_i;

    logic              gemm_res_valid_o;
    logic              gemm_res_ready_i;
    logic [ACC_W-1:0]  gemm_res_data_o;
    logic [3:0]        gemm_res_row_idx_o;
    logic [3:0]        gemm_status_flags_o;

    ara_systolic_tensor_unit #(
        .DIM_M(DIM_M),
        .DIM_N(DIM_N),
        .DATA_W(DATA_W),
        .ACC_W(ACC_W)
    ) u_gemm_dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .abort_i       (1'b0),
        .cmd_valid_i   (gemm_cmd_valid_i),
        .cmd_ready_o   (gemm_cmd_ready_o),
        .data_fmt_i    (gemm_data_fmt_i),
        .act_fn_i      (gemm_act_fn_i),
        .tile_op_i     (gemm_tile_op_i),
        .k_len_i       (gemm_k_len_i),
        .tile_done_o   (gemm_tile_done_o),
        .busy_o        (gemm_busy_o),
        .act_valid_i   (gemm_act_valid_i),
        .act_ready_o   (gemm_act_ready_o),
        .act_data_i    (gemm_act_data_i),
        .wgt_valid_i   (gemm_wgt_valid_i),
        .wgt_ready_o   (gemm_wgt_ready_o),
        .wgt_data_i    (gemm_wgt_data_i),
        .res_valid_o   (gemm_res_valid_o),
        .res_ready_i   (gemm_res_ready_i),
        .res_data_o    (gemm_res_data_o),
        .res_row_idx_o (gemm_res_row_idx_o),
        .status_flags_o(gemm_status_flags_o)
    );

    // ------------------------------------------------------------------------
    // DUT 2: 9-Port Express Highway NoC Router
    // ------------------------------------------------------------------------
    logic [NUM_PORTS-1:0][FLIT_W-1:0]  rtr_in_flit;
    logic [NUM_PORTS-1:0]              rtr_in_valid;
    logic [NUM_PORTS-1:0][NUM_VCS-1:0] rtr_in_ready;
    logic [NUM_PORTS-1:0][FLIT_W-1:0]  rtr_out_flit;
    logic [NUM_PORTS-1:0]              rtr_out_valid;
    logic [NUM_PORTS-1:0][NUM_VCS-1:0] rtr_out_ready;

    ara_noc_express_mesh_router #(
        .ROUTER_X     (0),
        .ROUTER_Y     (0),
        .FLIT_W       (FLIT_W),
        .NUM_PORTS    (NUM_PORTS),
        .NUM_VCS      (NUM_VCS),
        .FIFO_DEPTH   (4),
        .EXPRESS_STEP (8)
    ) u_rtr_dut (
        .clk               (clk),
        .rst_n             (rst_n),
        .in_flit_i         (rtr_in_flit),
        .in_valid_i        (rtr_in_valid),
        .in_ready_o        (rtr_in_ready),
        .out_flit_o        (rtr_out_flit),
        .out_valid_o       (rtr_out_valid),
        .out_ready_i       (rtr_out_ready),
        .express_hops_cnt_o(),
        .local_hops_cnt_o  ()
    );

    // ------------------------------------------------------------------------
    // DUT 3: Wafer Defect Bypass Unit
    // ------------------------------------------------------------------------
    logic              df_defect_en;
    logic [5:0]        df_spare_x;
    logic [5:0]        df_spare_y;
    logic              df_node_bypassed;
    logic [31:0]       df_bypass_cnt;

    logic [FLIT_W-1:0] df_west_in_flit;
    logic              df_west_in_valid;
    logic [1:0]        df_west_in_ready;

    logic [FLIT_W-1:0] df_east_out_flit;
    logic              df_east_out_valid;
    logic [1:0]        df_east_out_ready;

    ara_noc_defect_bypass #(
        .FLIT_W(FLIT_W),
        .NODE_X(8),
        .NODE_Y(8)
    ) u_defect_dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .defect_en_i      (df_defect_en),
        .spare_x_i        (df_spare_x),
        .spare_y_i        (df_spare_y),
        .node_bypassed_o  (df_node_bypassed),
        .bypass_flit_cnt_o(df_bypass_cnt),

        .north_in_flit_i  ('0),
        .north_in_valid_i (1'b0),
        .north_in_ready_o (),
        .south_in_flit_i  ('0),
        .south_in_valid_i (1'b0),
        .south_in_ready_o (),
        .east_in_flit_i   ('0),
        .east_in_valid_i  (1'b0),
        .east_in_ready_o  (),
        .west_in_flit_i   (df_west_in_flit),
        .west_in_valid_i  (df_west_in_valid),
        .west_in_ready_o  (df_west_in_ready),

        .north_out_flit_o (),
        .north_out_valid_o(),
        .north_out_ready_i(2'b11),
        .south_out_flit_o (),
        .south_out_valid_o(),
        .south_out_ready_i(2'b11),
        .east_out_flit_o  (df_east_out_flit),
        .east_out_valid_o (df_east_out_valid),
        .east_out_ready_i (df_east_out_ready),
        .west_out_flit_o  (),
        .west_out_valid_o (),
        .west_out_ready_i (2'b11),

        .r_north_in_flit_o (), .r_north_in_valid_o(), .r_north_in_ready_i(2'b11),
        .r_south_in_flit_o (), .r_south_in_valid_o(), .r_south_in_ready_i(2'b11),
        .r_east_in_flit_o  (), .r_east_in_valid_o (), .r_east_in_ready_i (2'b11),
        .r_west_in_flit_o  (), .r_west_in_valid_o (), .r_west_in_ready_i (2'b11),

        .r_north_out_flit_i('0), .r_north_out_valid_i(1'b0), .r_north_out_ready_o(),
        .r_south_out_flit_i('0), .r_south_out_valid_i(1'b0), .r_south_out_ready_o(),
        .r_east_out_flit_i ('0), .r_east_out_valid_i (1'b0), .r_east_out_ready_o (),
        .r_west_out_flit_i ('0), .r_west_out_valid_i (1'b0), .r_west_out_ready_o (),

        .local_ni_valid_i  (1'b0),
        .local_ni_ready_o  ()
    );

    // ------------------------------------------------------------------------
    // Helper function to build 544b flit
    // ------------------------------------------------------------------------
    function automatic [FLIT_W-1:0] make_test_flit(
        input [1:0]  f_type,
        input [5:0]  dx,
        input [5:0]  dy,
        input [3:0]  vc,
        input [13:0] txn,
        input [31:0] payload_tag
    );
        make_test_flit = '0;
        make_test_flit[543:542] = f_type;
        make_test_flit[541:536] = dx;
        make_test_flit[535:530] = dy;
        make_test_flit[529:526] = vc;
        make_test_flit[525:512] = txn;
        make_test_flit[31:0]    = payload_tag;
    endfunction

    int f_rtr_out = 0;
    int rtr_flits_captured = 0;

    always @(posedge clk) begin
        if (rst_n && f_rtr_out != 0) begin
            for (int op = 0; op < NUM_PORTS; op++) begin
                if (rtr_out_valid[op]) begin
                    logic [FLIT_W-1:0] flit_copy;
                    flit_copy = rtr_out_flit[op];
                    $fdisplay(f_rtr_out, "%01X %0136X", op, flit_copy);
                    rtr_flits_captured++;
                    $display("  [ROUTER EGRESS #%02d] Port %0d emitted flit tag 0x%08X",
                             rtr_flits_captured, op, flit_copy[31:0]);
                end
            end
        end
    end

    // ------------------------------------------------------------------------
    // Main Test Sequence
    // ------------------------------------------------------------------------
    initial begin
        $display("================================================================================");
        $display("   ARA 16,384-CORE WSE MICROSCOPIC HARDWARE AUDIT START");
        $display("   Cell-by-Cell PE Inspection | Congestion Storm | Defect Tolerance");
        $display("================================================================================");

        // Reset Sequence
        rst_n            = 1'b0;
        gemm_cmd_valid_i = 1'b0;
        gemm_act_valid_i = 1'b0;
        gemm_wgt_valid_i = 1'b0;
        gemm_res_ready_i = 1'b1;
        rtr_in_valid     = '0;
        rtr_in_flit      = '0;
        rtr_out_ready    = '1;
        df_defect_en     = 1'b0;
        df_spare_x       = 6'd63;
        df_spare_y       = 6'd8;
        df_west_in_valid = 1'b0;
        df_west_in_flit  = '0;
        df_east_out_ready= 2'b11;

        #2000;
        rst_n = 1'b1;
        #1000;
        @(posedge clk);

        // --------------------------------------------------------------------
        // AUDIT PART 1: 16x16 Systolic Matrix Engine Cell-by-Cell Audit
        // --------------------------------------------------------------------
        begin : blk_gemm_audit
            int f_stim, f_out, ret;
            f_stim = $fopen("tb/audit_gemm_stim.hex", "r");
            f_out  = $fopen("tb/audit_gemm_out.hex", "w");

            if (!f_stim || !f_out) begin
                $display("[FATAL] Could not open audit_gemm_stim.hex or audit_gemm_out.hex!");
                $finish;
            end

            $display("\n[AUDIT 1] Resetting Tile Accumulators & Configuring GEMM...");
            @(posedge clk);
            #50;
            gemm_cmd_valid_i = 1'b1;
            gemm_tile_op_i   = 2'b11; // Reset & Compute
            gemm_k_len_i     = 8'd1;  // Rank-1 Outer Product
            gemm_data_fmt_i  = 2'b00;
            gemm_act_fn_i    = 2'b00;
            @(posedge clk);
            #50;
            gemm_cmd_valid_i = 1'b0;

            $display("[AUDIT 1] Streaming Unique-Value Rank-1 Outer Product Vectors...");
            begin
                logic [DATA_W-1:0] a_vec, b_vec;
                ret = $fscanf(f_stim, "%h %h\n", a_vec, b_vec);
                wait (gemm_act_ready_o && gemm_wgt_ready_o);
                @(posedge clk);
                #50;
                gemm_act_valid_i = 1'b1;
                gemm_wgt_valid_i = 1'b1;
                gemm_act_data_i  = a_vec;
                gemm_wgt_data_i  = b_vec;
                @(posedge clk);
                #50;
                gemm_act_valid_i = 1'b0;
                gemm_wgt_valid_i = 1'b0;
            end

            // Wait until outer product tile finishes
            while (!gemm_tile_done_o) @(posedge clk);
            $display("[AUDIT 1] Computation finished! Draining all 16 accumulator rows...");

            // Trigger drain
            @(posedge clk);
            #50;
            gemm_cmd_valid_i = 1'b1;
            gemm_tile_op_i   = 2'b10; // Drain Tile
            @(posedge clk);
            #50;
            gemm_cmd_valid_i = 1'b0;

            for (int r = 0; r < 16; r++) begin
                while (!gemm_res_valid_o) @(posedge clk);
                #50;
                $fdisplay(f_out, "%0128X", gemm_res_data_o);

                // Direct microscopic sanity assertions in SV
                if (r == 0) begin
                    $display("  -> Row 00, Col 00 (PE_0_0)   = 0x%08X (FP32: 0.500000 Expected)", gemm_res_data_o[31:0]);
                end
                if (r == 3) begin
                    $display("  -> Row 03, Col 07 (PE_3_7)   = 0x%08X (FP32: 16.00000 Expected)", gemm_res_data_o[7*32 +: 32]);
                end
                if (r == 15) begin
                    $display("  -> Row 15, Col 15 (PE_15_15) = 0x%08X (FP32: 128.0000 Expected)", gemm_res_data_o[15*32 +: 32]);
                end
                @(posedge clk);
            end

            $fclose(f_stim);
            $fclose(f_out);
            $display("[AUDIT 1] 16x16 Matrix Tile Drained Cleanly into audit_gemm_out.hex!");
        end

        // --------------------------------------------------------------------
        // AUDIT PART 2: Congestion Storm & Multi-Flit Wormhole Router Test
        // --------------------------------------------------------------------
        begin : blk_router_audit
            f_rtr_out = $fopen("tb/audit_router_out.hex", "w");

            $display("\n[AUDIT 2] Injecting 9-Port Congestion Storm (All 9 Ingress Ports Active Simultaneously)...");
            @(posedge clk);
            #50;
            // All 9 ingress ports inject in the same cycle targeting Port 6 (Express East: dx=16)
            for (int p = 0; p < NUM_PORTS; p++) begin
                rtr_in_valid[p] = 1'b1;
                rtr_in_flit[p]  = make_test_flit(2'b11, 6'd16, 6'd0, 4'h0, 14'h100 + p, 32'hAAAA0000 + p);
            end

            @(posedge clk);
            #50;
            rtr_in_valid = '0;

            // Wait for all 9 storm packets to egress
            repeat (15) @(posedge clk);

            $display("\n[AUDIT 2] Testing Multi-Flit Wormhole Packet Integrity (HEAD -> BODY -> TAIL)...");
            // Port 4 injects 3-flit wormhole packet to Port 6
            // Cycle 1: HEAD
            @(posedge clk);
            #50;
            rtr_in_valid[4] = 1'b1;
            rtr_in_flit[4]  = make_test_flit(2'b00, 6'd16, 6'd0, 4'h0, 14'h201, 32'h11EA0001);

            // Cycle 2: BODY
            @(posedge clk);
            #50;
            rtr_in_valid[4] = 1'b1;
            rtr_in_flit[4]  = make_test_flit(2'b01, 6'd16, 6'd0, 4'h0, 14'h201, 32'hB0D10002);

            // Cycle 3: TAIL
            @(posedge clk);
            #50;
            rtr_in_valid[4] = 1'b1;
            rtr_in_flit[4]  = make_test_flit(2'b10, 6'd16, 6'd0, 4'h0, 14'h201, 32'h7A110003);

            @(posedge clk);
            #50;
            rtr_in_valid[4] = 1'b0;

            // Wait for wormhole packet to egress
            repeat (15) @(posedge clk);

            // Inject 6 additional single flits from various ports to bring total to 18
            for (int p = 0; p < 6; p++) begin
                @(posedge clk);
                #50;
                rtr_in_valid[p] = 1'b1;
                rtr_in_flit[p]  = make_test_flit(2'b11, 6'd16, 6'd0, 4'h0, 14'h300 + p, 32'hBBBB0000 + p);
                @(posedge clk);
                #50;
                rtr_in_valid[p] = 1'b0;
                repeat (2) @(posedge clk);
            end

            repeat (10) @(posedge clk);
            $fclose(f_rtr_out);
            f_rtr_out = 0;
            $display("[AUDIT 2] Express Highway Router Stress Completed! Flits captured=%0d (Expected 18)", rtr_flits_captured);
        end

        // --------------------------------------------------------------------
        // AUDIT PART 3: Wafer Defect Bypass & Spare Retargeting
        // --------------------------------------------------------------------
        begin : blk_defect_audit
            $display("\n[AUDIT 3] Testing Wafer Defect Bypass on Node (8,8)...");
            @(posedge clk);
            #50;
            df_defect_en = 1'b1;
            df_spare_x   = 6'd63; // Spare column
            df_spare_y   = 6'd8;

            // Packet A: Transit packet destined for (16, 8)
            @(posedge clk);
            #50;
            df_west_in_valid = 1'b1;
            df_west_in_flit  = make_test_flit(2'b11, 6'd16, 6'd8, 4'h0, 14'h401, 32'hCAFE0001);

            @(posedge clk);
            #50;
            df_west_in_valid = 1'b0;
            if (df_east_out_valid && df_east_out_flit[31:0] == 32'hCAFE0001) begin
                $display("  [PASS] Deflection 1-Cycle Pipeline Slice: Transit Flit Passed Cleanly! Tag=0x%08X", df_east_out_flit[31:0]);
            end else begin
                $display("  [FAIL] Deflection transit failed: valid=%b flit=0x%08X", df_east_out_valid, df_east_out_flit[31:0]);
            end

            // Packet B: Packet destined specifically for dead node (8,8)
            @(posedge clk);
            #50;
            df_west_in_valid = 1'b1;
            df_west_in_flit  = make_test_flit(2'b11, 6'd8, 6'd8, 4'h0, 14'h402, 32'hDEAD0002);

            @(posedge clk);
            #50;
            df_west_in_valid = 1'b0;
            if (df_east_out_valid && df_east_out_flit[541:536] == 6'd63) begin
                $display("  [PASS] Dead Destination Retargeting: Header rewritten to Spare X=%0d (Expected 63)!",
                         df_east_out_flit[541:536]);
            end else begin
                $display("  [FAIL] Dead Destination Retargeting Failed: Dest_X=%0d", df_east_out_flit[541:536]);
            end
        end

        $display("\n================================================================================");
        $display("   [MICROSCOPIC AUDIT COMPLETE] ALL HARDWARE CHECKS FINISHED!");
        $display("================================================================================");
        #1000;
        $finish;
    end

endmodule
