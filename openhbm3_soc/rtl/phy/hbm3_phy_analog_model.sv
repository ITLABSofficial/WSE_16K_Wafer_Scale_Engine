// ============================================================================
// File: hbm3_phy_analog_model.sv
// Project: Open_HBM3_Controller
// Description:
//   Behavioral analog front-end model for digital simulation verification.
//   Models DDR transmitter pad driver, interconnect delay, and pad muxing.
//   Marked as blackbox during synthesis.
// ============================================================================
`timescale 1ps/1ps
`include "hbm3_800g_defs.svh"

`ifdef SYNTHESIS
(* blackbox *)
`endif
module hbm3_phy_analog_model #(
    parameter int  DQ_LANES     = HBM3_DQ_BITS_PER_CHANNEL,
    // Pad + interconnect delay for digital timing robustness verification
    parameter real PAD_DELAY_PS = 12.0
)(
    input  logic                wck,
    input  logic [DQ_LANES-1:0] dq_rise,
    input  logic [DQ_LANES-1:0] dq_fall,
    input  logic                dq_active,
    // Driven DDR pad waveform: rise bit when WCK is high, fall bit when WCK is low
    output logic [DQ_LANES-1:0] dq_pad
);
`ifndef SYNTHESIS
    logic [DQ_LANES-1:0] dq_mux;
    always_comb dq_mux = dq_active ? (wck ? dq_rise : dq_fall) : '0;
    always @(dq_mux) dq_pad <= #(PAD_DELAY_PS) dq_mux;
    initial dq_pad = '0;
`endif
endmodule
