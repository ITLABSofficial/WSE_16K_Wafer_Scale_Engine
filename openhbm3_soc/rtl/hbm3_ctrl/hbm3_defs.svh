`ifndef HBM3_DEFS_SVH
`define HBM3_DEFS_SVH
// ============================================================================
// File: hbm3_defs.svh
// Project: Open_HBM3_Controller
// Description:
//   HBM3 Architecture Definitions and Timing Constants (JEDEC JESD238 baseline).
// ============================================================================

    localparam int DW        = 32;    // Pseudo-channel data bus width
    localparam int BL        = 8;     // Burst length (beats) -> 32-byte packet
    /* verilator lint_off UNUSEDPARAM */
    localparam int BURST_B   = BL*DW/8;  // 32 bytes per burst
    /* verilator lint_on UNUSEDPARAM */
    localparam int NBANKS    = 16;    // Banks per pseudo-channel
    localparam int NBANK_AW  = $clog2(NBANKS);      // 4 bank address bits
    localparam int ROWBITS   = 10;
    localparam int COLBITS   = 5;     // Page size = 2^5 * 32B = 1 KB
    localparam int NUM_PC_DEFAULT = 4; // Default simulation pseudo-channels

    // Timing constraints (clock cycles)
    localparam int T_RCD = 4;   // ACT -> RD/WR
    localparam int T_RP  = 4;   // PRE -> ACT
    localparam int T_RRD = 2;   // Bank-to-bank ACT interval
    localparam int T_RTP = 2;   // RD -> PRE interval

    // Refresh interval: default 200 cycles for simulation visibility.
    // Can be overridden at compile time (-DT_REFI_VAL=100000).
    `ifndef T_REFI_VAL
      `define T_REFI_VAL 200
    `endif
    localparam int T_REFI = `T_REFI_VAL;
    localparam int T_RFC  = 8;   // REF duration

    localparam logic [1:0] CMD_ACT = 2'b00, CMD_RD = 2'b01, CMD_WR = 2'b10, CMD_PRE = 2'b11;

`endif
