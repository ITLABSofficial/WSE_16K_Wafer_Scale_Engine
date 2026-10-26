// ============================================================================
// File: tb_ara_noc_defect_bypass.sv
// Project: Ara_MultiCore_WSE_HBM3 (Phase 1: Step 3 Verification)
// Technology: ASAP7 7nm FinFET Predictive PDK (Target: 2.0 GHz / 500 ps cycle)
// Architectural Invariants & Verification Standards
//
// Description:
//   Bit-Exact Testbench for ara_noc_defect_bypass (Wafer Defect Tolerance):
//   1. Normal Mode (defect_en = 0): Transparent router transmission.
//   2. Defect Mode (defect_en = 1):
//      - Local NI injection blocked (ready = 0).
//      - Transit West -> East deflection through bypass buffer.
//      - Dynamic Retargeting: packets destined for dead node rewritten to Spare (X, Y).
//      - Telemetry counter verified bit-exact.
// ============================================================================

`timescale 1ps/1ps

module tb_ara_noc_defect_bypass;

    localparam int unsigned FLIT_W = 544;
    localparam int unsigned NODE_X = 2;
    localparam int unsigned NODE_Y = 3;
    localparam int unsigned SPARE_X = 7;
    localparam int unsigned SPARE_Y = 3;

    logic clk = 1'b0;
    always #250 clk = ~clk;

    logic rst_n = 1'b0;

    // Defect configuration
    logic        defect_en = 1'b0;
    logic [5:0]  spare_x   = SPARE_X[5:0];
    logic [5:0]  spare_y   = SPARE_Y[5:0];
    wire         node_bypassed;
    wire  [31:0] bypass_flit_cnt;

    // External mesh ports
    logic [FLIT_W-1:0] north_in_flit = '0;
    logic              north_in_valid = 1'b0;
    wire  [1:0]        north_in_ready;

    logic [FLIT_W-1:0] south_in_flit = '0;
    logic              south_in_valid = 1'b0;
    wire  [1:0]        south_in_ready;

    logic [FLIT_W-1:0] east_in_flit  = '0;
    logic              east_in_valid  = 1'b0;
    wire  [1:0]        east_in_ready;

    logic [FLIT_W-1:0] west_in_flit  = '0;
    logic              west_in_valid  = 1'b0;
    wire  [1:0]        west_in_ready;

    wire  [FLIT_W-1:0] north_out_flit;
    wire               north_out_valid;
    logic [1:0]        north_out_ready = 2'b11;

    wire  [FLIT_W-1:0] south_out_flit;
    wire               south_out_valid;
    logic [1:0]        south_out_ready = 2'b11;

    wire  [FLIT_W-1:0] east_out_flit;
    wire               east_out_valid;
    logic [1:0]        east_out_ready = 2'b11;

    wire  [FLIT_W-1:0] west_out_flit;
    wire               west_out_valid;
    logic [1:0]        west_out_ready = 2'b11;

    // Router internal ports (emulated)
    wire  [FLIT_W-1:0] r_north_in_flit;
    wire               r_north_in_valid;
    logic [1:0]        r_north_in_ready = 2'b11;

    wire  [FLIT_W-1:0] r_south_in_flit;
    wire               r_south_in_valid;
    logic [1:0]        r_south_in_ready = 2'b11;

    wire  [FLIT_W-1:0] r_east_in_flit;
    wire               r_east_in_valid;
    logic [1:0]        r_east_in_ready = 2'b11;

    wire  [FLIT_W-1:0] r_west_in_flit;
    wire               r_west_in_valid;
    logic [1:0]        r_west_in_ready = 2'b11;

    logic [FLIT_W-1:0] r_north_out_flit = '0;
    logic              r_north_out_valid = 1'b0;
    wire  [1:0]        r_north_out_ready;

    logic [FLIT_W-1:0] r_south_out_flit = '0;
    logic              r_south_out_valid = 1'b0;
    wire  [1:0]        r_south_out_ready;

    logic [FLIT_W-1:0] r_east_out_flit  = '0;
    logic              r_east_out_valid  = 1'b0;
    wire  [1:0]        r_east_out_ready;

    logic [FLIT_W-1:0] r_west_out_flit  = '0;
    logic              r_west_out_valid  = 1'b0;
    wire  [1:0]        r_west_out_ready;

    // Local NI
    logic              local_ni_valid = 1'b0;
    wire               local_ni_ready;

    // DUT
    ara_noc_defect_bypass #(
        .FLIT_W(FLIT_W),
        .NODE_X(NODE_X),
        .NODE_Y(NODE_Y)
    ) u_dut (
        .clk              (clk),
        .rst_n            (rst_n),
        .defect_en_i      (defect_en),
        .spare_x_i        (spare_x),
        .spare_y_i        (spare_y),
        .node_bypassed_o  (node_bypassed),
        .bypass_flit_cnt_o(bypass_flit_cnt),

        .north_in_flit_i  (north_in_flit),
        .north_in_valid_i (north_in_valid),
        .north_in_ready_o (north_in_ready),
        .south_in_flit_i  (south_in_flit),
        .south_in_valid_i (south_in_valid),
        .south_in_ready_o (south_in_ready),
        .east_in_flit_i   (east_in_flit),
        .east_in_valid_i  (east_in_valid),
        .east_in_ready_o  (east_in_ready),
        .west_in_flit_i   (west_in_flit),
        .west_in_valid_i  (west_in_valid),
        .west_in_ready_o  (west_in_ready),

        .north_out_flit_o (north_out_flit),
        .north_out_valid_o(north_out_valid),
        .north_out_ready_i(north_out_ready),
        .south_out_flit_o (south_out_flit),
        .south_out_valid_o(south_out_valid),
        .south_out_ready_i(south_out_ready),
        .east_out_flit_o  (east_out_flit),
        .east_out_valid_o (east_out_valid),
        .east_out_ready_i (east_out_ready),
        .west_out_flit_o  (west_out_flit),
        .west_out_valid_o (west_out_valid),
        .west_out_ready_i (west_out_ready),

        .r_north_in_flit_o(r_north_in_flit),
        .r_north_in_valid_o(r_north_in_valid),
        .r_north_in_ready_i(r_north_in_ready),
        .r_south_in_flit_o(r_south_in_flit),
        .r_south_in_valid_o(r_south_in_valid),
        .r_south_in_ready_i(r_south_in_ready),
        .r_east_in_flit_o (r_east_in_flit),
        .r_east_in_valid_o(r_east_in_valid),
        .r_east_in_ready_i(r_east_in_ready),
        .r_west_in_flit_o (r_west_in_flit),
        .r_west_in_valid_o(r_west_in_valid),
        .r_west_in_ready_i(r_west_in_ready),

        .r_north_out_flit_i(r_north_out_flit),
        .r_north_out_valid_i(r_north_out_valid),
        .r_north_out_ready_o(r_north_out_ready),
        .r_south_out_flit_i(r_south_out_flit),
        .r_south_out_valid_i(r_south_out_valid),
        .r_south_out_ready_o(r_south_out_ready),
        .r_east_out_flit_i(r_east_out_flit),
        .r_east_out_valid_i(r_east_out_valid),
        .r_east_out_ready_o(r_east_out_ready),
        .r_west_out_flit_i(r_west_out_flit),
        .r_west_out_valid_i(r_west_out_valid),
        .r_west_out_ready_o(r_west_out_ready),

        .local_ni_valid_i (local_ni_valid),
        .local_ni_ready_o (local_ni_ready)
    );

    int error_count = 0;

    initial begin
        $display("============================================================================");
        $display("  ARA NOC DEFECT BYPASS & RETARGETING BIT-EXACT VERIFICATION");
        $display("============================================================================");

        // Reset
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        #1;
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
        #1;

        // --------------------------------------------------------------------
        // TEST 1: Normal Mode (defect_en = 0)
        // --------------------------------------------------------------------
        $display("\n[TEST 1] Testing Normal Operation (defect_en = 0)...");
        begin
            logic [FLIT_W-1:0] test_flit;
            test_flit = {2'b11, 6'd4, 6'd3, 4'h0, 14'h123, 512'hCAFE_0001};

            if (local_ni_ready !== 1'b1 || node_bypassed !== 1'b0) begin
                $display("  [FATAL ERROR] In normal mode, local_ni_ready must be 1 and node_bypassed must be 0!");
                error_count++;
            end

            // West_In -> Router West_In
            west_in_flit  <= test_flit;
            west_in_valid <= 1'b1;
            #1;
            if (r_west_in_flit !== test_flit || r_west_in_valid !== 1'b1) begin
                $display("  [FATAL ERROR] Router did not receive direct ingress flit in normal mode!");
                error_count++;
            end else begin
                $display("  [PASS] Normal mode transparent routing verified (0 extra latency).");
            end
            @(posedge clk);
            #1;
            west_in_valid <= 1'b0;
        end

        // --------------------------------------------------------------------
        // TEST 2: Defect Mode Isolation & Local Injection Rejection
        // --------------------------------------------------------------------
        $display("\n[TEST 2] Enabling Defect Mode (defect_en = 1)...");
        @(posedge clk);
        #1;
        defect_en = 1'b1;
        #1;

        if (local_ni_ready !== 1'b0 || node_bypassed !== 1'b1) begin
            $display("  [FATAL ERROR] Local NI injection must be blocked when defective!");
            error_count++;
        end else begin
            $display("  [PASS] Local cluster isolated cleanly (local_ni_ready = 0, node_bypassed = 1).");
        end

        // --------------------------------------------------------------------
        // TEST 3: Deflection Routing (West_In -> East_Out Bypass)
        // --------------------------------------------------------------------
        $display("\n[TEST 3] Testing Deflection Bypass (Transit West -> East)...");
        begin
            logic [FLIT_W-1:0] transit_flit;
            // Dest is (5, 3), not this dead node
            transit_flit = {2'b01, 6'd5, 6'd3, 4'h0, 14'h777, 512'hA5A5_5A5A};

            @(posedge clk);
            #1;
            west_in_flit  <= transit_flit;
            west_in_valid <= 1'b1;
            @(posedge clk);
            #1;
            west_in_valid <= 1'b0;

            // Check East_Out after 1 cycle register slice
            if (east_out_valid !== 1'b1) begin
                $display("  [FATAL ERROR] Deflected flit did not appear on East_Out!");
                error_count++;
            end else if (east_out_flit !== transit_flit) begin
                $display("  [FATAL ERROR] Deflected flit corrupted on East_Out!");
                error_count++;
            end else begin
                $display("  [PASS] Transit flit cleanly deflected West -> East with 1-cycle latency slice!");
            end
            @(posedge clk);
        end

        // --------------------------------------------------------------------
        // TEST 4: Dynamic Retargeting to Spare Node
        // --------------------------------------------------------------------
        $display("\n[TEST 4] Testing Dynamic Packet Retargeting to Spare Cluster...");
        begin
            logic [FLIT_W-1:0] dead_target_flit;
            // Dest is THIS dead node (NODE_X=2, NODE_Y=3)
            dead_target_flit = {2'b11, 6'd2, 6'd3, 4'h0, 14'h999, 512'hBEEF_DEAD};

            @(posedge clk);
            #1;
            west_in_flit  <= dead_target_flit;
            west_in_valid <= 1'b1;
            @(posedge clk);
            #1;
            west_in_valid <= 1'b0;

            if (east_out_valid !== 1'b1) begin
                $display("  [FATAL ERROR] Retargeted flit did not exit!");
                error_count++;
            end else if (east_out_flit[541:536] !== SPARE_X[5:0] || east_out_flit[535:530] !== SPARE_Y[5:0]) begin
                $display("  [FATAL ERROR] Flit Dest not retargeted to Spare! Got (%0d, %0d), Expected (%0d, %0d)",
                         east_out_flit[541:536], east_out_flit[535:530], SPARE_X, SPARE_Y);
                error_count++;
            end else if (east_out_flit[511:0] !== 512'hBEEF_DEAD) begin
                $display("  [FATAL ERROR] Payload corrupted during retargeting!");
                error_count++;
            end else begin
                $display("  [PASS] Packet to dead tile successfully retargeted to Spare (%0d, %0d)!",
                         SPARE_X, SPARE_Y);
            end

            @(posedge clk);
        end

        // Check telemetry
        if (bypass_flit_cnt !== 32'd2) begin
            $display("  [FATAL ERROR] Telemetry flit count mismatch! Expected 2, got %0d", bypass_flit_cnt);
            error_count++;
        end else begin
            $display("  [PASS] Defect bypass telemetry counter bit-exact (Count = %0d)!", bypass_flit_cnt);
        end

        repeat (5) @(posedge clk);

        $display("\n============================================================================");
        if (error_count == 0) begin
            $display("  >>> ALL NOC DEFECT BYPASS TESTS PASSED (0 ERRORS)! <<<");
            $display("  Wafer-Scale Defect Isolation, Deflection & Spare Retargeting 100%% Bit-Exact!");
        end else begin
            $display("  >>> TESTBENCH FAILED WITH %0d ERRORS! <<<", error_count);
        end
        $display("============================================================================\n");

        $finish;
    end

endmodule
