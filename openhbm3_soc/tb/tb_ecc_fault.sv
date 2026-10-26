`timescale 1ns/1ps
// END-TO-END ECC verification: perform writes to DRAM model, inject intentional
// 1-bit and 2-bit faults via FAULT_INJECT port, read back, and verify behavior:
//   1 bit  -> silently corrected, host receives clean data,
//             pc_channel asserts sticky corrected flag
//   2 bit  -> uncorrectable, sticky uncorrectable flag asserts
// Negative test validating complete data path ECC hardware invariants.
`include "hbm3_defs.svh"

module tb_ecc_fault;
    logic clk = 0, rst_n;
    always #5 clk = ~clk;

    localparam int NUM_PC = 4;
    localparam int AW     = $clog2(NUM_PC) + ROWBITS + NBANK_AW + COLBITS;

    logic        req_valid = 0, req_ready, req_write;
    logic [AW-1:0]   req_addr;
    logic [255:0]    req_wdata;
    logic        rsp_valid, busy;
    logic [255:0]    rsp_rdata;
    logic [$clog2(NUM_PC)-1:0] rsp_pc;
    logic [NUM_PC-1:0] ecc_corrected_sticky, ecc_uncorrectable_sticky;

    logic [NUM_PC-1:0]    fault_valid = 0;
    logic [15*NUM_PC-1:0] fault_key   = 0;
    logic [39*NUM_PC-1:0] fault_flip  = 0;

    hbm3_top #(.NUM_PC(NUM_PC)) dut (
        .clk, .rst_n,
        .fault_valid, .fault_key, .fault_flip,
        .req_valid, .req_ready, .req_write, .req_addr, .req_wdata,
        .rsp_valid, .rsp_rdata, .rsp_pc, .busy,
        .ecc_corrected_sticky, .ecc_uncorrectable_sticky,
        .cmd_valid(), .cmd_type(), .cmd_bank(), .cmd_row(), .cmd_col(),
        .cmd_wdata(), .cmd_wdbi(), .cmd_wecc(), .cmd_allbanks(),
        .cmd_rdata(), .cmd_rdbi(), .cmd_recc_stat()
    );

    // PC=0, bank=1, row=1 -- skey = {bank(4b), row[5:0](6b), col(5b)}
    // = {4'd1, 6'd1, col}
    localparam int BANK = 1, ROW = 1;
    function automatic logic [AW-1:0] addr_of(input int col);
        logic [AW-1:0] a;
        a = '0;
        a |= (AW'(BANK)) << COLBITS;
        a |= (AW'(ROW))  << (COLBITS+NBANK_AW);
        a |= (AW'(col));
        return a;
    endfunction

    task automatic wr(input logic [255:0] d);
        req_valid = 1; req_write = 1; req_addr = addr_of(0); req_wdata = d;
        do @(posedge clk); while (!req_ready);
        #1; req_valid = 0;
        while (busy) @(posedge clk);
    endtask

    logic [255:0] rd_result;
    task automatic rd();
        req_valid = 1; req_write = 0; req_addr = addr_of(0); req_wdata = 'x;
        do @(posedge clk); while (!req_ready);
        #1; req_valid = 0;
        wait (rsp_valid);
        rd_result = rsp_rdata;
        @(posedge clk);
    endtask

    // skey for PC=0: {bank[3:0], row[5:0], col[4:0]} = {4'd1, 6'd1, 5'd0}
    localparam logic [14:0] SKEY0 = {4'(BANK), 6'(ROW), 5'd0};

    int errors = 0;

    initial begin
        rst_n = 0; repeat(4) @(posedge clk); rst_n = 1; repeat(2) @(posedge clk);

        // 1) Write baseline data
        wr(256'hCAFEBABE_00000000_00000000_00000000_00000000_00000000_00000000_11223344);
        if (ecc_corrected_sticky[0] || ecc_uncorrectable_sticky[0]) begin
            $display("[ECCF-ERROR] flag already asserted immediately after write!");
            errors++;
        end

        // 2) Inject single-bit fault (bit 3 of first word in beat 0)
        fault_valid[0] = 1;
        fault_key[14:0] = SKEY0;
        fault_flip[38:0] = 39'h0000000008;  // Data bit 3
        @(posedge clk); fault_valid[0] = 0;
        repeat(2) @(posedge clk);

        rd();
        if (rd_result[31:0] !== 32'h11223344) begin
            $display("[ECCF-ERROR] data incorrect post single-bit injection! expected=11223344 received=%h", rd_result[31:0]);
            errors++;
        end
        if (!ecc_corrected_sticky[0]) begin
            $display("[ECCF-ERROR] Single-bit corrected flag DID NOT ASSERT!");
            errors++;
        end
        if (ecc_uncorrectable_sticky[0]) begin
            $display("[ECCF-ERROR] Single-bit error mistakenly asserted uncorrectable flag!");
            errors++;
        end
        $display("TB_ECC_FAULT: single-bit -> data=%h corrected=%b uncorrectable=%b",
                  rd_result[31:0], ecc_corrected_sticky[0], ecc_uncorrectable_sticky[0]);

        // 3) New write (preserves sticky flags) + double-bit error injection
        wr(256'hCAFEBABE_00000000_00000000_00000000_00000000_00000000_00000000_AABBCCDD);
        fault_valid[0] = 1;
        fault_key[14:0] = SKEY0;
        fault_flip[38:0] = 39'h0000000003;  // Data bit 0 AND bit 1 (double bit)
        @(posedge clk); fault_valid[0] = 0;
        repeat(2) @(posedge clk);

        rd();
        if (!ecc_uncorrectable_sticky[0]) begin
            $display("[ECCF-ERROR] Double-bit error DID NOT ASSERT uncorrectable flag!");
            errors++;
        end
        $display("TB_ECC_FAULT: double-bit -> data=%h (may be corrupt, EXPECTED) uncorrectable=%b",
                  rd_result[31:0], ecc_uncorrectable_sticky[0]);

        if (errors == 0) $display("TB_ECC_FAULT: PASS");
        else              $display("TB_ECC_FAULT: FAIL (%0d errors)", errors);
        $finish;
    end

    initial begin
        #500_000;
        $display("TB_ECC_FAULT: TIMEOUT");
        $finish;
    end
endmodule
