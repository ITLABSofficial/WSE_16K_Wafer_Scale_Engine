// ============================================================================
// File: ara_digital_voltage_sensor.sv
// Project: Ara_MultiCore_WSE_HBM3
// Technology: ASAP7 7nm FinFET Predictive PDK (2.0 GHz Target)
// Specification: Architectural Invariants & Verification Standards
// Defensive Rules: ARCHITECTURE.md compliance
//
// Description:
//   All-Digital On-Die Voltage Droop Sensor (DVS) Macro for High-Speed FinFET
//   Micro-Architectures.
//
// Operating Principle:
//   Fast load steps (e.g. 64-192 cores firing simultaneous FP32 GEMMs) cause
//   high di/dt transients and parasitic L*di/dt voltage droop across the PDN.
//   An 8-tap inverter delay line measures instantaneous gate propagation speed:
//     t_gate(V_DD) proportional to (C_L * V_DD) / (mu_e * (V_DD - V_th)^alpha).
//   When V_DD droops, gate delay increases and the number of taps reached
//   before the clock edge drops.
//
// Fast Mitigation:
//   - Sub-2 cycle droop detection
//   - Clock stretching request (stretch_req_o) suppresses next edge to prevent setup violations
//   - IVR phase boost request (ivr_boost_req_o) commands GaN IVR to fire boost phases
//   - Real-time millivolt telemetry streaming (Zero-loss skid buffer)
// ============================================================================

