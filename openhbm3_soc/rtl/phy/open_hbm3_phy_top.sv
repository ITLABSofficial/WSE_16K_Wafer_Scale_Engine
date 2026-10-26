// ============================================================================
// File: open_hbm3_phy_top.sv
// Project: Open_HBM3_PHY (1.18 TB/s HBM3/HBM3E Full Physical Layer Subsystem)
// Technology: ASAP7 7nm FinFET Predictive PDK (WCK Target: 4.6 GHz / 9.2 Gbps)
// Description:
//   Unified Complete HBM3/HBM3E PHY Subsystem integrating:
//     1. 2:1 Core-to-PHY Stream Gearbox & Gray-Pointer Asynchronous CDC FIFO
//     2. 64-Lane 8:1 DDR Serializer TX Channel with Registered Timing Closure
//     3. 64-Lane 1:8 DDR Deserializer RX Channel with Per-Lane Elastic Deskew
//     4. 2-Phase Link Training Engine (Bit-Slip Alignment + Frame Delimiter Sync)
//     5. Real-Time Hardware Diagnostic Monitors and Parity/Framing Watchdogs
// ============================================================================

`include "hbm3_phy_defs.svh"

module open_hbm3_phy_top #(
    parameter int DQ_LANES       = HBM3_DQ_LANES_PER_CHANNEL,       // 64
    parameter int SER_RATIO      = HBM3_SER_RATIO,                  // 8
    parameter int HOST_DATA_BITS = 256,
    parameter int PHY_DATA_BITS  = 512,
    parameter int ADDR_BITS      = 35
)(
    // Clock & Primary Reset Domains
    input  logic                                 core_clk,         // 2.0 GHz Core Clock
    input  logic                                 core_rst_n,
    input  logic                                 phy_clk,          // 1.15 GHz PHY Clock
    input  logic                                 phy_rst_n,
    input  logic                                 wck,              // 4.60 GHz High-Speed SerDes Clock

    // ------------------------------------------------------------------------
    // Core Domain Host/Controller Interface (256-bit beats @ 2.0 GHz)
    // ------------------------------------------------------------------------
    input  logic                                 core_tx_valid,
    output logic                                 core_tx_ready,
    input  logic                                 core_tx_flush,
    input  logic [ADDR_BITS-1:0]                 core_tx_addr,
    input  logic [HOST_DATA_BITS-1:0]            core_tx_data,

    output logic                                 core_rx_valid,
    output logic [HOST_DATA_BITS-1:0]            core_rx_data,

    // ------------------------------------------------------------------------
    // Physical Micro-Bump / TSV Pad Interface (64 DQ lanes @ 9.2 Gbps DDR)
    // ------------------------------------------------------------------------
    output logic [DQ_LANES-1:0]                  pad_tx_dq_rise,
    output logic [DQ_LANES-1:0]                  pad_tx_dq_fall,
    output logic                                 pad_tx_active,

    input  logic [DQ_LANES-1:0]                  pad_rx_dq_rise,
    input  logic [DQ_LANES-1:0]                  pad_rx_dq_fall,

    // ------------------------------------------------------------------------
    // Link Training & Health Status
    // ------------------------------------------------------------------------
    input  logic                                 train_start,
    output logic                                 train_done,
    output logic                                 train_ok,
    output logic [DQ_LANES-1:0]                  train_bit_locked,
    output logic                                 train_deskew_locked,
    output logic                                 phy_cal_done,
    output logic                                 err_overflow,
    output logic                                 err_underflow
);
    // ------------------------------------------------------------------------
    // Internal Signals
    // ------------------------------------------------------------------------
    // Gearbox to TX
    logic                                 phy_gb_valid;
    logic                                 phy_gb_ready;
    logic [1:0]                           phy_gb_mask;
    logic [2*ADDR_BITS-1:0]               phy_gb_addr;
    logic [PHY_DATA_BITS-1:0]             phy_gb_wdata;

    // Training to TX/RX
    logic                                 tr_align;
    logic [DQ_LANES-1:0]                  tr_bitslip;
    logic                                 tr_arm_deskew;
    logic                                 tr_clr_deskew;
    logic [SER_RATIO-1:0]                 tr_frame_marker;
    logic                                 tr_tx_pat_en;
    logic                                 tr_tx_marker_en;

    // RX to Training / Core
    logic [PHY_DATA_BITS-1:0]             rx_par_data;
    logic                                 rx_par_valid;
    logic                                 rx_all_lanes_ready;
    logic [DQ_LANES-1:0]                  rx_lane_marker_seen;
    logic [DQ_LANES-1:0]                  rx_lane_ready_to_pop;

    // TX Mux: Training Patterns vs. Gearbox Host Payload
    logic [PHY_DATA_BITS-1:0]             tx_mux_data;
    logic                                 tx_mux_valid;
    logic                                 tx_chan_ready;
    logic                                 beat_start;
    logic                                 dq_active;

    // Training pattern generation
    logic                                 train_beat_par_q;
    always_ff @(posedge wck or negedge phy_rst_n) begin
        if (!phy_rst_n) begin
            train_beat_par_q <= 1'b0;
        end else if (tx_chan_ready && tr_tx_pat_en) begin
            train_beat_par_q <= ~train_beat_par_q;
        end
    end

    always_comb begin
        if (tr_tx_marker_en) begin
            // Transmit Sync Frame Delimiter across all 64 lanes
            tx_mux_valid = 1'b1;
            for (int l = 0; l < DQ_LANES; l++) begin
                tx_mux_data[l*SER_RATIO +: SER_RATIO] = HBM3_FRAME_DELIMITER;
            end
        end else if (tr_tx_pat_en) begin
            // Transmit alternating Phase 1 Training Patterns
            tx_mux_valid = 1'b1;
            for (int l = 0; l < DQ_LANES; l++) begin
                tx_mux_data[l*SER_RATIO +: SER_RATIO] = train_beat_par_q ? HBM3_TRAIN_PAT_B : HBM3_TRAIN_PAT_A;
            end
        end else begin
            // Transmit normal Gearbox payload
            tx_mux_valid = phy_gb_valid;
            tx_mux_data  = phy_gb_wdata;
        end
    end

    assign phy_gb_ready = tx_chan_ready && !tr_tx_pat_en && !tr_tx_marker_en;
    assign phy_cal_done = train_ok;

    // ------------------------------------------------------------------------
    // 1. Core-to-PHY 2:1 Gearbox and CDC FIFO
    // ------------------------------------------------------------------------
    hbm3_phy_gearbox_2to1_cdc #(
        .CHANNELS       (1),
        .ADDR_BITS      (ADDR_BITS),
        .HOST_DATA_BITS (HOST_DATA_BITS),
        .PHY_DATA_BITS  (PHY_DATA_BITS)
    ) u_gearbox (
        .core_clk       (core_clk),
        .phy_clk        (phy_clk),
        .core_rst_n     (core_rst_n),
        .phy_rst_n      (phy_rst_n),
        .phy_cal_done   (train_ok),
        .core_valid     (core_tx_valid),
        .core_ready     (core_tx_ready),
        .core_flush     (core_tx_flush),
        .core_addr      (core_tx_addr),
        .core_wdata     (core_tx_data),
        .phy_valid      (phy_gb_valid),
        .phy_ready      (phy_gb_ready),
        .phy_mask       (phy_gb_mask),
        .phy_addr       (phy_gb_addr),
        .phy_wdata      (phy_gb_wdata)
    );

    // ------------------------------------------------------------------------
    // 2. 64-Lane Physical TX Channel (512-bit -> 64 DQ Serializer)
    // ------------------------------------------------------------------------
    hbm3_phy_tx_channel #(
        .DQ_LANES  (DQ_LANES),
        .SER_RATIO (SER_RATIO)
    ) u_tx_chan (
        .wck        (wck),
        .rst_n      (phy_rst_n),
        .par_valid  (tx_mux_valid),
        .par_ready  (tx_chan_ready),
        .par_data   (tx_mux_data),
        .dq_rise    (pad_tx_dq_rise),
        .dq_fall    (pad_tx_dq_fall),
        .dq_active  (pad_tx_active),
        .beat_start (beat_start)
    );

    // ------------------------------------------------------------------------
    // 3. 64-Lane Physical RX Channel (64 DQ Deserializer + Elastic Deskew)
    // ------------------------------------------------------------------------
    hbm3_phy_rx_channel #(
        .DQ_LANES  (DQ_LANES),
        .SER_RATIO (SER_RATIO)
    ) u_rx_chan (
        .wck               (wck),
        .rst_n             (phy_rst_n),
        .dq_rise           (pad_rx_dq_rise),
        .dq_fall           (pad_rx_dq_fall),
        .align             (tr_align),
        .bitslip           (tr_bitslip),
        .arm_deskew        (tr_arm_deskew),
        .clr_deskew        (tr_clr_deskew),
        .bypass_deskew     (!train_deskew_locked),
        .frame_marker      (tr_frame_marker),
        .par_data          (rx_par_data),
        .par_valid         (rx_par_valid),
        .lane_marker_seen  (rx_lane_marker_seen),
        .lane_has_payload (rx_lane_ready_to_pop),
        .all_lanes_ready   (rx_all_lanes_ready),
        .deskew_active_o   (),
        .overflow_err_o    (err_overflow),
        .underflow_err_o   (err_underflow)
    );

    // ------------------------------------------------------------------------
    // 4. 2-Phase Link Training FSM
    // ------------------------------------------------------------------------
    hbm3_phy_training #(
        .DQ_LANES  (DQ_LANES),
        .SER_RATIO (SER_RATIO)
    ) u_training (
        .wck             (wck),
        .rst_n           (phy_rst_n),
        .start           (train_start),
        .rx_valid        (rx_par_valid),
        .rx_data         (rx_par_data),
        .all_lanes_ready (rx_all_lanes_ready),
        .align           (tr_align),
        .bitslip         (tr_bitslip),
        .arm_deskew      (tr_arm_deskew),
        .clr_deskew      (tr_clr_deskew),
        .frame_marker_o  (tr_frame_marker),
        .tx_pattern_en   (tr_tx_pat_en),
        .tx_marker_en    (tr_tx_marker_en),
        .done            (train_done),
        .ok              (train_ok),
        .bit_locked      (train_bit_locked),
        .deskew_locked   (train_deskew_locked)
    );

    // Host loopback / receive slice
    assign core_rx_valid = rx_par_valid;
    assign core_rx_data  = rx_par_data[HOST_DATA_BITS-1:0];

endmodule
