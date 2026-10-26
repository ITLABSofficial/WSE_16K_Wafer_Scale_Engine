// ============================================================================
// File: ara_openhbm3_soc_top.sv
// Project: Ara_OpenHBM3_SoC (Top-Level SoC Integration Wrapper)
// Technology: ASAP7 7nm FinFET Predictive PDK (Target: 759.2 MHz / 1.317 ns)
// Specification: Architectural Invariants & Verification Standards
// Architectural Invariants & Verification Standards
//
// Description:
//   Top-level SoC integration wrapper binding:
//   1. 2x2 Active Interposer AXI5 Crossbar (ara_hbm3_interposer_p2p)
//   2. Decoupled Streaming Engine & Hardware Guard FSM (ara_hbm3_pim_decoupled_fsm)
//   3. 16-Lane True IEEE-754 FMA Core (ara_hbm3_pim_true_fma)
//   4. 2-Cycle Synchronous Reset Deassertion Synchronizer (Reset Synchronizer Verification)
//   5. Dual HBM3 Stack AXI5 Master Interfaces (Stack 0 & Stack 1)
// ============================================================================

`timescale 1ps/1ps

module ara_openhbm3_soc_top #(
    parameter int unsigned AXI_DATA_W    = 256,
    parameter int unsigned AXI_ADDR_W    = 64,
    parameter int unsigned AXI_ID_W      = 4,
    parameter int unsigned LANES         = 16,
    parameter int unsigned DRAM_DATA_W   = 256,
    parameter int unsigned ACT_DATA_W    = 256,
    parameter int unsigned ACC_DATA_W    = 512,
    parameter int unsigned TFAW_CYCLES    = 24,
    parameter int unsigned TWTR_L_CYCLES  = 10,
    parameter int unsigned TRTW_CYCLES    = 8,
    parameter int unsigned WDT_DEFAULT    = 65535
)(
    // Clocks and Primary Asynchronous Reset
    input  logic                      clk_hbm,
    input  logic                      rst_async_n,

    // ------------------------------------------------------------------------
    // Host / Ara Vector Core AXI5 Slave Port (Direct Host Access)
    // ------------------------------------------------------------------------
    input  logic [AXI_ADDR_W-1:0]     s_host_axi_araddr,
    input  logic [AXI_ID_W-1:0]       s_host_axi_arid,
    input  logic [7:0]                s_host_axi_arlen,
    input  logic                      s_host_axi_arvalid,
    output logic                      s_host_axi_arrdy,

    output logic [AXI_DATA_W-1:0]     s_host_axi_rdata,
    output logic [AXI_ID_W-1:0]       s_host_axi_rid,
    output logic [1:0]                s_host_axi_rresp,
    output logic                      s_host_axi_rlast,
    output logic                      s_host_axi_rvalid,
    input  logic                      s_host_axi_rrdy,

    input  logic [AXI_ADDR_W-1:0]     s_host_axi_awaddr,
    input  logic [AXI_ID_W-1:0]       s_host_axi_awid,
    input  logic [7:0]                s_host_axi_awlen,
    input  logic                      s_host_axi_awvalid,
    output logic                      s_host_axi_awrdy,

    input  logic [AXI_DATA_W-1:0]     s_host_axi_wdata,
    input  logic [AXI_DATA_W/8-1:0]   s_host_axi_wstrb,
    input  logic                      s_host_axi_wlast,
    input  logic                      s_host_axi_wvalid,
    output logic                      s_host_axi_wrdy,

    output logic [AXI_ID_W-1:0]       s_host_axi_bid,
    output logic [1:0]                s_host_axi_bresp,
    output logic                      s_host_axi_bvalid,
    input  logic                      s_host_axi_brdy,

    // ------------------------------------------------------------------------
    // PIM Command & Descriptor Control Interface (MMIO / Control Unit)
    // ------------------------------------------------------------------------
    input  logic [127:0]              pim_cmd_desc_i,
    input  logic                      pim_cmd_valid_i,
    output logic                      pim_cmd_ready_o,
    input  logic                      pim_force_abort_i,

    // Vector Activations & Preload Bias Inputs (from Ara Vector Registers)
    input  logic [ACT_DATA_W-1:0]     pim_act_data_i,
    input  logic                      pim_act_valid_i,
    output logic                      pim_act_ready_o,
    input  logic [ACC_DATA_W-1:0]     pim_acc_bias_i,

    // PIM Computation Results (to Ara Vector Unit / Accumulator Bus)
    output logic [ACC_DATA_W-1:0]     pim_res_data_o,
    output logic                      pim_res_valid_o,
    input  logic                      pim_res_ready_i,
    output logic [31:0]               pim_scalar_dot_o,
    output logic [3:0]                pim_status_flags_o,
    output logic                      pim_cg_en_o,

    // PIM Status & Interrupts
    output logic                      pim_busy_o,
    output logic                      pim_done_irq_o,
    output logic                      pim_err_irq_o,
    output logic [3:0]                pim_err_code_o,

    // System Refresh & Fault Inputs
    input  logic                      dram_refresh_due_i,
    input  logic                      dram_ecc_fatal_i,

    // ------------------------------------------------------------------------
    // HBM3 Stack 0 AXI5 Master Port (Connects to Stack 0 Controller)
    // ------------------------------------------------------------------------
    output logic [AXI_ADDR_W-1:0]     m0_stack_axi_araddr,
    output logic [AXI_ID_W-1:0]       m0_stack_axi_arid,
    output logic [7:0]                m0_stack_axi_arlen,
    output logic                      m0_stack_axi_arvalid,
    input  logic                      m0_stack_axi_arrdy,

    input  logic [AXI_DATA_W-1:0]     m0_stack_axi_rdata,
    input  logic [AXI_ID_W-1:0]       m0_stack_axi_rid,
    input  logic [1:0]                m0_stack_axi_rresp,
    input  logic                      m0_stack_axi_rlast,
    input  logic                      m0_stack_axi_rvalid,
    output logic                      m0_stack_axi_rrdy,

    output logic [AXI_ADDR_W-1:0]     m0_stack_axi_awaddr,
    output logic [AXI_ID_W-1:0]       m0_stack_axi_awid,
    output logic [7:0]                m0_stack_axi_awlen,
    output logic                      m0_stack_axi_awvalid,
    input  logic                      m0_stack_axi_awrdy,

    output logic [AXI_DATA_W-1:0]     m0_stack_axi_wdata,
    output logic [AXI_DATA_W/8-1:0]   m0_stack_axi_wstrb,
    output logic                      m0_stack_axi_wlast,
    output logic                      m0_stack_axi_wvalid,
    input  logic                      m0_stack_axi_wrdy,

    input  logic [AXI_ID_W-1:0]       m0_stack_axi_bid,
    input  logic [1:0]                m0_stack_axi_bresp,
    input  logic                      m0_stack_axi_bvalid,
    output logic                      m0_stack_axi_brdy,

    // ------------------------------------------------------------------------
    // HBM3 Stack 1 AXI5 Master Port (Connects to Stack 1 Controller)
    // ------------------------------------------------------------------------
    output logic [AXI_ADDR_W-1:0]     m1_stack_axi_araddr,
    output logic [AXI_ID_W-1:0]       m1_stack_axi_arid,
    output logic [7:0]                m1_stack_axi_arlen,
    output logic                      m1_stack_axi_arvalid,
    input  logic                      m1_stack_axi_arrdy,

    input  logic [AXI_DATA_W-1:0]     m1_stack_axi_rdata,
    input  logic [AXI_ID_W-1:0]       m1_stack_axi_rid,
    input  logic [1:0]                m1_stack_axi_rresp,
    input  logic                      m1_stack_axi_rlast,
    input  logic                      m1_stack_axi_rvalid,
    output logic                      m1_stack_axi_rrdy,

    output logic [AXI_ADDR_W-1:0]     m1_stack_axi_awaddr,
    output logic [AXI_ID_W-1:0]       m1_stack_axi_awid,
    output logic [7:0]                m1_stack_axi_awlen,
    output logic                      m1_stack_axi_awvalid,
    input  logic                      m1_stack_axi_awrdy,

    output logic [AXI_DATA_W-1:0]     m1_stack_axi_wdata,
    output logic [AXI_DATA_W/8-1:0]   m1_stack_axi_wstrb,
    output logic                      m1_stack_axi_wlast,
    output logic                      m1_stack_axi_wvalid,
    input  logic                      m1_stack_axi_wrdy,

    input  logic [AXI_ID_W-1:0]       m1_stack_axi_bid,
    input  logic [1:0]                m1_stack_axi_bresp,
    input  logic                      m1_stack_axi_bvalid,
    output logic                      m1_stack_axi_brdy,

    // ------------------------------------------------------------------------
    // Inter-Stack Peer-to-Peer Crossbar Ports (Architecture Specification Section 5)
    // ------------------------------------------------------------------------
    input  logic [AXI_DATA_W-1:0]     p2p_s0_tx_data_i,
    input  logic                      p2p_s0_tx_valid_i,
    output logic                      p2p_s0_tx_ready_o,
    output logic [AXI_DATA_W-1:0]     p2p_s1_rx_data_o,
    output logic                      p2p_s1_rx_valid_o,
    input  logic                      p2p_s1_rx_ready_i,

    input  logic [AXI_DATA_W-1:0]     p2p_s1_tx_data_i,
    input  logic                      p2p_s1_tx_valid_i,
    output logic                      p2p_s1_tx_ready_o,
    output logic [AXI_DATA_W-1:0]     p2p_s0_rx_data_o,
    output logic                      p2p_s0_rx_valid_o,
    input  logic                      p2p_s0_rx_ready_i,

    output logic                      stack0_barrier_out_o,
    input  logic                      stack0_barrier_in_i,
    output logic                      stack1_barrier_out_o,
    input  logic                      stack1_barrier_in_i
);

    // ========================================================================
    // 1. Reset Synchronizer (Reset Synchronizer Verification)
    // ========================================================================
    // Asynchronous assertion, synchronous 2-cycle deassertion
    logic rst_sync_meta;
    logic rst_hbm_n;

    always_ff @(posedge clk_hbm or negedge rst_async_n) begin
        if (!rst_async_n) begin
            rst_sync_meta <= 1'b0;
            rst_hbm_n     <= 1'b0;
        end else begin
            rst_sync_meta <= 1'b1;
            rst_hbm_n     <= rst_sync_meta;
        end
    end

    // ========================================================================
    // 2. Internal Interconnect Signals
    // ========================================================================
    // Slave Port 1 of Interposer (Driven by PIM Decoupled Streaming Engine)
    logic [AXI_ADDR_W-1:0]   pim_axi_araddr;
    logic [AXI_ID_W-1:0]     pim_axi_arid;
    logic [7:0]              pim_axi_arlen;
    logic                    pim_axi_arvalid;
    logic                    pim_axi_arrdy;

    logic [AXI_DATA_W-1:0]   pim_axi_rdata;
    logic [AXI_ID_W-1:0]     pim_axi_rid;
    logic [1:0]              pim_axi_rresp;
    logic                    pim_axi_rlast;
    logic                    pim_axi_rvalid;
    logic                    pim_axi_rrdy;

    logic [AXI_ADDR_W-1:0]   pim_axi_awaddr;
    logic [AXI_ID_W-1:0]     pim_axi_awid;
    logic [7:0]              pim_axi_awlen;
    logic                    pim_axi_awvalid;
    logic                    pim_axi_awrdy;

    logic [AXI_DATA_W-1:0]   pim_axi_wdata;
    logic [AXI_DATA_W/8-1:0] pim_axi_wstrb;
    logic                    pim_axi_wlast;
    logic                    pim_axi_wvalid;
    logic                    pim_axi_wrdy;

    logic [AXI_ID_W-1:0]     pim_axi_bid;
    logic [1:0]              pim_axi_bresp;
    logic                    pim_axi_bvalid;
    logic                    pim_axi_brdy;

    // Decoupled FSM to FMA Internal Datapath Wires
    logic                    fsm_fma_valid;
    logic                    fma_fsm_ready;
    logic [1:0]              fsm_fma_act_fn;
    logic [1:0]              fsm_fma_acc_op;
    logic                    fsm_fma_mode_sel;
    logic [1:0]              fsm_fma_data_fmt;
    logic                    fsm_fma_flush;

    // DRAM Interface between FSM and AXI Streamer
    logic [33:0]             fsm_dram_addr;
    logic [2:0]              fsm_dram_op;
    logic                    fsm_dram_req;
    logic                    fsm_dram_rdy;
    logic                    fsm_dram_rdata_vld;
    logic                    fsm_dram_wdata_req;
    logic                    fsm_dram_wdata_rdy;
    logic                    fsm_dram_wcommit;

    // Registered DRAM Read Data to FMA
    logic [DRAM_DATA_W-1:0]  dram_weight_reg;
    logic                    fma_out_valid;
    logic                    fma_out_ready;

    // ========================================================================
    // 3. 2x2 Active Interposer AXI5 Crossbar Instance
    // ========================================================================
    ara_hbm3_interposer_p2p #(
        .DATA_W       (AXI_DATA_W),
        .ADDR_W       (AXI_ADDR_W),
        .ID_W         (AXI_ID_W),
        .PIPELINE_STG (2)
    ) u_interposer_crossbar (
        .clk_hbm        (clk_hbm),
        .rst_hbm_n      (rst_hbm_n),

        // S0: Host / Ara Vector Unit Port
        .s0_axi_araddr  (s_host_axi_araddr),
        .s0_axi_arid    (s_host_axi_arid),
        .s0_axi_arlen   (s_host_axi_arlen),
        .s0_axi_arvalid (s_host_axi_arvalid),
        .s0_axi_arrdy   (s_host_axi_arrdy),

        .s0_axi_rdata   (s_host_axi_rdata),
        .s0_axi_rid     (s_host_axi_rid),
        .s0_axi_rresp   (s_host_axi_rresp),
        .s0_axi_rlast   (s_host_axi_rlast),
        .s0_axi_rvalid  (s_host_axi_rvalid),
        .s0_axi_rrdy    (s_host_axi_rrdy),

        .s0_axi_awaddr  (s_host_axi_awaddr),
        .s0_axi_awid    (s_host_axi_awid),
        .s0_axi_awlen   (s_host_axi_awlen),
        .s0_axi_awvalid (s_host_axi_awvalid),
        .s0_axi_awrdy   (s_host_axi_awrdy),

        .s0_axi_wdata   (s_host_axi_wdata),
        .s0_axi_wstrb   (s_host_axi_wstrb),
        .s0_axi_wlast   (s_host_axi_wlast),
        .s0_axi_wvalid  (s_host_axi_wvalid),
        .s0_axi_wrdy    (s_host_axi_wrdy),

        .s0_axi_bid     (s_host_axi_bid),
        .s0_axi_bresp   (s_host_axi_bresp),
        .s0_axi_bvalid  (s_host_axi_bvalid),
        .s0_axi_brdy    (s_host_axi_brdy),

        // S1: PIM Master Port
        .s1_axi_araddr  (pim_axi_araddr),
        .s1_axi_arid    (pim_axi_arid),
        .s1_axi_arlen   (pim_axi_arlen),
        .s1_axi_arvalid (pim_axi_arvalid),
        .s1_axi_arrdy   (pim_axi_arrdy),

        .s1_axi_rdata   (pim_axi_rdata),
        .s1_axi_rid     (pim_axi_rid),
        .s1_axi_rresp   (pim_axi_rresp),
        .s1_axi_rlast   (pim_axi_rlast),
        .s1_axi_rvalid  (pim_axi_rvalid),
        .s1_axi_rrdy    (pim_axi_rrdy),

        .s1_axi_awaddr  (pim_axi_awaddr),
        .s1_axi_awid    (pim_axi_awid),
        .s1_axi_awlen   (pim_axi_awlen),
        .s1_axi_awvalid (pim_axi_awvalid),
        .s1_axi_awrdy   (pim_axi_awrdy),

        .s1_axi_wdata   (pim_axi_wdata),
        .s1_axi_wstrb   (pim_axi_wstrb),
        .s1_axi_wlast   (pim_axi_wlast),
        .s1_axi_wvalid  (pim_axi_wvalid),
        .s1_axi_wrdy    (pim_axi_wrdy),

        .s1_axi_bid     (pim_axi_bid),
        .s1_axi_bresp   (pim_axi_bresp),
        .s1_axi_bvalid  (pim_axi_bvalid),
        .s1_axi_brdy    (pim_axi_brdy),

        // M0: Stack 0 Controller Port
        .m0_axi_araddr  (m0_stack_axi_araddr),
        .m0_axi_arid    (m0_stack_axi_arid),
        .m0_axi_arlen   (m0_stack_axi_arlen),
        .m0_axi_arvalid (m0_stack_axi_arvalid),
        .m0_axi_arrdy   (m0_stack_axi_arrdy),

        .m0_axi_rdata   (m0_stack_axi_rdata),
        .m0_axi_rid     (m0_stack_axi_rid),
        .m0_axi_rresp   (m0_stack_axi_rresp),
        .m0_axi_rlast   (m0_stack_axi_rlast),
        .m0_axi_rvalid  (m0_stack_axi_rvalid),
        .m0_axi_rrdy    (m0_stack_axi_rrdy),

        .m0_axi_awaddr  (m0_stack_axi_awaddr),
        .m0_axi_awid    (m0_stack_axi_awid),
        .m0_axi_awlen   (m0_stack_axi_awlen),
        .m0_axi_awvalid (m0_stack_axi_awvalid),
        .m0_axi_awrdy   (m0_stack_axi_awrdy),

        .m0_axi_wdata   (m0_stack_axi_wdata),
        .m0_axi_wstrb   (m0_stack_axi_wstrb),
        .m0_axi_wlast   (m0_stack_axi_wlast),
        .m0_axi_wvalid  (m0_stack_axi_wvalid),
        .m0_axi_wrdy    (m0_stack_axi_wrdy),

        .m0_axi_bid     (m0_stack_axi_bid),
        .m0_axi_bresp   (m0_stack_axi_bresp),
        .m0_axi_bvalid  (m0_stack_axi_bvalid),
        .m0_axi_brdy    (m0_stack_axi_brdy),

        // M1: Stack 1 Controller Port
        .m1_axi_araddr  (m1_stack_axi_araddr),
        .m1_axi_arid    (m1_stack_axi_arid),
        .m1_axi_arlen   (m1_stack_axi_arlen),
        .m1_axi_arvalid (m1_stack_axi_arvalid),
        .m1_axi_arrdy   (m1_stack_axi_arrdy),

        .m1_axi_rdata   (m1_stack_axi_rdata),
        .m1_axi_rid     (m1_stack_axi_rid),
        .m1_axi_rresp   (m1_stack_axi_rresp),
        .m1_axi_rlast   (m1_stack_axi_rlast),
        .m1_axi_rvalid  (m1_stack_axi_rvalid),
        .m1_axi_rrdy    (m1_stack_axi_rrdy),

        .m1_axi_awaddr  (m1_stack_axi_awaddr),
        .m1_axi_awid    (m1_stack_axi_awid),
        .m1_axi_awlen   (m1_stack_axi_awlen),
        .m1_axi_awvalid (m1_stack_axi_awvalid),
        .m1_axi_awrdy   (m1_stack_axi_awrdy),

        .m1_axi_wdata   (m1_stack_axi_wdata),
        .m1_axi_wstrb   (m1_stack_axi_wstrb),
        .m1_axi_wlast   (m1_stack_axi_wlast),
        .m1_axi_wvalid  (m1_stack_axi_wvalid),
        .m1_axi_wrdy    (m1_stack_axi_wrdy),

        .m1_axi_bid     (m1_stack_axi_bid),
        .m1_axi_bresp   (m1_stack_axi_bresp),
        .m1_axi_bvalid  (m1_stack_axi_bvalid),
        .m1_axi_brdy    (m1_stack_axi_brdy),

        // Inter-Stack P2P Direct Stream & Barrier Lines (Inter-Stack P2P Streaming)
        .p2p_s0_tx_data     (p2p_s0_tx_data_i),
        .p2p_s0_tx_valid    (p2p_s0_tx_valid_i),
        .p2p_s0_tx_ready    (p2p_s0_tx_ready_o),
        .p2p_s1_rx_data     (p2p_s1_rx_data_o),
        .p2p_s1_rx_valid    (p2p_s1_rx_valid_o),
        .p2p_s1_rx_ready    (p2p_s1_rx_ready_i),

        .p2p_s1_tx_data     (p2p_s1_tx_data_i),
        .p2p_s1_tx_valid    (p2p_s1_tx_valid_i),
        .p2p_s1_tx_ready    (p2p_s1_tx_ready_o),
        .p2p_s0_rx_data     (p2p_s0_rx_data_o),
        .p2p_s0_rx_valid    (p2p_s0_rx_valid_o),
        .p2p_s0_rx_ready    (p2p_s0_rx_ready_i),

        .stack0_barrier_out (stack0_barrier_out_o),
        .stack0_barrier_in  (stack0_barrier_in_i),
        .stack1_barrier_out (stack1_barrier_out_o),
        .stack1_barrier_in  (stack1_barrier_in_i)
    );

    // ========================================================================
    // 4. Decoupled Streaming Engine & Hardware Guard FSM Instance
    // ========================================================================
    logic fsm_target_stack1;

    ara_hbm3_pim_decoupled_fsm #(
        .TFAW_CYCLES   (TFAW_CYCLES),
        .TWTR_L_CYCLES (TWTR_L_CYCLES),
        .TRTW_CYCLES   (TRTW_CYCLES),
        .WDT_DEFAULT   (WDT_DEFAULT)
    ) u_pim_streaming_fsm (
        .clk_hbm           (clk_hbm),
        .rst_hbm_n         (rst_hbm_n),

        // Command Interface
        .pim_cmd_desc_i    (pim_cmd_desc_i),
        .pim_cmd_valid_i   (pim_cmd_valid_i),
        .pim_cmd_ready_o   (pim_cmd_ready_o),
        .pim_force_abort_i (pim_force_abort_i),

        // Physical DRAM Command Emulation / Stream Request
        .dram_cmd_addr_o   (fsm_dram_addr),
        .dram_cmd_op_o     (fsm_dram_op),
        .dram_cmd_req_o    (fsm_dram_req),
        .dram_cmd_rdy_i    (fsm_dram_rdy),
        .dram_rdata_vld_i  (fsm_dram_rdata_vld),
        .dram_wdata_req_o  (fsm_dram_wdata_req),
        .dram_wdata_rdy_i  (fsm_dram_wdata_rdy),
        .dram_wcommit_i    (fsm_dram_wcommit),

        // FMA Datapath Interface
        .fma_valid_o       (fsm_fma_valid),
        .fma_ready_i       (fma_fsm_ready),
        .fma_act_fn_o      (fsm_fma_act_fn),
        .fma_acc_op_o      (fsm_fma_acc_op),
        .fma_mode_sel_o    (fsm_fma_mode_sel),
        .fma_data_fmt_o    (fsm_fma_data_fmt),
        .fma_flush_o       (fsm_fma_flush),

        // Refresh & Fault Signals
        .refresh_due_i     (dram_refresh_due_i),
        .ecc_fatal_i       (dram_ecc_fatal_i),

        // Status & Interrupt Signals
        .pim_busy_o        (pim_busy_o),
        .pim_done_irq_o    (pim_done_irq_o),
        .pim_err_irq_o     (pim_err_irq_o),
        .pim_err_code_o    (pim_err_code_o),
        .target_stack_o    (fsm_target_stack1)
    );

    // ========================================================================
    // 5. PIM AXI Bridge Adapter (Translates FSM Commands to AXI5 Transactions)
    // ========================================================================

    always @* begin
        // Read Address Channel (Select Stack 0 or Stack 1 - hardware invariant & hardware invariant)
        pim_axi_araddr  = (fsm_target_stack1 ? 64'h0000_0005_0000_0000 : 64'h0000_0001_0000_0000) + {30'd0, fsm_dram_addr};
        pim_axi_arid    = 4'hA;                            // PIM Stream ID
        pim_axi_arlen   = 8'd0;                            // Single beat 256-bit
        pim_axi_arvalid = fsm_dram_req && (fsm_dram_op == 3'b010); // RD op
        fsm_dram_rdy    = (fsm_dram_op == 3'b010) ? pim_axi_arrdy : 
                          (fsm_dram_op == 3'b011) ? pim_axi_awrdy : 1'b1;

        // Read Data Channel /* verified invariant */:
        // Backpressured by FMA when busy; unconditionally drains and discards orphaned beats when IDLE
        pim_axi_rrdy       = pim_busy_o ? fma_fsm_ready : 1'b1;
        fsm_dram_rdata_vld = pim_axi_rvalid && pim_axi_rrdy && pim_busy_o;

        // Write Channels /* verified invariant */
        pim_axi_awaddr     = (fsm_target_stack1 ? 64'h0000_0005_0000_0000 : 64'h0000_0001_0000_0000) + {30'd0, fsm_dram_addr};
        pim_axi_awid       = 4'hA;
        pim_axi_awlen      = 8'd0;
        pim_axi_awvalid    = fsm_dram_req && (fsm_dram_op == 3'b011); // WR op
        pim_axi_wdata      = pim_res_data_o[255:0]; // Drain low 256-bit accumulator
        pim_axi_wstrb      = '1;
        pim_axi_wlast      = 1'b1;
        pim_axi_wvalid     = fsm_dram_wdata_req;
        fsm_dram_wdata_rdy = pim_axi_wrdy;

        pim_axi_brdy       = 1'b1;
        fsm_dram_wcommit   = pim_axi_bvalid; // Write commit strobe on BVALID
    end

    // ========================================================================
    // 6. 16-Lane True IEEE-754 FMA Array Instance
    // ========================================================================
    ara_hbm3_pim_true_fma #(
        .LANES       (LANES),
        .DRAM_DATA_W (DRAM_DATA_W),
        .ACT_DATA_W  (ACT_DATA_W),
        .ACC_DATA_W  (ACC_DATA_W)
    ) u_pim_true_fma_array (
        .clk_hbm        (clk_hbm),
        .rst_hbm_n      (rst_hbm_n),

        // Flow Control /* verified invariant */
        .valid_i        (pim_axi_rvalid && pim_busy_o),
        .ready_o        (fma_fsm_ready),
        .valid_o        (pim_res_valid_o),
        .ready_i        (pim_res_ready_i),

        .act_valid_i    (pim_act_valid_i),
        .act_ready_o    (pim_act_ready_o),

        // Configuration & Control
        .data_fmt_i     (fsm_fma_data_fmt),
        .act_fn_i       (fsm_fma_act_fn),
        .acc_op_i       (fsm_fma_acc_op),
        .mode_sel_i     (fsm_fma_mode_sel),
        .flush_i        (fsm_fma_flush),

        // Data Inputs
        .dram_rdata_i   (pim_axi_rdata),
        .act_data_i     (pim_act_data_i),
        .acc_bias_i     (pim_acc_bias_i),

        // Data Outputs
        .res_data_o     (pim_res_data_o),
        .scalar_dot_o   (pim_scalar_dot_o),
        .status_flags_o (pim_status_flags_o),
        .pim_cg_en_o    (pim_cg_en_o)
    );

    assign fma_out_valid = pim_res_valid_o;
    assign fma_out_ready = pim_res_ready_i;

endmodule
