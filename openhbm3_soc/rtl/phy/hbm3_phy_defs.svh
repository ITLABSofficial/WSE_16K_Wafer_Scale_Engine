// ============================================================================
// File: hbm3_phy_defs.svh
// Project: Open_HBM3_PHY (Industry-Standard 1.18 TB/s HBM3/HBM3E Full PHY)
// Technology: ASAP7 7nm FinFET Predictive PDK (WCK Target: 4.6 GHz / 9.2 Gbps)
// Description:
//   Architectural and physical parameters for the Open_HBM3_PHY subsystem.
//   Defines serialization ratios, DQ lane counts, training patterns, and
//   deskew elastic buffer parameters according to JEDEC JESD238B and HBM3E.
// ============================================================================

`ifndef OPEN_HBM3_PHY_DEFS_SVH
`define OPEN_HBM3_PHY_DEFS_SVH

// ----------------------------------------------------------------------------
// PHY Physical & Architectural Constants
// ----------------------------------------------------------------------------
// Number of differential DQ data lanes per physical HBM3 channel
localparam int HBM3_DQ_LANES_PER_CHANNEL        = 64;

// Parallel data width per channel at the PHY-Controller DFI/Gearbox boundary
`ifndef HBM3_PHY_DATA_BITS_PER_CHANNEL_DEF
`define HBM3_PHY_DATA_BITS_PER_CHANNEL_DEF
localparam int HBM3_PHY_DATA_BITS_PER_CHANNEL   = 512;
`endif

// Serialization ratio: 512 bits / 64 lanes = 8 bits per DQ pin per beat
localparam int HBM3_SER_RATIO                   = HBM3_PHY_DATA_BITS_PER_CHANNEL / HBM3_DQ_LANES_PER_CHANNEL; // 8

// Number of WCK cycles per beat (DDR: 2 bits per WCK cycle -> 8 / 2 = 4 WCK cycles)
localparam int HBM3_WCK_CYCLES_PER_BEAT         = HBM3_SER_RATIO / 2; // 4

// Elastic Deskew Buffer Depth (accommodates up to 3 beats = 24 bits of inter-lane skew)
localparam int HBM3_ELASTIC_BUF_DEPTH           = 4;

// ----------------------------------------------------------------------------
// Link Training & Framing Constants
// ----------------------------------------------------------------------------
// Phase 1 Bit Alignment Patterns (2-beat rotation breaking symmetry)
localparam logic [7:0] HBM3_TRAIN_PAT_A         = 8'hA5; // 1010_0101
localparam logic [7:0] HBM3_TRAIN_PAT_B         = 8'h39; // 0011_1001

// Phase 2 Beat Deskew Frame Delimiter Marker
localparam logic [7:0] HBM3_FRAME_DELIMITER     = 8'h7E; // 0111_1110 (Unique framing marker)

// Link Training settle cycles after bitslip pulse
localparam int HBM3_TRAIN_SETTLE_CYCLES         = 3;

// Max training iterations before lane declared defective
localparam int HBM3_MAX_BITSLIP_ATTEMPTS        = 24;

// ----------------------------------------------------------------------------
// Frequency and Bandwidth Target Specification
// ----------------------------------------------------------------------------
// WCK Clock Frequency    : 4.60 GHz (Period = 217.39 ps)
// Data Rate per DQ Pin   : 9.20 Gbps (DDR on 4.6 GHz)
// Bandwidth per Channel  : 64 pins * 9.2 Gbps / 8 = 73.6 GB/s
// Bandwidth for 16 Ch    : 16 * 73.6 GB/s = 1177.6 GB/s (1.1776 TB/s raw HBM3E)
// Core Domain Frequency  : 2.00 GHz (500 ps cycle)
// PHY Domain Frequency   : 1.15 GHz (869.56 ps cycle = 4 WCK cycles)

`endif // OPEN_HBM3_PHY_DEFS_SVH
