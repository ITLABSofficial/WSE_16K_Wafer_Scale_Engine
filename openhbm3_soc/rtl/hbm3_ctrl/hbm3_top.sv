// ============================================================================
// File: hbm3_top.sv
// Project: Open_HBM3_Controller
// Description:
//   Full system simulation test harness connecting synthesizable hbm3_ctrl IP
//   to NUM_PC behavioral dram_model instances for end-to-end verification.
// ============================================================================
`timescale 1ns/1ps
`include "hbm3_defs.svh"

module hbm3_top #(
    parameter int NUM_PC = NUM_PC_DEFAULT,
    parameter int AW     = $clog2(NUM_PC) + ROWBITS +
                           NBANK_AW + COLBITS
)(
    input  logic        clk,
    input  logic        rst_n,

    input  logic        req_valid,
    output logic        req_ready,
    input  logic        req_write,
    input  logic [AW-1:0]   req_addr,
    input  logic [255:0]    req_wdata,
    output logic        rsp_valid,
    output logic [255:0]    rsp_rdata,
    output logic [$clog2(NUM_PC)-1:0] rsp_pc,
    output logic        busy,
    output logic [NUM_PC-1:0] ecc_corrected_sticky,
    output logic [NUM_PC-1:0] ecc_uncorrectable_sticky,

    // Simulation fault injection interface (see tb/tb_ecc_fault.sv)
    input  logic [NUM_PC-1:0]         fault_valid,
    input  logic [15*NUM_PC-1:0]      fault_key,
    input  logic [39*NUM_PC-1:0]      fault_flip,

    // Command taps for waveform observation and verification debugging
    output logic [NUM_PC-1:0]         cmd_valid,
    output logic [2*NUM_PC-1:0]       cmd_type,
    output logic [4*NUM_PC-1:0]       cmd_bank,
    output logic [ROWBITS*NUM_PC-1:0] cmd_row,
    output logic [COLBITS*NUM_PC-1:0] cmd_col,
    output logic [32*NUM_PC-1:0]      cmd_wdata,
    output logic [4*NUM_PC-1:0]       cmd_wdbi,
    output logic [7*NUM_PC-1:0]       cmd_wecc,
    output logic [NUM_PC-1:0]         cmd_allbanks,
    output logic [32*NUM_PC-1:0]      cmd_rdata,
    output logic [4*NUM_PC-1:0]       cmd_rdbi,
    output logic [2*NUM_PC-1:0]       cmd_recc_stat
);

    // Sub-channel B (Dual-column DDR): internal controller to DRAM connection
    // baglanti -- hbm3_top'un KENDI disaridan gorunen port listesine
    // eklenmedi (mevcut testbench'ler degismeden calismaya devam eder).
    logic [COLBITS*NUM_PC-1:0] cmd_col_b_i;
    logic [32*NUM_PC-1:0]      cmd_wdata_b_i;
    logic [4*NUM_PC-1:0]       cmd_wdbi_b_i;
    logic [7*NUM_PC-1:0]       cmd_wecc_b_i;
    logic [32*NUM_PC-1:0]      cmd_rdata_b_i;
    logic [4*NUM_PC-1:0]       cmd_rdbi_b_i;
    logic [2*NUM_PC-1:0]       cmd_recc_stat_b_i;

    hbm3_ctrl #(.NUM_PC(NUM_PC)) u_ctrl (
        .clk, .rst_n,
        .req_valid, .req_ready, .req_write, .req_addr, .req_wdata,
        .rsp_valid, .rsp_rdata, .rsp_pc, .busy,
        .ecc_corrected_sticky, .ecc_uncorrectable_sticky,
        .cmd_valid, .cmd_type, .cmd_bank, .cmd_row, .cmd_col,
        .cmd_wdata, .cmd_wdbi, .cmd_wecc, .cmd_allbanks,
        .cmd_rdata (cmd_rdata),
        .cmd_rdbi  (cmd_rdbi),
        .cmd_recc_stat(cmd_recc_stat),
        .cmd_col_b  (cmd_col_b_i),
        .cmd_wdata_b(cmd_wdata_b_i),
        .cmd_wdbi_b (cmd_wdbi_b_i),
        .cmd_wecc_b (cmd_wecc_b_i),
        .cmd_rdata_b(cmd_rdata_b_i),
        .cmd_rdbi_b (cmd_rdbi_b_i),
        .cmd_recc_stat_b(cmd_recc_stat_b_i)
    );

    // Behavioral DRAM instances per pseudo-channel (simulation only)
    genvar g;
    generate for (g = 0; g < NUM_PC; g++) begin : g_dram
        dram_model u_dram (
            .clk, .rst_n,
            .cmd_valid   (cmd_valid[g]),
            .cmd_type    (cmd_type[2*g +: 2]),
            .cmd_bank    (cmd_bank[4*g +: 4]),
            .cmd_row     (cmd_row[g*ROWBITS +: ROWBITS]),
            .cmd_col     (cmd_col[g*COLBITS +: COLBITS]),
            .cmd_wdata   (cmd_wdata[32*g +: 32]),
            .cmd_wdbi    (cmd_wdbi[4*g +: 4]),
            .cmd_wecc    (cmd_wecc[7*g +: 7]),
            .cmd_allbanks(cmd_allbanks[g]),
            .cmd_rdata   (cmd_rdata[32*g +: 32]),
            .cmd_rdbi    (cmd_rdbi[4*g +: 4]),
            .cmd_recc_stat(cmd_recc_stat[2*g +: 2]),
            .cmd_col_b   (cmd_col_b_i[g*COLBITS +: COLBITS]),
            .cmd_wdata_b (cmd_wdata_b_i[32*g +: 32]),
            .cmd_wdbi_b  (cmd_wdbi_b_i[4*g +: 4]),
            .cmd_wecc_b  (cmd_wecc_b_i[7*g +: 7]),
            .cmd_rdata_b (cmd_rdata_b_i[32*g +: 32]),
            .cmd_rdbi_b  (cmd_rdbi_b_i[4*g +: 4]),
            .cmd_recc_stat_b(cmd_recc_stat_b_i[2*g +: 2]),
            .fault_valid (fault_valid[g]),
            .fault_key   (fault_key[15*g +: 15]),
            .fault_flip  (fault_flip[39*g +: 39])
        );
    end endgenerate

endmodule