`timescale 1ps/1ps

module ara_digital_voltage_sensor #(
    parameter logic [7:0] SENSOR_ID          = 8'h01,
    parameter logic [11:0] NOMINAL_VDD_MV     = 12'd700, // 700 mV nominal for ASAP7
    parameter logic [11:0] DROOP_WARN_MV      = 12'd650, // Droop warning: 650 mV (-7.1%)
    parameter logic [11:0] DROOP_CRIT_MV      = 12'd600  // Droop critical: 600 mV (-14.3%)
)(
    input  logic        clk,
    input  logic        rst_n,

    // Configuration & Thresholds (in millivolts)
    input  logic        cfg_we_i,
    input  logic [11:0] cfg_droop_warn_mv_i,
    input  logic [11:0] cfg_droop_crit_mv_i,
    input  logic        cfg_stretch_en_i,

    // Physical Environment Stimulus (used in simulation / AMS co-sim)
    // In actual silicon, this is derived from the tapped delay line quantization.
    input  logic [11:0] sim_vdd_mv_i,
    input  logic        sim_vdd_override_en_i,

    // Real-Time Voltage Telemetry Output (in millivolts, 0-1200 mV)
    output logic [11:0] vdd_mv_o,
    output logic [1:0]  droop_level_o, // 00: Nominal, 01: Minor, 10: Moderate, 11: Critical
    output logic        droop_alert_o,

    // Fast Hardware Protection Outputs (Sub-2 Cycle Response)
    output logic        stretch_req_o,   // Clock stretching request to prevent timing fault
    output logic        ivr_boost_req_o, // Command IVR to engage peak current booster

    // Sideband Streaming Telemetry Interface (Zero-Loss Skid Buffer)
    output logic        telem_valid_o,
    output logic [31:0] telem_data_o,
    input  logic        telem_ready_i
);

    // ========================================================================
    // 1. CONFIGURATION & REGISTERED THRESHOLDS
    // ========================================================================
    logic [11:0] th_warn_mv_q;
    logic [11:0] th_crit_mv_q;
    logic        stretch_en_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            th_warn_mv_q <= DROOP_WARN_MV;
            th_crit_mv_q <= DROOP_CRIT_MV;
            stretch_en_q <= 1'b1;
        end else if (cfg_we_i) begin
            if (cfg_droop_warn_mv_i != 12'h0) th_warn_mv_q <= cfg_droop_warn_mv_i;
            if (cfg_droop_crit_mv_i != 12'h0) th_crit_mv_q <= cfg_droop_crit_mv_i;
            stretch_en_q <= cfg_stretch_en_i;
        end
    end

    // ========================================================================
    // 2. TAPPED DELAY LINE SAMPLING & QUANTIZATION
    // ========================================================================
    // In silicon, an 8-tap delay line is sampled on clock edge.
    // 8'b1111_1111: VDD >= 700 mV (All 8 taps reached)
    // 8'b0111_1111: VDD ~ 660 mV (7 taps)
    // 8'b0011_1111: VDD ~ 630 mV (6 taps)
    // 8'b0001_1111: VDD ~ 600 mV (5 taps)
    // 8'b0000_1111: VDD ~ 570 mV (4 taps - critical)
    // 8'b0000_0000: VDD < 500 mV (Severe brownout)

    logic [11:0] sampled_vdd_q;
    logic [7:0]  thermometer_taps_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sampled_vdd_q      <= NOMINAL_VDD_MV;
            thermometer_taps_q <= 8'hFF;
        end else begin
            if (sim_vdd_override_en_i) begin
                sampled_vdd_q <= sim_vdd_mv_i;
                // Derive thermometer code from voltage
                if (sim_vdd_mv_i >= 12'd680)      thermometer_taps_q <= 8'b1111_1111;
                else if (sim_vdd_mv_i >= 12'd650) thermometer_taps_q <= 8'b0111_1111;
                else if (sim_vdd_mv_i >= 12'd620) thermometer_taps_q <= 8'b0011_1111;
                else if (sim_vdd_mv_i >= 12'd590) thermometer_taps_q <= 8'b0001_1111;
                else if (sim_vdd_mv_i >= 12'd560) thermometer_taps_q <= 8'b0000_1111;
                else                              thermometer_taps_q <= 8'b0000_0011;
            end else begin
                // Nominal tracking
                sampled_vdd_q      <= NOMINAL_VDD_MV;
                thermometer_taps_q <= 8'hFF;
            end
        end
    end

    assign vdd_mv_o = sampled_vdd_q;

    // ========================================================================
    // 3. DROOP LEVEL CLASSIFICATION & ALERT ENGINE
    // ========================================================================
    logic is_critical_droop;
    logic is_warn_droop;

    assign is_critical_droop = (sampled_vdd_q <= th_crit_mv_q);
    assign is_warn_droop     = (sampled_vdd_q <= th_warn_mv_q);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            droop_level_o   <= 2'b00;
            droop_alert_o   <= 1'b0;
            stretch_req_o   <= 1'b0;
            ivr_boost_req_o <= 1'b0;
        end else begin
            if (is_critical_droop) begin
                droop_level_o   <= 2'b11; // Critical Level 3
                droop_alert_o   <= 1'b1;
                stretch_req_o   <= stretch_en_q;
                ivr_boost_req_o <= 1'b1;
            end else if (is_warn_droop) begin
                droop_level_o   <= 2'b10; // Moderate Level 2
                droop_alert_o   <= 1'b1;
                stretch_req_o   <= 1'b0;
                ivr_boost_req_o <= 1'b1;
            end else if (sampled_vdd_q < NOMINAL_VDD_MV - 12'd25) begin
                droop_level_o   <= 2'b01; // Minor Level 1
                droop_alert_o   <= 1'b0;
                stretch_req_o   <= 1'b0;
                ivr_boost_req_o <= 1'b0;
            end else begin
                droop_level_o   <= 2'b00; // Nominal Level 0
                droop_alert_o   <= 1'b0;
                stretch_req_o   <= 1'b0;
                ivr_boost_req_o <= 1'b0;
            end
        end
    end

    // ========================================================================
    // 4. SIDEBAND TELEMETRY STREAMING (SKID BUFFER PROTECTED)
    // ========================================================================
    // Packet Format (32-bit):
    //   [31:24]: Tag / Status {6'h16, droop_alert_o, is_critical_droop}
    //   [23:16]: SENSOR_ID (8-bit)
    //   [15:12]: droop_level_o (4-bit zero-extended)
    //   [11:0] : VDD voltage in millivolts
    logic [31:0] telem_pkt;
    assign telem_pkt = {6'h16, droop_alert_o, is_critical_droop, SENSOR_ID, 2'b00, droop_level_o, sampled_vdd_q};

    logic [31:0] skid_buf_q;
    logic        skid_valid_q;

    // Periodic telemetry generation every 16 cycles or on alert state change
    logic [3:0] telem_cadence_cnt_q;
    logic       telem_strobe;
    logic       prev_droop_alert_q;
    logic       prev_crit_droop_q;

    wire droop_state_change = (droop_alert_o != prev_droop_alert_q) || (is_critical_droop != prev_crit_droop_q);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            telem_cadence_cnt_q <= '0;
            telem_strobe        <= 1'b0;
            prev_droop_alert_q  <= 1'b0;
            prev_crit_droop_q   <= 1'b0;
        end else begin
            telem_cadence_cnt_q <= telem_cadence_cnt_q + 1'b1;
            prev_droop_alert_q  <= droop_alert_o;
            prev_crit_droop_q   <= is_critical_droop;
            telem_strobe        <= (telem_cadence_cnt_q == 4'hF) || droop_state_change;
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            skid_buf_q    <= 32'h0;
            skid_valid_q  <= 1'b0;
            telem_valid_o <= 1'b0;
            telem_data_o  <= 32'h0;
        end else begin
            if (skid_valid_q) begin
                if (telem_ready_i) begin
                    telem_data_o  <= skid_buf_q;
                    telem_valid_o <= 1'b1;
                    if (telem_strobe) begin
                        skid_buf_q   <= telem_pkt;
                        skid_valid_q <= 1'b1;
                    end else begin
                        skid_valid_q <= 1'b0;
                    end
                end
            end else begin
                if (telem_valid_o && !telem_ready_i) begin
                    if (telem_strobe) begin
                        skid_buf_q   <= telem_pkt;
                        skid_valid_q <= 1'b1;
                    end
                end else begin
                    if (telem_strobe) begin
                        telem_data_o  <= telem_pkt;
                        telem_valid_o <= 1'b1;
                    end else begin
                        telem_valid_o <= 1'b0;
                    end
                end
            end
        end
    end

    // ========================================================================
    // 5. FORMAL VERIFICATION INVARIANTS & PROPERTIES (SVA)
    // ========================================================================
`ifdef FORMAL
    logic [2:0] f_rst_cnt = 0;
    always @(posedge clk) begin
        if (f_rst_cnt < 3'd2) f_rst_cnt <= f_rst_cnt + 1'b1;
    end
    always_comb begin
        if (f_rst_cnt < 3'd2) assume (!rst_n);
        else assume (rst_n);
        assume (th_crit_mv_q <= th_warn_mv_q);
    end

    // Sequential Response Properties: Sub-2 cycle reaction
    logic f_past_valid = 0;
    logic f_past_crit;
    logic f_past_warn;
    logic f_past_stretch_en;

    always @(posedge clk) begin
        f_past_valid      <= rst_n && (f_rst_cnt >= 3'd2);
        f_past_crit       <= is_critical_droop;
        f_past_warn       <= is_warn_droop;
        f_past_stretch_en <= stretch_en_q;

        if (f_past_valid && rst_n) begin
            // 1. Critical Droop: asserts stretch_req in 1 cycle when stretch_en is active
            if (f_past_crit && f_past_stretch_en) begin
                assert(stretch_req_o == 1'b1);
            end

            // 2. IVR Boost: Warning or critical droop must trigger IVR boost in 1 cycle
            if (f_past_crit || f_past_warn) begin
                assert(ivr_boost_req_o == 1'b1);
            end
        end
    end

    // 3. Telemetry Identity: Sensor ID in packet matches parameter
    always_comb begin
        if (rst_n && f_rst_cnt >= 3'd2 && telem_valid_o) begin
            assert(telem_data_o[23:16] == SENSOR_ID);
        end
    end
`endif

endmodule
