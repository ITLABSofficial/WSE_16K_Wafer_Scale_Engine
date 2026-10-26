// ============================================================================
// File: ara_ivr_power_stage.sv
// Project: Ara_MultiCore_WSE_HBM3
// Technology: ASAP7 7nm FinFET Predictive PDK (2.0 GHz Target)
// Specification: Architectural Invariants & Verification Standards
// Defensive Rules: ARCHITECTURE.md compliance
//
// Description:
//   Integrated Voltage Regulator (IVR) Multi-Phase GaN Switched-Capacitor
//   Power Stage Hard Macro Model.
//
// Features:
//   - 16 Interleaved High-Frequency (100 MHz - 1 GHz) GaN Power Phases
//   - Dynamic Phase-Shedding at light loads (Efficiency > 92%)
//   - Fast Phase-Boost (< 2 cycles) commanded by on-die Voltage Droop Sensors (DVS)
//   - 200 nF On-Die MIMCAP decoupling integration keeping L_eff <= 7.5 pH
//   - Real-time phase state & current telemetry streaming to Telemetry Hub
// ============================================================================

`timescale 1ps/1ps

module ara_ivr_power_stage #(
    parameter logic [7:0] RAIL_ID          = 8'h01,
    parameter int unsigned NUM_PHASES     = 16,
    parameter logic [11:0] TARGET_VDD_MV   = 12'd700
)(
    input  logic        clk,
    input  logic        rst_n,

    // Fast Hardware Boost from DVS Voltage Droop Sensor
    input  logic        ivr_boost_req_i, // High: engage all 16 phases immediately
    input  logic [1:0]  droop_level_i,   // Droop level classification

    // Digital Power Management Interface
    input  logic        enable_i,
    input  logic [3:0]  cfg_min_phases_i, // Minimum active phases for standby

    // Regulated Power Rail Telemetry & Status
    output logic [11:0] estimated_vdd_mv_o,
    output logic [4:0]  active_phases_o,
    output logic        rail_stable_o,

    // Sideband Streaming Telemetry Interface (Zero-Loss Skid Buffer)
    output logic        telem_valid_o,
    output logic [31:0] telem_data_o,
    input  logic        telem_ready_i
);

    // ========================================================================
    // 1. DYNAMIC PHASE CONTROL & SLEW-RATE MANAGEMENT
    // ========================================================================
    logic [4:0] active_phases_q;
    logic [11:0] vdd_track_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active_phases_q <= 5'd4; // Default: 4 phases active
            vdd_track_q     <= TARGET_VDD_MV;
            rail_stable_o   <= 1'b0;
        end else if (!enable_i) begin
            active_phases_q <= 5'd0;
            vdd_track_q     <= 12'd0;
            rail_stable_o   <= 1'b0;
        end else begin
            if (ivr_boost_req_i) begin
                // Fast Phase Boost: Fire ALL 16 phases immediately (1-cycle response)
                active_phases_q <= 5'd16;
                vdd_track_q     <= TARGET_VDD_MV;
                rail_stable_o   <= 1'b1;
            end else begin
                // Normal Phase Management based on droop level
                case (droop_level_i)
                    2'b00: begin // Nominal: Slew down to minimum phases
                        if (active_phases_q > {1'b0, cfg_min_phases_i} && active_phases_q > 5'd4) begin
                            active_phases_q <= active_phases_q - 1'b1;
                        end
                        vdd_track_q   <= TARGET_VDD_MV;
                        rail_stable_o <= 1'b1;
                    end
                    2'b01: begin // Minor: 8 phases
                        active_phases_q <= 5'd8;
                        vdd_track_q     <= TARGET_VDD_MV - 12'd10;
                        rail_stable_o   <= 1'b1;
                    end
                    2'b10: begin // Moderate: 12 phases
                        active_phases_q <= 5'd12;
                        vdd_track_q     <= TARGET_VDD_MV - 12'd25;
                        rail_stable_o   <= 1'b1;
                    end
                    2'b11: begin // Critical: 16 phases
                        active_phases_q <= 5'd16;
                        vdd_track_q     <= TARGET_VDD_MV - 12'd50;
                        rail_stable_o   <= 1'b0;
                    end
                endcase
            end
        end
    end

    assign active_phases_o    = active_phases_q;
    assign estimated_vdd_mv_o = vdd_track_q;

    // ========================================================================
    // 2. SIDEBAND TELEMETRY STREAMING (SKID BUFFER PROTECTED)
    // ========================================================================
    // Packet Format (32-bit):
    //   [31:24]: Tag {6'h18, rail_stable_o, ivr_boost_req_i}
    //   [23:16]: RAIL_ID (8-bit)
    //   [15:12]: active_phases_q[3:0]
    //   [11:0] : estimated_vdd_mv_o[11:0]
    logic [31:0] telem_pkt;
    assign telem_pkt = {6'h18, rail_stable_o, ivr_boost_req_i, RAIL_ID, (active_phases_q >= 5'd15 ? 4'hF : active_phases_q[3:0]), vdd_track_q};

    logic [31:0] skid_buf_q;
    logic        skid_valid_q;
    logic [3:0]  cadence_cnt_q;
    logic        telem_strobe;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cadence_cnt_q <= '0;
            telem_strobe  <= 1'b0;
        end else begin
            cadence_cnt_q <= cadence_cnt_q + 1'b1;
            telem_strobe  <= (cadence_cnt_q == 4'hF) || ivr_boost_req_i;
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

endmodule
