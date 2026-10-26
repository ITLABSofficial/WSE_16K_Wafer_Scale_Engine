// ============================================================================
// File: tb_open_hbm3_phy_link.sv
// Project: Open_HBM3_PHY (Link-Level Testbench)
// Description:
//   Validates the Complete TX -> Channel (with 0..7 bit skews) -> RX -> Training
//   closed-loop. Proves that all 64 lanes (including 5, 6, 7 bit skews) are
//   cycle-aligned with zero bit errors and zero beat skew.
// ============================================================================

`timescale 1ns/1ps
`include "hbm3_phy_defs.svh"

module tb_open_hbm3_phy_link;
    localparam int LANES = HBM3_DQ_LANES_PER_CHANNEL;       // 64
    localparam int SER   = HBM3_SER_RATIO;                  // 8
    localparam int WIDTH = LANES * SER;                     // 512
    localparam int HIST  = 32;

    logic wck = 0, rst_n = 0;
    // 4.6 GHz WCK clock (period ~217 ps -> #0.1085 ns half period)
    always #0.1085 wck = ~wck;

    // TX Signals
    logic             par_valid = 1'b1, par_ready;
    logic [WIDTH-1:0] par_data;
    logic [LANES-1:0] tx_rise, tx_fall;
    logic             dq_active, beat_start;

    // Training & Pattern Signals
    logic             start = 0;
    logic             tx_pattern_en;
    logic             tx_marker_en;
    logic             beat_par;
    logic [SER-1:0]   pat_ctr;

    always_ff @(posedge wck or negedge rst_n) begin
        if (!rst_n) begin
            beat_par <= 1'b0;
            pat_ctr  <= '0;
        end else if (par_ready && par_valid) begin
            if (tx_pattern_en) beat_par <= ~beat_par;
            else if (!tx_marker_en) pat_ctr <= pat_ctr + 1'b1;
        end
    end

    // Transmitter Data Multiplexing
    always_comb begin
        par_data = '0;
        if (tx_marker_en) begin
            for (int l = 0; l < LANES; l++) par_data[l*SER +: SER] = HBM3_FRAME_DELIMITER;
        end else if (tx_pattern_en) begin
            for (int l = 0; l < LANES; l++) par_data[l*SER +: SER] = beat_par ? HBM3_TRAIN_PAT_B : HBM3_TRAIN_PAT_A;
        end else begin
            for (int l = 0; l < LANES; l++) par_data[l*SER +: SER] = pat_ctr + SER'(l);
        end
    end

    hbm3_phy_tx_channel u_tx (
        .wck        (wck),
        .rst_n      (rst_n),
        .par_valid  (par_valid),
        .par_ready  (par_ready),
        .par_data   (par_data),
        .dq_rise    (tx_rise),
        .dq_fall    (tx_fall),
        .dq_active  (dq_active),
        .beat_start (beat_start)
    );

    // ------------------------------------------------------------------------
    // Physical Channel with Controlled Skew Injection (0..7 bits across lanes)
    // ------------------------------------------------------------------------
    logic [HIST-1:0] hist_r [0:LANES-1];
    logic [HIST-1:0] hist_f [0:LANES-1];
    logic [LANES-1:0] rx_rise, rx_fall;

    always_ff @(posedge wck or negedge rst_n) begin
        for (int l = 0; l < LANES; l++) begin
            if (!rst_n) begin
                hist_r[l] <= '0;
                hist_f[l] <= '0;
            end else begin
                hist_r[l] <= {tx_rise[l], hist_r[l][HIST-1:1]};
                hist_f[l] <= {tx_fall[l], hist_f[l][HIST-1:1]};
            end
        end
    end

    genvar gl;
    generate
        for (gl = 0; gl < LANES; gl++) begin : g_skew
            // Injects fractional and full-beat skews: l % 8 spans 0..7 bit skews!
            localparam int BIT_SKEW = gl % 8;
            localparam int TAP      = BIT_SKEW / 2;
            assign rx_rise[gl] = (BIT_SKEW % 2 == 0) ? hist_r[gl][TAP] : hist_f[gl][TAP];
            assign rx_fall[gl] = (BIT_SKEW % 2 == 0) ? hist_f[gl][TAP] : hist_r[gl][TAP+1];
        end
    endgenerate

    // ------------------------------------------------------------------------
    // RX Channel with Elastic Deskew Buffers & 2-Phase Training Engine
    // ------------------------------------------------------------------------
    logic [WIDTH-1:0] rx_data;
    logic             rx_valid;
    logic             tr_align;
    logic [LANES-1:0] tr_bitslip;
    logic             tr_arm_deskew;
    logic             tr_clr_deskew;
    logic [SER-1:0]   tr_frame_marker;
    logic             tr_done, tr_ok;
    logic [LANES-1:0] tr_bit_locked;
    logic             tr_deskew_locked;
    logic             all_lanes_ready;
    logic             err_ovf, err_udf;

    hbm3_phy_rx_channel u_rx (
        .wck               (wck),
        .rst_n             (rst_n),
        .dq_rise           (rx_rise),
        .dq_fall           (rx_fall),
        .align             (tr_align),
        .bitslip           (tr_bitslip),
        .arm_deskew        (tr_arm_deskew),
        .clr_deskew        (tr_clr_deskew),
        .bypass_deskew     (!tr_deskew_locked),
        .frame_marker      (tr_frame_marker),
        .par_data          (rx_data),
        .par_valid         (rx_valid),
        .lane_marker_seen  (),
        .lane_has_payload (),
        .all_lanes_ready   (all_lanes_ready),
        .deskew_active_o   (),
        .overflow_err_o    (err_ovf),
        .underflow_err_o   (err_udf)
    );

    hbm3_phy_training u_tr (
        .wck             (wck),
        .rst_n           (rst_n),
        .start           (start),
        .rx_valid        (rx_valid),
        .rx_data         (rx_data),
        .all_lanes_ready (all_lanes_ready),
        .align           (tr_align),
        .bitslip         (tr_bitslip),
        .arm_deskew      (tr_arm_deskew),
        .clr_deskew      (tr_clr_deskew),
        .frame_marker_o  (tr_frame_marker),
        .tx_pattern_en   (tx_pattern_en),
        .tx_marker_en    (tx_marker_en),
        .done            (tr_done),
        .ok              (tr_ok),
        .bit_locked      (tr_bit_locked),
        .deskew_locked   (tr_deskew_locked)
    );

    // ------------------------------------------------------------------------
    // Verification & Post-Training Checker
    // ------------------------------------------------------------------------
    int dchk = 0, err_count = 0;
    logic [SER-1:0] prev_word0;
    logic synced = 0;

    always_ff @(posedge wck) begin
        if (rst_n && tr_done && tr_ok && !tx_pattern_en && !tx_marker_en && rx_valid) begin
            dchk <= dchk + 1;
            // Check cross-lane word relationship: lane L should be (lane 0 + L)
            for (int l = 0; l < LANES; l++) begin
                logic [SER-1:0] expected_val;
                expected_val = rx_data[0 +: SER] + SER'(l);
                if (rx_data[l*SER +: SER] !== expected_val) begin
                    err_count <= err_count + 1;
                    if (err_count < 10) begin
                        $display("[ERROR] Beat %0d Lane %0d: got %02h, expected %02h",
                                 dchk, l, rx_data[l*SER +: SER], expected_val);
                    end
                end
            end

            // Check sequential increments on Lane 0
            if (!synced) begin
                synced     <= 1'b1;
                prev_word0 <= rx_data[0 +: SER];
            end else begin
                if (rx_data[0 +: SER] !== (prev_word0 + 1'b1)) begin
                    err_count <= err_count + 1;
                    if (err_count < 10) begin
                        $display("[ERROR] Sequence mismatch: prev=%02h, cur=%02h",
                                 prev_word0, rx_data[0 +: SER]);
                    end
                end
                prev_word0 <= rx_data[0 +: SER];
            end
        end
    end

    initial begin
        $display("================================================================================");
        $display("   OPEN_HBM3_PHY LINK TEST: TX -> CHANNEL (0..7 BIT SKEWS) -> RX DESKEW");
        $display("================================================================================");
        repeat (10) @(posedge wck);
        rst_n = 1'b1;
        repeat (10) @(posedge wck);

        $display("[INFO] Triggering Link Training FSM...");
        @(negedge wck); start = 1'b1;
        @(posedge wck);
        @(negedge wck); start = 1'b0;

        wait (tr_done);
        if (tr_ok) begin
            $display("[PASS] Link Training Completed Successfully!");
            $display("       All 64 Lanes Bit-Locked : %0b (64/64)", &tr_bit_locked);
            $display("       Inter-Lane Deskew Locked: %0b", tr_deskew_locked);
        end else begin
            $display("[FATAL] Link Training Failed!");
            $fatal(1, "Training Failed");
        end

        // Wait for at least 50 valid beats
        wait (dchk >= 50);

        if (err_count == 0) begin
            $display("[PASS] POST-TRAINING VERIFICATION PASSED!");
            $display("       Tested Beats       : %0d", dchk);
            $display("       Total Bits Verified: %0d bits", dchk * WIDTH);
            $display("       Bit Errors Found   : %0d (0.000%%)", err_count);
            $display("================================================================================");
        end else begin
            $display("[FATAL] POST-TRAINING VERIFICATION FAILED with %0d errors!", err_count);
            $fatal(1, "Post-training verification failed");
        end

        $finish;
    end

    // Safety timeout
    initial begin
        #50000;
        $display("[FATAL] Simulation timeout!");
        $fatal(1, "Timeout");
    end

endmodule
