`timescale 1ns/1ps
// Bandwidth measurement: M writes followed by M pipelined reads issued to a
// single channel across distinct banks/rows (pipelined requests without stalling
// on read responses, throttled only by req_ready). Validates bank pre-activation
// (pf_*) concurrency and latency hiding under sustained traffic.
`include "hbm3_defs.svh"

module tb_bandwidth;
    logic clk = 0, rst_n;
    always #5 clk = ~clk;

    localparam int NUM_PC = 4;
    localparam int AW     = $clog2(NUM_PC) + ROWBITS + NBANK_AW + COLBITS;
    localparam int M      = 64;   // Number of requests per direction

    logic        req_valid = 0, req_ready, req_write;
    logic [AW-1:0]   req_addr;
    logic [255:0]    req_wdata;
    logic        rsp_valid;
    logic [255:0]    rsp_rdata;
    logic [$clog2(NUM_PC)-1:0] rsp_pc;
    logic        busy;

    hbm3_top #(.NUM_PC(NUM_PC)) dut (
        .clk, .rst_n,
        .fault_valid('0), .fault_key('0), .fault_flip('0),
        .req_valid, .req_ready, .req_write, .req_addr, .req_wdata,
        .rsp_valid, .rsp_rdata, .rsp_pc, .busy,
        .cmd_valid(), .cmd_type(), .cmd_bank(), .cmd_row(), .cmd_col(),
        .cmd_wdata(), .cmd_wdbi(), .cmd_rdata(), .cmd_rdbi()
    );

    // PC=0 fixed, round-robin banks, different row per access to mandate
    // actual ACT commands (avoiding optimistic page-hit assumptions).
    function automatic logic [AW-1:0] mk_addr(input int i);
        logic [AW-1:0] a;
        a  = '0;
        a |= (AW'(i % NBANKS))            << COLBITS;
        a |= (AW'(i + 1))                 << (COLBITS+NBANK_AW);
        return a;
    endfunction

    logic [255:0] expect_q [M];
    int errors = 0;

    task automatic issue(input bit wr, input int i);
        logic [255:0] d;
        d = 256'hDEADBEEF_CAFEBABE_12345678_9ABCDEF0_FFFF0000_11112222_33334444_5555 + 256'(i);
        if (wr) expect_q[i] = d;
        req_valid = 1; req_write = wr; req_addr = mk_addr(i);
        req_wdata = wr ? d : 256'hx;
        do @(posedge clk); while (!req_ready);
        #1; req_valid = 0;
    endtask

    // Collect read responses in FIFO order
    int rd_recv = 0;
    always @(posedge clk) begin
        if (rsp_valid) begin
            if (rsp_rdata !== expect_q[rd_recv]) begin
                $display("[BW-ERROR] i=%0d received=%h expected=%h", rd_recv, rsp_rdata, expect_q[rd_recv]);
                errors++;
            end
            rd_recv++;
        end
    end

    int tw_start, tw_end, tr_start, tr_end;

    initial begin
        rst_n = 0; repeat(4) @(posedge clk); rst_n = 1; repeat(2) @(posedge clk);

        // Fair measurement: interval measured from first request until completion
        // of last operation (busy deasserts for writes).
        tw_start = $time;
        for (int i = 0; i < M; i++) issue(1, i);
        while (busy) @(posedge clk);
        tw_end = $time;

        tr_start = $time;
        for (int i = 0; i < M; i++) issue(0, i);
        while (rd_recv < M) @(posedge clk);
        tr_end = $time;

        begin
            real wns, rns, wbytes, rbytes, wgbps, rgbps, peak_gbps;
            wns = real'(tw_end - tw_start); rns = real'(tr_end - tr_start);
            wbytes = real'(M) * real'(BURST_B); rbytes = real'(M) * real'(BURST_B);
            wgbps = wbytes / wns; rgbps = rbytes / rns;
            peak_gbps = 32.0 / (real'(BL/2) * 10.0); // 8B/cycle ideal (DDR), simplex, 10ns/cycle
            $display("=== BANDWIDTH BENCHMARK RESULTS (M=%0d, pipelined) ===", M);
            $display("  WRITE: %0t (%.0f cycles) -> %.3f GB/s (of ideal peak %%%.1f%)",
                      (tw_end-tw_start), wns/10.0, wgbps, 100.0*wgbps/peak_gbps);
            $display("  READ : %0t (%.0f cycles) -> %.3f GB/s (of ideal peak %%%.1f%)",
                      (tr_end-tr_start), rns/10.0, rgbps, 100.0*rgbps/peak_gbps);
            $display("  Ideal peak (bus %0d-bit, BL%0d, simplex): %.3f GB/s", DW, BL, peak_gbps);
        end

        if (errors == 0 && rd_recv == M) $display("TB_BANDWIDTH: PASS");
        else                             $display("TB_BANDWIDTH: FAIL (%0d errors, rd_recv=%0d)", errors, rd_recv);
        $finish;
    end

    initial begin
        #2_000_000;
        $display("TB_BANDWIDTH: TIMEOUT (rd_recv=%0d)", rd_recv);
        $finish;
    end
endmodule
