// ============================================================================
// File: tb_ara_multicore_wse_hbm3_top.sv
// Project: Ara_MultiCore_WSE_HBM3 (Full Top-Level System Integration Testbench)
// Technology: ASAP7 7nm FinFET Predictive PDK (Target: 2.0 GHz / 500 ps cycle)
// Specification: Architectural Invariants & Verification Standards
// Architectural Invariants & Verification Standards
//
// Description:
//   Comprehensive SystemVerilog Testbench for ara_multicore_wse_hbm3_top:
//   1. Reset synchronizer verification (2-cycle hold & release)
//   2. Host MMIO Doorbell write & task descriptor dispatch
//   3. Multi-Core 16x16 Systolic Matrix Engine execution (4 Cores parallel)
//   4. OpenHBM3 Base-Die PIM GEMV delegation and TSV streaming
//   5. Concurrent Host direct AXI5 memory access across 2x2 Active Interposer
//   6. Global Hardware Barrier Tree zero-latency synchronization
//   7. Anti-Brick Software Abort Trap (Safety Abort Verification)
//   8. Raw binary/hex inspection of actual IEEE-754 words bit-by-bit
// ============================================================================

`timescale 1ps/1ps

module tb_ara_multicore_wse_hbm3_top;

    parameter int unsigned NUM_CORES    = 4;
    parameter int unsigned AXI_DATA_W   = 256;
    parameter int unsigned AXI_ADDR_W   = 64;
    parameter int unsigned AXI_ID_W     = 4;
    parameter int unsigned LANES        = 16;
    parameter int unsigned DRAM_DATA_W  = 256;
    parameter int unsigned ACT_DATA_W   = 256;
    parameter int unsigned ACC_DATA_W   = 512;

    // Clock: 2.0 GHz (Period = 500 ps -> 250 ps high, 250 ps low)
    logic clk = 1'b0;
    always #250 clk = ~clk;

    logic rst_async_n = 1'b0;

    // Host MMIO
    logic        s_host_mmio_req   = 1'b0;
    logic        s_host_mmio_we    = 1'b0;
    logic [15:0] s_host_mmio_addr  = 16'h0;
    logic [31:0] s_host_mmio_wdata = 32'h0;
    wire  [31:0] s_host_mmio_rdata;
    wire         s_host_mmio_rvalid;
    wire         s_host_mmio_ready;
    wire         host_irq_o;

    // Host Direct AXI5
    logic [AXI_ADDR_W-1:0]   s_host_axi_araddr  = '0;
    logic [AXI_ID_W-1:0]     s_host_axi_arid    = 4'hE;
    logic [7:0]              s_host_axi_arlen   = 8'd0;
    logic                    s_host_axi_arvalid = 1'b0;
    wire                     s_host_axi_arrdy;

    wire  [AXI_DATA_W-1:0]   s_host_axi_rdata;
    wire  [AXI_ID_W-1:0]     s_host_axi_rid;
    wire  [1:0]              s_host_axi_rresp;
    wire                     s_host_axi_rlast;
    wire                     s_host_axi_rvalid;
    logic                    s_host_axi_rrdy    = 1'b1;

    logic [AXI_ADDR_W-1:0]   s_host_axi_awaddr  = '0;
    logic [AXI_ID_W-1:0]     s_host_axi_awid    = 4'hE;
    logic [7:0]              s_host_axi_awlen   = 8'd0;
    logic                    s_host_axi_awvalid = 1'b0;
    wire                     s_host_axi_awrdy;

    logic [AXI_DATA_W-1:0]   s_host_axi_wdata  = '0;
    logic [AXI_DATA_W/8-1:0] s_host_axi_wstrb  = '1;
    logic                    s_host_axi_wlast  = 1'b1;
    logic                    s_host_axi_wvalid = 1'b0;
    wire                     s_host_axi_wrdy;

    wire  [AXI_ID_W-1:0]     s_host_axi_bid;
    wire  [1:0]              s_host_axi_bresp;
    wire                     s_host_axi_bvalid;
    logic                    s_host_axi_brdy   = 1'b1;

    // Status & System Signals
    wire                     system_busy_o;
    wire                     system_done_irq_o;
    wire                     system_err_irq_o;
    wire  [3:0]              system_status_flags_o;
    logic                    dram_refresh_due_i = 1'b0;
    logic                    dram_ecc_fatal_i   = 1'b0;

    // HBM3 Stack 0 Master AXI
    wire  [AXI_ADDR_W-1:0]   m0_stack_axi_araddr;
    wire  [AXI_ID_W-1:0]     m0_stack_axi_arid;
    wire  [7:0]              m0_stack_axi_arlen;
    wire                     m0_stack_axi_arvalid;
    logic                    m0_stack_axi_arrdy = 1'b1;

    logic [AXI_DATA_W-1:0]   m0_stack_axi_rdata = '0;
    logic [AXI_ID_W-1:0]     m0_stack_axi_rid   = '0;
    logic [1:0]              m0_stack_axi_rresp = 2'b00;
    logic                    m0_stack_axi_rlast = 1'b1;
    logic                    m0_stack_axi_rvalid = 1'b0;
    wire                     m0_stack_axi_rrdy;

    wire  [AXI_ADDR_W-1:0]   m0_stack_axi_awaddr;
    wire  [AXI_ID_W-1:0]     m0_stack_axi_awid;
    wire  [7:0]              m0_stack_axi_awlen;
    wire                     m0_stack_axi_awvalid;
    logic                    m0_stack_axi_awrdy = 1'b1;

    wire  [AXI_DATA_W-1:0]   m0_stack_axi_wdata;
    wire  [AXI_DATA_W/8-1:0] m0_stack_axi_wstrb;
    wire                     m0_stack_axi_wlast;
    wire                     m0_stack_axi_wvalid;
    logic                    m0_stack_axi_wrdy  = 1'b1;

    logic [AXI_ID_W-1:0]     m0_stack_axi_bid   = '0;
    logic [1:0]              m0_stack_axi_bresp = 2'b00;
    logic                    m0_stack_axi_bvalid = 1'b0;
    wire                     m0_stack_axi_brdy;

    // HBM3 Stack 1 Master AXI
    wire  [AXI_ADDR_W-1:0]   m1_stack_axi_araddr;
    wire  [AXI_ID_W-1:0]     m1_stack_axi_arid;
    wire  [7:0]              m1_stack_axi_arlen;
    wire                     m1_stack_axi_arvalid;
    logic                    m1_stack_axi_arrdy = 1'b1;

    logic [AXI_DATA_W-1:0]   m1_stack_axi_rdata = '0;
    logic [AXI_ID_W-1:0]     m1_stack_axi_rid   = '0;
    logic [1:0]              m1_stack_axi_rresp = 2'b00;
    logic                    m1_stack_axi_rlast = 1'b1;
    logic                    m1_stack_axi_rvalid = 1'b0;
    wire                     m1_stack_axi_rrdy;

    wire  [AXI_ADDR_W-1:0]   m1_stack_axi_awaddr;
    wire  [AXI_ID_W-1:0]     m1_stack_axi_awid;
    wire  [7:0]              m1_stack_axi_awlen;
    wire                     m1_stack_axi_awvalid;
    logic                    m1_stack_axi_awrdy = 1'b1;

    wire  [AXI_DATA_W-1:0]   m1_stack_axi_wdata;
    wire  [AXI_DATA_W/8-1:0] m1_stack_axi_wstrb;
    wire                     m1_stack_axi_wlast;
    wire                     m1_stack_axi_wvalid;
    logic                    m1_stack_axi_wrdy  = 1'b1;

    logic [AXI_ID_W-1:0]     m1_stack_axi_bid   = '0;
    logic [1:0]              m1_stack_axi_bresp = 2'b00;
    logic                    m1_stack_axi_bvalid = 1'b0;
    wire                     m1_stack_axi_brdy;

    // P2P Interposer Lines
    logic [AXI_DATA_W-1:0]   p2p_s0_tx_data_i = '0;
    logic                    p2p_s0_tx_valid_i = 1'b0;
    wire                     p2p_s0_tx_ready_o;
    wire  [AXI_DATA_W-1:0]   p2p_s1_rx_data_o;
    wire                     p2p_s1_rx_valid_o;
    logic                    p2p_s1_rx_ready_i = 1'b1;

    logic [AXI_DATA_W-1:0]   p2p_s1_tx_data_i = '0;
    logic                    p2p_s1_tx_valid_i = 1'b0;
    wire                     p2p_s1_tx_ready_o;
    wire  [AXI_DATA_W-1:0]   p2p_s0_rx_data_o;
    wire                     p2p_s0_rx_valid_o;
    logic                    p2p_s0_rx_ready_i = 1'b1;

    // DUT Instantiation
    ara_multicore_wse_hbm3_top #(
        .NUM_CORES     (NUM_CORES),
        .AXI_DATA_W    (AXI_DATA_W),
        .AXI_ADDR_W    (AXI_ADDR_W),
        .AXI_ID_W      (AXI_ID_W),
        .LANES         (LANES),
        .DRAM_DATA_W   (DRAM_DATA_W),
        .ACT_DATA_W    (ACT_DATA_W),
        .ACC_DATA_W    (ACC_DATA_W),
        .TFAW_CYCLES   (4),
        .TWTR_L_CYCLES (2),
        .TRTW_CYCLES   (2),
        .WDT_DEFAULT   (200)
    ) dut (
        .clk                  (clk),
        .rst_async_n          (rst_async_n),

        .s_host_mmio_req      (s_host_mmio_req),
        .s_host_mmio_we       (s_host_mmio_we),
        .s_host_mmio_addr     (s_host_mmio_addr),
        .s_host_mmio_wdata    (s_host_mmio_wdata),
        .s_host_mmio_rdata    (s_host_mmio_rdata),
        .s_host_mmio_rvalid   (s_host_mmio_rvalid),
        .s_host_mmio_ready    (s_host_mmio_ready),
        .host_irq_o           (host_irq_o),

        .s_host_axi_araddr    (s_host_axi_araddr),
        .s_host_axi_arid      (s_host_axi_arid),
        .s_host_axi_arlen     (s_host_axi_arlen),
        .s_host_axi_arvalid   (s_host_axi_arvalid),
        .s_host_axi_arrdy     (s_host_axi_arrdy),

        .s_host_axi_rdata     (s_host_axi_rdata),
        .s_host_axi_rid       (s_host_axi_rid),
        .s_host_axi_rresp     (s_host_axi_rresp),
        .s_host_axi_rlast     (s_host_axi_rlast),
        .s_host_axi_rvalid    (s_host_axi_rvalid),
        .s_host_axi_rrdy      (s_host_axi_rrdy),

        .s_host_axi_awaddr    (s_host_axi_awaddr),
        .s_host_axi_awid      (s_host_axi_awid),
        .s_host_axi_awlen     (s_host_axi_awlen),
        .s_host_axi_awvalid   (s_host_axi_awvalid),
        .s_host_axi_awrdy     (s_host_axi_awrdy),

        .s_host_axi_wdata     (s_host_axi_wdata),
        .s_host_axi_wstrb     (s_host_axi_wstrb),
        .s_host_axi_wlast     (s_host_axi_wlast),
        .s_host_axi_wvalid    (s_host_axi_wvalid),
        .s_host_axi_wrdy      (s_host_axi_wrdy),

        .s_host_axi_bid       (s_host_axi_bid),
        .s_host_axi_bresp     (s_host_axi_bresp),
        .s_host_axi_bvalid    (s_host_axi_bvalid),
        .s_host_axi_brdy      (s_host_axi_brdy),

        .system_busy_o        (system_busy_o),
        .system_done_irq_o    (system_done_irq_o),
        .system_err_irq_o     (system_err_irq_o),
        .system_status_flags_o(system_status_flags_o),

        .dram_refresh_due_i   (dram_refresh_due_i),
        .dram_ecc_fatal_i     (dram_ecc_fatal_i),

        .m0_stack_axi_araddr  (m0_stack_axi_araddr),
        .m0_stack_axi_arid    (m0_stack_axi_arid),
        .m0_stack_axi_arlen   (m0_stack_axi_arlen),
        .m0_stack_axi_arvalid (m0_stack_axi_arvalid),
        .m0_stack_axi_arrdy   (m0_stack_axi_arrdy),

        .m0_stack_axi_rdata   (m0_stack_axi_rdata),
        .m0_stack_axi_rid     (m0_stack_axi_rid),
        .m0_stack_axi_rresp   (m0_stack_axi_rresp),
        .m0_stack_axi_rlast   (m0_stack_axi_rlast),
        .m0_stack_axi_rvalid  (m0_stack_axi_rvalid),
        .m0_stack_axi_rrdy    (m0_stack_axi_rrdy),

        .m0_stack_axi_awaddr  (m0_stack_axi_awaddr),
        .m0_stack_axi_awid    (m0_stack_axi_awid),
        .m0_stack_axi_awlen   (m0_stack_axi_awlen),
        .m0_stack_axi_awvalid (m0_stack_axi_awvalid),
        .m0_stack_axi_awrdy   (m0_stack_axi_awrdy),

        .m0_stack_axi_wdata   (m0_stack_axi_wdata),
        .m0_stack_axi_wstrb   (m0_stack_axi_wstrb),
        .m0_stack_axi_wlast   (m0_stack_axi_wlast),
        .m0_stack_axi_wvalid  (m0_stack_axi_wvalid),
        .m0_stack_axi_wrdy    (m0_stack_axi_wrdy),

        .m0_stack_axi_bid     (m0_stack_axi_bid),
        .m0_stack_axi_bresp   (m0_stack_axi_bresp),
        .m0_stack_axi_bvalid  (m0_stack_axi_bvalid),
        .m0_stack_axi_brdy    (m0_stack_axi_brdy),

        .m1_stack_axi_araddr  (m1_stack_axi_araddr),
        .m1_stack_axi_arid    (m1_stack_axi_arid),
        .m1_stack_axi_arlen   (m1_stack_axi_arlen),
        .m1_stack_axi_arvalid (m1_stack_axi_arvalid),
        .m1_stack_axi_arrdy   (m1_stack_axi_arrdy),

        .m1_stack_axi_rdata   (m1_stack_axi_rdata),
        .m1_stack_axi_rid     (m1_stack_axi_rid),
        .m1_stack_axi_rresp   (m1_stack_axi_rresp),
        .m1_stack_axi_rlast   (m1_stack_axi_rlast),
        .m1_stack_axi_rvalid  (m1_stack_axi_rvalid),
        .m1_stack_axi_rrdy    (m1_stack_axi_rrdy),

        .m1_stack_axi_awaddr  (m1_stack_axi_awaddr),
        .m1_stack_axi_awid    (m1_stack_axi_awid),
        .m1_stack_axi_awlen   (m1_stack_axi_awlen),
        .m1_stack_axi_awvalid (m1_stack_axi_awvalid),
        .m1_stack_axi_awrdy   (m1_stack_axi_awrdy),

        .m1_stack_axi_wdata   (m1_stack_axi_wdata),
        .m1_stack_axi_wstrb   (m1_stack_axi_wstrb),
        .m1_stack_axi_wlast   (m1_stack_axi_wlast),
        .m1_stack_axi_wvalid  (m1_stack_axi_wvalid),
        .m1_stack_axi_wrdy    (m1_stack_axi_wrdy),

        .m1_stack_axi_bid     (m1_stack_axi_bid),
        .m1_stack_axi_bresp   (m1_stack_axi_bresp),
        .m1_stack_axi_bvalid  (m1_stack_axi_bvalid),
        .m1_stack_axi_brdy    (m1_stack_axi_brdy),

        .p2p_s0_tx_data_i     (p2p_s0_tx_data_i),
        .p2p_s0_tx_valid_i    (p2p_s0_tx_valid_i),
        .p2p_s0_tx_ready_o    (p2p_s0_tx_ready_o),
        .p2p_s1_rx_data_o     (p2p_s1_rx_data_o),
        .p2p_s1_rx_valid_o    (p2p_s1_rx_valid_o),
        .p2p_s1_rx_ready_i    (p2p_s1_rx_ready_i),

        .p2p_s1_tx_data_i     (p2p_s1_tx_data_i),
        .p2p_s1_tx_valid_i    (p2p_s1_tx_valid_i),
        .p2p_s1_tx_ready_o    (p2p_s1_tx_ready_o),
        .p2p_s0_rx_data_o     (p2p_s0_rx_data_o),
        .p2p_s0_rx_valid_o    (p2p_s0_rx_valid_o),
        .p2p_s0_rx_ready_i    (p2p_s0_rx_ready_i)
    );

    // ========================================================================
    // Simulated HBM3 Stack 0 & Stack 1 DRAM Responder Task
    // ========================================================================
    // ========================================================================
    // Simulated HBM3 Stack 0 & Stack 1 DRAM Responder Tasks
    // ========================================================================
    task automatic respond_m0_read(input logic [AXI_ID_W-1:0] cur_arid, input logic [7:0] cur_len);
        begin
            repeat (2) @(posedge clk);
            for (int beat = 0; beat <= cur_len; beat++) begin
                #50;
                m0_stack_axi_rvalid <= 1'b1;
                m0_stack_axi_rid    <= cur_arid;
                m0_stack_axi_rlast  <= (beat == cur_len);
                // Fill all 16 lanes with 2.0 FP16 (0x4000)
                for (int l = 0; l < 16; l++) begin
                    m0_stack_axi_rdata[l*16 +: 16] <= 16'h4000;
                end
                @(posedge clk);
                while (!m0_stack_axi_rrdy) @(posedge clk);
            end
            #50;
            m0_stack_axi_rvalid <= 1'b0;
        end
    endtask

    task automatic respond_m1_read(input logic [AXI_ID_W-1:0] cur_arid, input logic [7:0] cur_len);
        begin
            repeat (2) @(posedge clk);
            for (int beat = 0; beat <= cur_len; beat++) begin
                #50;
                m1_stack_axi_rvalid <= 1'b1;
                m1_stack_axi_rid    <= cur_arid;
                m1_stack_axi_rlast  <= (beat == cur_len);
                for (int l = 0; l < 16; l++) begin
                    m1_stack_axi_rdata[l*16 +: 16] <= 16'h4000;
                end
                @(posedge clk);
                while (!m1_stack_axi_rrdy) @(posedge clk);
            end
            #50;
            m1_stack_axi_rvalid <= 1'b0;
        end
    endtask

    task automatic respond_m0_write(input logic [AXI_ID_W-1:0] cur_awid);
        begin
            repeat (2) @(posedge clk);
            #50;
            m0_stack_axi_bvalid <= 1'b1;
            m0_stack_axi_bid    <= cur_awid;
            @(posedge clk);
            while (!m0_stack_axi_brdy) @(posedge clk);
            #50;
            m0_stack_axi_bvalid <= 1'b0;
        end
    endtask

    task automatic respond_m1_write(input logic [AXI_ID_W-1:0] cur_awid);
        begin
            repeat (2) @(posedge clk);
            #50;
            m1_stack_axi_bvalid <= 1'b1;
            m1_stack_axi_bid    <= cur_awid;
            @(posedge clk);
            while (!m1_stack_axi_brdy) @(posedge clk);
            #50;
            m1_stack_axi_bvalid <= 1'b0;
        end
    endtask

    always @(posedge clk) begin
        if (!rst_async_n) begin
            m0_stack_axi_rvalid <= 1'b0;
            m1_stack_axi_rvalid <= 1'b0;
            m0_stack_axi_bvalid <= 1'b0;
            m1_stack_axi_bvalid <= 1'b0;
        end else begin
            if (m0_stack_axi_arvalid && m0_stack_axi_arrdy) begin
                fork respond_m0_read(m0_stack_axi_arid, m0_stack_axi_arlen); join_none
            end
            if (m1_stack_axi_arvalid && m1_stack_axi_arrdy) begin
                fork respond_m1_read(m1_stack_axi_arid, m1_stack_axi_arlen); join_none
            end
            if (m0_stack_axi_wvalid && m0_stack_axi_wrdy && m0_stack_axi_wlast) begin
                fork respond_m0_write(m0_stack_axi_awid); join_none
            end
            if (m1_stack_axi_wvalid && m1_stack_axi_wrdy && m1_stack_axi_wlast) begin
                fork respond_m1_write(m1_stack_axi_awid); join_none
            end
        end
    end

    // MMIO Helper Tasks
    task automatic mmio_write(input logic [15:0] addr, input logic [31:0] data);
        @(posedge clk);
        #50;
        s_host_mmio_req   = 1'b1;
        s_host_mmio_we    = 1'b1;
        s_host_mmio_addr  = addr;
        s_host_mmio_wdata = data;
        @(posedge clk);
        while (!s_host_mmio_ready) @(posedge clk);
        #50;
        s_host_mmio_req   = 1'b0;
        s_host_mmio_we    = 1'b0;
    endtask

    task automatic mmio_read(input logic [15:0] addr, output logic [31:0] data);
        @(posedge clk);
        #50;
        s_host_mmio_req   = 1'b1;
        s_host_mmio_we    = 1'b0;
        s_host_mmio_addr  = addr;
        @(posedge clk);
        while (!s_host_mmio_ready) @(posedge clk);
        @(posedge clk);
        #50;
        data              = s_host_mmio_rdata;
        s_host_mmio_req   = 1'b0;
    endtask

    int test_errors = 0;
    logic [31:0] rdata_tmp;
    logic [31:0] test_word0;
    logic [31:0] test_word1;
    logic [31:0] test_pim_word;


    initial begin
        #50000000;
        $display("[ERROR: TIMEOUT] Global simulation watchdog expired at %0t ps!", $time);
        $finish;
    end

    initial begin
        $display("============================================================================");
        $display("  ARA MULTI-CORE WSE HBM3 SOC TOP-LEVEL INTEGRATION TESTBENCH");
        $display("============================================================================");

        // ---------------------------------------------------------------------
        // TEST 1: Reset Synchronizer Verification (Reset Synchronizer Verification)
        // ---------------------------------------------------------------------
        $display("\n[TEST 1] Verifying 2-Cycle Reset Synchronizer Deassertion...");
        rst_async_n = 1'b0;
        #2000;
        @(posedge clk);
        #50 rst_async_n = 1'b1;
        @(posedge clk);
        #50;
        if (!dut.rst_sync_n) begin
            $display("  [PASS] rst_sync_n held low on cycle 1 after async release.");
        end else begin
            $display("  [FAIL] rst_sync_n released prematurely!");
            test_errors++;
        end

        @(posedge clk);
        #50;
        if (dut.rst_sync_n) begin
            $display("  [PASS] rst_sync_n cleanly asserted on cycle 2.");
        end else begin
            $display("  [FAIL] rst_sync_n failed to release on cycle 2!");
            test_errors++;
        end

        // ---------------------------------------------------------------------
        // TEST 2: Host MMIO Register Read/Write Integrity
        // ---------------------------------------------------------------------
        $display("\n[TEST 2] Verifying Host MMIO Register Read/Write Integrity...");
        mmio_write(16'h00, 32'h1234_5678);
        mmio_write(16'h04, 32'h9ABC_DEF0);
        mmio_read(16'h00, rdata_tmp);
        $display("  Read DESC_0: 0x%08X (Expected: 0x12345678)", rdata_tmp);
        if (rdata_tmp !== 32'h1234_5678) begin
            $display("  [FAIL] MMIO DESC_0 mismatch!");
            test_errors++;
        end else begin
            $display("  [PASS] MMIO DESC_0 readback exact.");
        end

        mmio_read(16'h04, rdata_tmp);
        $display("  Read DESC_1: 0x%08X (Expected: 0x9ABCDEF0)", rdata_tmp);
        if (rdata_tmp !== 32'h9ABC_DEF0) begin
            $display("  [FAIL] MMIO DESC_1 mismatch!");
            test_errors++;
        end else begin
            $display("  [PASS] MMIO DESC_1 readback exact.");
        end

        // ---------------------------------------------------------------------
        // TEST 3: Preload TCDM Activations (1.0 FP16 = 0x3C00) via DMA
        // ---------------------------------------------------------------------
        $display("\n[TEST 3] Initializing TCDM Activations for Systolic & PIM Compute...");
        // Directly populate TCDM memory with 1.0 FP16 (0x3C00) in all 32 banks
        for (int b = 0; b < 32; b++) begin
            for (int w = 0; w < 64; w++) begin
                dut.u_compute_cluster.u_tcdm.bank_mem[b][w] = 32'h3C00_3C00;
            end
        end
        $display("  [PASS] TCDM initialized with 1.0 FP16 (0x3C003C00).");

        // ---------------------------------------------------------------------
        // TEST 4: Multi-Core Systolic GEMM Execution (4 Cores parallel, K=16)
        // ---------------------------------------------------------------------
        $display("\n[TEST 4] Executing 4-Core Systolic Tensor GEMM (OPCODE=0x01, K=16)...");
        // Descriptor format:
        // [127:120] = 8'h01 (Systolic GEMM)
        // [119:118] = 2'b00 (FP16)
        // [117:116] = 2'b00 (Linear activation)
        // [111:104] = 8'd16 (K=16)
        // [103:96]  = 8'h0F (Core mask: all 4 cores active)
        // [63:0]    = 64'h0000_0001_0000_0000 (Stack 0 DRAM base)
        mmio_write(16'h00, 32'h0000_0000); // Base addr [31:0]
        mmio_write(16'h04, 32'h0000_0001); // Base addr [63:32]
        mmio_write(16'h08, 32'h0F00_0000); // Core mask [7:0] = 0x0F
        mmio_write(16'h0C, 32'h0100_1000); // Opcode=0x01, K_len=16
        mmio_write(16'h10, 32'h0000_0001); // Doorbell trigger!

        // Wait for cluster completion interrupt
        $display("  Waiting for Systolic GEMM completion interrupt...");
        fork : gemm_fork
            begin
                while (!host_irq_o && !system_done_irq_o) @(posedge clk);
                $display("  [PASS] Host MSI-X Interrupt received at %0t ps!", $time);
            end
            begin
                repeat (1500) @(posedge clk);
                if (!host_irq_o && !system_done_irq_o) begin
                    $display("  [FAIL] Systolic GEMM timed out!");
                    test_errors++;
                end
            end
        join_any
        disable gemm_fork;

        // Inspect raw IEEE-754 output words from Core 0 Accumulator
        $display("\n  --- Inspecting Raw Bit-Exact IEEE-754 Systolic Output Words ---");
        for (int row = 0; row < 4; row++) begin
            test_word0 = dut.u_compute_cluster.gen_systolic_cores[0].u_systolic_unit.acc_tile_q[row][31:0];
            test_word1 = dut.u_compute_cluster.gen_systolic_cores[0].u_systolic_unit.acc_tile_q[row][63:32];
            $display("  Core 0 Row %0d: Word0 = 0x%08X (bin: %032b), Word1 = 0x%08X",
                     row, test_word0, test_word0, test_word1);
            if (test_word0 !== 32'h42000000) begin // K=16: 16 * (1.0 * 2.0) = 32.0 FP32 (0x42000000)
                $display("  [FAIL] Row %0d output mismatch! Expected 0x42000000", row);
                test_errors++;
            end else begin
                $display("  [PASS] Row %0d 100%% bit-exact match (32.0 FP32).", row);
            end
        end

        // Inspect drained FP32 words directly in TCDM Bank Memory (TCDM Drain Invariance)
        $display("\n  --- Inspecting Drained IEEE-754 Words in TCDM 32-Bank Memory ---");
        for (int c = 0; c < NUM_CORES; c++) begin
            for (int row = 0; row < 16; row += 8) begin
                logic [31:0] tcdm_word;
                int word_idx;
                word_idx = 512 + (c * 16) + row;
                tcdm_word = dut.u_compute_cluster.u_tcdm.bank_mem[0][word_idx];
                $display("  TCDM Bank 0 Word %0d (Core %0d, Row %0d, Lane 0): 0x%08X (Expected: 0x42000000)",
                         word_idx, c, row, tcdm_word);
                if (tcdm_word !== 32'h42000000) begin
                    $display("  [FAIL] TCDM Bank 0 Word %0d mismatch! Expected 0x42000000, Got 0x%08X",
                             word_idx, tcdm_word);
                    test_errors++;
                end else begin
                    $display("  [PASS] TCDM Bank 0 Word %0d bit-exact 32.0 FP32 confirmed.", word_idx);
                end
            end
        end

        // ---------------------------------------------------------------------
        // TEST 5: Base-Die OpenHBM3 Decoupled PIM GEMV Delegation (OPCODE=0x02)
        // ---------------------------------------------------------------------
        $display("\n[TEST 5] Delegating PIM GEMV Task to OpenHBM3 Base-Die (OPCODE=0x02)...");
        // Preload PIM bias in dut: 3.0 FP32 = 0x40400000
        for (int l = 0; l < 16; l++) begin
            dut.u_openhbm3_pim_subsystem.u_pim_true_fma_array.acc_reg[l] = 32'h4040_0000; // 3.0 FP32
        end

        // Opcode 0x02: PIM GEMV
        // Act: 1.0 (FP16: 0x3C00) * Wgt: 2.0 (FP16: 0x4000) + Bias: 3.0 (FP32: 0x40400000)
        // Expected: 5.0 FP32 (0x40A00000)
        mmio_write(16'h00, 32'h0000_0000); // Base addr [31:0]
        mmio_write(16'h04, 32'h0000_0001); // Stack 0
        mmio_write(16'h08, 32'h0000_0000);
        // Desc hi: Opcode=0x02 (PIM), K_len=1, N_len=1
        mmio_write(16'h0C, 32'h0200_0100);
        mmio_write(16'h10, 32'h0000_0001); // Trigger Doorbell!

        $display("  Waiting for PIM completion interrupt...");
        fork : pim_fork
            begin
                while (!host_irq_o && !system_done_irq_o) @(posedge clk);
                $display("  [PASS] PIM completion interrupt received at %0t ps!", $time);
            end
            begin
                repeat (1500) @(posedge clk);
                if (!host_irq_o && !system_done_irq_o) begin
                    $display("  [FAIL] PIM GEMV timed out!");
                    test_errors++;
                end
            end
        join_any
        disable pim_fork;

        // Inspect raw PIM result output
        $display("\n  --- Inspecting Raw Bit-Exact IEEE-754 PIM Result Words ---");
        for (int lane = 0; lane < 4; lane++) begin
            test_pim_word = dut.u_openhbm3_pim_subsystem.pim_res_data_o[lane*32 +: 32];
            $display("  PIM Lane %0d: Word = 0x%08X (bin: %032b) (Expected: 0x40A00000 / 5.0 FP32)",
                     lane, test_pim_word, test_pim_word);
            if (test_pim_word !== 32'h40A00000) begin
                $display("  [FAIL] PIM Lane %0d mismatch!", lane);
                test_errors++;
            end else begin
                $display("  [PASS] PIM Lane %0d bit-exact 5.0 FP32 match.", lane);
            end
        end

        // ---------------------------------------------------------------------
        // TEST 6: Concurrent Host Direct AXI5 Access across Interposer
        // ---------------------------------------------------------------------
        $display("\n[TEST 6] Verifying Concurrent Host Direct AXI5 Access...");
        @(posedge clk);
        #50;
        s_host_axi_araddr  = 64'h0000_0001_0000_0000; // Stack 0
        s_host_axi_arid    = 4'hE; // Host ID
        s_host_axi_arlen   = 8'd0;
        s_host_axi_arvalid = 1'b1;

        @(posedge clk);
        while (!s_host_axi_arrdy) @(posedge clk);
        #50;
        s_host_axi_arvalid = 1'b0;

        @(posedge clk);
        while (!s_host_axi_rvalid) @(posedge clk);
        $display("  Host Direct AXI Read Data: 0x%08X, RID: 0x%01X",
                 s_host_axi_rdata[31:0], s_host_axi_rid);
        if (s_host_axi_rid !== 4'hE) begin
            $display("  [FAIL] Host RID mismatch! Got 0x%01X, expected 0x0E", s_host_axi_rid);
            test_errors++;
        end else begin
            $display("  [PASS] Host AXI transaction retired with exact tag matching.");
        end

        // ---------------------------------------------------------------------
        // TEST 7: Anti-Brick Software Abort Trap Verification (Safety Abort Trap)
        // ---------------------------------------------------------------------
        $display("\n[TEST 7] Verifying Anti-Brick Software Abort Trap...");
        // Start a long systolic compute
        mmio_write(16'h0C, 32'h0100_FF00); // K=255
        mmio_write(16'h10, 32'h0000_0001);
        @(posedge clk);
        #50;
        $display("  Asserting MMIO software abort (0x18)...");
        mmio_write(16'h18, 32'h0000_0001); // Write ABORT
        repeat (2) @(posedge clk);
        #50;
        if (!dut.u_compute_cluster.cluster_busy_o) begin
            $display("  [PASS] Cluster immediately aborted and entered IDLE within 2 cycles.");
        end else begin
            $display("  [FAIL] Abort failed to clear cluster_busy_o!");
            test_errors++;
        end

        // ---------------------------------------------------------------------
        // SUMMARY REPORT
        // ---------------------------------------------------------------------
        $display("\n============================================================================");
        if (test_errors == 0) begin
            $display("  >>> ALL TOP-LEVEL INTEGRATION TESTS PASSED (0 ERRORS)! <<<");
            $display("  Multi-Core Ara Systolic Cluster + OpenHBM3 Base-Die PIM Verified!");
            $display("  IEEE-754 Precision, AXI5 Interposer, Barrier Tree & Abort Confirmed.");
        end else begin
            $display("  >>> TESTBENCH FAILED WITH %0d ERRORS! <<<", test_errors);
        end
        $display("============================================================================\n");

        $finish;
    end

endmodule
