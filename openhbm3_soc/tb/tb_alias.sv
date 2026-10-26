`timescale 1ns/1ps
// ============================================================================
// File: tb_alias.sv
// Project: Open_HBM3_Controller
// Description:
//   Negative test verifying the dram_model address aliasing detector triggers
//   when distinct rows map to the same storage index under reduced RSTOR.
//   PASS CRITERION: At least one "[DRAM-ERROR] ... ADDRESS ALIASING COLLISION" emitted.
// ============================================================================
`include "hbm3_defs.svh"

module tb_alias;
    logic clk = 0, rst_n;
    always #5 clk = ~clk;

    localparam int NUM_PC = 4;
    localparam int AW     = $clog2(NUM_PC) + ROWBITS + NBANK_AW + COLBITS;
    localparam int RSTOR  = 6;      // Must match dram_model

    logic        req_valid = 0, req_ready, req_write;
    logic [AW-1:0]   req_addr;
    logic [255:0]    req_wdata;
    logic        rsp_valid, busy;
    logic [255:0]    rsp_rdata;
    logic [$clog2(NUM_PC)-1:0] rsp_pc;

    hbm3_top #(.NUM_PC(NUM_PC)) dut (
        .clk, .rst_n,
        .fault_valid('0), .fault_key('0), .fault_flip('0),
        .req_valid, .req_ready, .req_write, .req_addr, .req_wdata,
        .rsp_valid, .rsp_rdata, .rsp_pc, .busy,
        .cmd_valid(), .cmd_type(), .cmd_bank(), .cmd_row(), .cmd_col(),
        .cmd_wdata(), .cmd_wdbi(), .cmd_allbanks(), .cmd_rdata(), .cmd_rdbi()
    );

    function automatic logic [AW-1:0] addr_of(input int bank, input int row);
        logic [AW-1:0] a;
        a  = '0;
        a |= (AW'(bank)) << COLBITS;
        a |= (AW'(row))  << (COLBITS + NBANK_AW);
        return a;
    endfunction

    task automatic wr(input int bank, input int row, input logic [255:0] d);
        req_valid = 1; req_write = 1;
        req_addr = addr_of(bank, row); req_wdata = d;
        do @(posedge clk); while (!req_ready);
        #1; req_valid = 0;
        while (busy) @(posedge clk);
    endtask

    initial begin
        rst_n = 0; repeat(4) @(posedge clk); rst_n = 1; repeat(2) @(posedge clk);

        // Same bank + same column, identical lower RSTOR bits on two distinct rows
        $display("TB_ALIAS: rows %0d and %0d map to the same storage index (RSTOR=%0d)",
                 1, 1 + (1<<RSTOR), RSTOR);
        wr(3, 1,              256'hAAAA_AAAA);
        wr(3, 1 + (1<<RSTOR), 256'hBBBB_BBBB);   // Collision triggered here

        repeat(20) @(posedge clk);
        $display("TB_ALIAS: finished (ADDRESS ALIASING COLLISION expected above)");
        $finish;
    end

    initial begin
        #500_000;
        $display("TB_ALIAS: TIMEOUT");
        $finish;
    end
endmodule
