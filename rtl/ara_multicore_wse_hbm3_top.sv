// ============================================================================
// File: ara_multicore_wse_hbm3_top.sv
// Project: Ara_MultiCore_WSE_HBM3 (Top-Level Multi-Core WSE HBM3 SoC Integration)
// Technology: ASAP7 7nm FinFET Predictive PDK (Target: 2.0 GHz / 500 ps cycle)
// Specification: Architectural Invariants & Verification Standards
// Architectural Invariants & Verification Standards
//
// Description:
//   Top-level SoC integration wrapper binding:
//   1. Multi-Core Ara Systolic Compute Cluster (ara_multicore_cluster)
//   2. OpenHBM3 Base-Die Decoupled PIM Subsystem (ara_openhbm3_soc_top)
//   3. Host MMIO Doorbell Dispatcher (ara_host_cmd_dispatcher)
//   4. Global Hardware Barrier Tree (ara_barrier_tree)
//   5. 2-Cycle Synchronous Reset Synchronizer (Reset Synchronizer Verification)
//   6. Atomic AXI5 Host / Cluster Interposer Arbiter /* verified invariant */
// ============================================================================

`timescale 1ps/1ps

module ara_multicore_wse_hbm3_top #(
    parameter int unsigned NUM_CORES     = 4,
    parameter int unsigned AXI_DATA_W    = 256,
    parameter int unsigned AXI_ADDR_W    = 64,
    parameter int unsigned AXI_ID_W      = 4,
    parameter int unsigned LANES         = 16,
    parameter int unsigned DRAM_DATA_W   = 256,
    parameter int unsigned ACT_DATA_W    = 256,
    parameter int unsigned ACC_DATA_W    = 512,
    parameter int unsigned TFAW_CYCLES   = 24,
    parameter int unsigned TWTR_L_CYCLES = 10,
    parameter int unsigned TRTW_CYCLES   = 8,
    parameter int unsigned WDT_DEFAULT   = 65535
)(
    // Clocks and Primary Asynchronous Reset
    input  logic                         clk,
    input  logic                         rst_async_n,

    // ------------------------------------------------------------------------
    // Host PCIe/CXL MMIO Doorbell Slave Interface
    // ------------------------------------------------------------------------
    input  logic                         s_host_mmio_req,
    input  logic                         s_host_mmio_we,
    input  logic [15:0]                  s_host_mmio_addr,
    input  logic [31:0]                  s_host_mmio_wdata,
    output logic [31:0]                  s_host_mmio_rdata,
    output logic                         s_host_mmio_rvalid,
    output logic                         s_host_mmio_ready,
    output logic                         host_irq_o,

    // ------------------------------------------------------------------------
    // Host Direct AXI5 Slave Port (Access to HBM3 DRAM & Base-Die PIM)
    // ------------------------------------------------------------------------
    input  logic [AXI_ADDR_W-1:0]        s_host_axi_araddr,
    input  logic [AXI_ID_W-1:0]          s_host_axi_arid,
    input  logic [7:0]                   s_host_axi_arlen,
    input  logic                         s_host_axi_arvalid,
    output logic                         s_host_axi_arrdy,

    output logic [AXI_DATA_W-1:0]        s_host_axi_rdata,
    output logic [AXI_ID_W-1:0]          s_host_axi_rid,
    output logic [1:0]                   s_host_axi_rresp,
    output logic                         s_host_axi_rlast,
    output logic                         s_host_axi_rvalid,
    input  logic                         s_host_axi_rrdy,

    input  logic [AXI_ADDR_W-1:0]        s_host_axi_awaddr,
    input  logic [AXI_ID_W-1:0]          s_host_axi_awid,
    input  logic [7:0]                   s_host_axi_awlen,
    input  logic                         s_host_axi_awvalid,
    output logic                         s_host_axi_awrdy,

    input  logic [AXI_DATA_W-1:0]        s_host_axi_wdata,
    input  logic [AXI_DATA_W/8-1:0]      s_host_axi_wstrb,
    input  logic                         s_host_axi_wlast,
    input  logic                         s_host_axi_wvalid,
    output logic                         s_host_axi_wrdy,

    output logic [AXI_ID_W-1:0]          s_host_axi_bid,
    output logic [1:0]                   s_host_axi_bresp,
    output logic                         s_host_axi_bvalid,
    input  logic                         s_host_axi_brdy,

    // ------------------------------------------------------------------------
    // System Status & Interrupts
    // ------------------------------------------------------------------------
    output logic                         system_busy_o,
    output logic                         system_done_irq_o,
    output logic                         system_err_irq_o,
    output logic [3:0]                   system_status_flags_o,

    // System Refresh & Fault Inputs
    input  logic                         dram_refresh_due_i,
    input  logic                         dram_ecc_fatal_i,

    // ------------------------------------------------------------------------
    // HBM3 Stack 0 AXI5 Master Port (Connects to Stack 0 PHY / Controller)
    // ------------------------------------------------------------------------
    output logic [AXI_ADDR_W-1:0]        m0_stack_axi_araddr,
    output logic [AXI_ID_W-1:0]          m0_stack_axi_arid,
    output logic [7:0]                   m0_stack_axi_arlen,
    output logic                         m0_stack_axi_arvalid,
    input  logic                         m0_stack_axi_arrdy,

    input  logic [AXI_DATA_W-1:0]        m0_stack_axi_rdata,
    input  logic [AXI_ID_W-1:0]          m0_stack_axi_rid,
    input  logic [1:0]                   m0_stack_axi_rresp,
    input  logic                         m0_stack_axi_rlast,
    input  logic                         m0_stack_axi_rvalid,
    output logic                         m0_stack_axi_rrdy,

    output logic [AXI_ADDR_W-1:0]        m0_stack_axi_awaddr,
    output logic [AXI_ID_W-1:0]          m0_stack_axi_awid,
    output logic [7:0]                   m0_stack_axi_awlen,
    output logic                         m0_stack_axi_awvalid,
    input  logic                         m0_stack_axi_awrdy,

    output logic [AXI_DATA_W-1:0]        m0_stack_axi_wdata,
    output logic [AXI_DATA_W/8-1:0]      m0_stack_axi_wstrb,
    output logic                         m0_stack_axi_wlast,
    output logic                         m0_stack_axi_wvalid,
    input  logic                         m0_stack_axi_wrdy,

    input  logic [AXI_ID_W-1:0]          m0_stack_axi_bid,
    input  logic [1:0]                   m0_stack_axi_bresp,
    input  logic                         m0_stack_axi_bvalid,
    output logic                         m0_stack_axi_brdy,

    // ------------------------------------------------------------------------
    // HBM3 Stack 1 AXI5 Master Port (Connects to Stack 1 PHY / Controller)
    // ------------------------------------------------------------------------
    output logic [AXI_ADDR_W-1:0]        m1_stack_axi_araddr,
    output logic [AXI_ID_W-1:0]          m1_stack_axi_arid,
    output logic [7:0]                   m1_stack_axi_arlen,
    output logic                         m1_stack_axi_arvalid,
    input  logic                         m1_stack_axi_arrdy,

    input  logic [AXI_DATA_W-1:0]        m1_stack_axi_rdata,
    input  logic [AXI_ID_W-1:0]          m1_stack_axi_rid,
    input  logic [1:0]                   m1_stack_axi_rresp,
    input  logic                         m1_stack_axi_rlast,
    input  logic                         m1_stack_axi_rvalid,
    output logic                         m1_stack_axi_rrdy,

    output logic [AXI_ADDR_W-1:0]        m1_stack_axi_awaddr,
    output logic [AXI_ID_W-1:0]          m1_stack_axi_awid,
    output logic [7:0]                   m1_stack_axi_awlen,
    output logic                         m1_stack_axi_awvalid,
    input  logic                         m1_stack_axi_awrdy,

    output logic [AXI_DATA_W-1:0]        m1_stack_axi_wdata,
    output logic [AXI_DATA_W/8-1:0]      m1_stack_axi_wstrb,
    output logic                         m1_stack_axi_wlast,
    output logic                         m1_stack_axi_wvalid,
    input  logic                         m1_stack_axi_wrdy,

    input  logic [AXI_ID_W-1:0]          m1_stack_axi_bid,
    input  logic [1:0]                   m1_stack_axi_bresp,
    input  logic                         m1_stack_axi_bvalid,
    output logic                         m1_stack_axi_brdy,

    // ------------------------------------------------------------------------
    // Inter-Stack Peer-to-Peer Crossbar Ports
    // ------------------------------------------------------------------------
    input  logic [AXI_DATA_W-1:0]        p2p_s0_tx_data_i,
    input  logic                         p2p_s0_tx_valid_i,
    output logic                         p2p_s0_tx_ready_o,
    output logic [AXI_DATA_W-1:0]        p2p_s1_rx_data_o,
    output logic                         p2p_s1_rx_valid_o,
    input  logic                         p2p_s1_rx_ready_i,

    input  logic [AXI_DATA_W-1:0]        p2p_s1_tx_data_i,
    input  logic                         p2p_s1_tx_valid_i,
    output logic                         p2p_s1_tx_ready_o,
    output logic [AXI_DATA_W-1:0]        p2p_s0_rx_data_o,
    output logic                         p2p_s0_rx_valid_o,
    input  logic                         p2p_s0_rx_ready_i
);

    // ========================================================================
    // 1. Reset Synchronizer (Reset Synchronizer Verification)
    // ========================================================================
    logic rst_sync_meta;
    logic rst_sync_n;

    always_ff @(posedge clk or negedge rst_async_n) begin
        if (!rst_async_n) begin
            rst_sync_meta <= 1'b0;
            rst_sync_n    <= 1'b0;
        end else begin
            rst_sync_meta <= 1'b1;
            rst_sync_n    <= rst_sync_meta;
        end
    end

    // ========================================================================
    // 2. Internal Interconnect Wires
    // ========================================================================
    // Host Dispatcher to Cluster
    logic [127:0] cluster_cmd_desc;
    logic         cluster_cmd_valid;
    logic         cluster_cmd_ready;
    logic         cluster_force_abort;
    logic         cluster_busy;
    logic         cluster_done_irq;
    logic         cluster_err_irq;
    logic [3:0]   cluster_status_flags;

    // Cluster to PIM Subsystem
    logic [127:0] pim_cmd_desc;
    logic         pim_cmd_valid;
    logic         pim_cmd_ready;
    logic [ACT_DATA_W-1:0] pim_act_data;
    logic         pim_act_valid;
    logic         pim_act_ready;
    logic [ACC_DATA_W-1:0] pim_res_data;
    logic         pim_res_valid;
    logic         pim_res_ready;
    logic [31:0]  pim_scalar_dot;
    logic [3:0]   pim_status_flags;
    logic         pim_cg_en;
    logic         pim_busy;
    logic         pim_done_irq;
    logic         pim_err_irq;
    logic [3:0]   pim_err_code;

    // Barrier Lines
    logic [NUM_CORES-1:0] cluster_barrier_req;
    logic                 barrier_release;
    logic                 barrier_busy;
    logic                 stack0_barrier_out;
    logic                 stack1_barrier_out;

    // Cluster Master AXI5 to Arbiter
    logic [AXI_ADDR_W-1:0] c_axi_araddr;
    logic [AXI_ID_W-1:0]   c_axi_arid;
    logic [7:0]            c_axi_arlen;
    logic                  c_axi_arvalid;
    logic                  c_axi_arrdy;

    logic [AXI_DATA_W-1:0] c_axi_rdata;
    logic [AXI_ID_W-1:0]   c_axi_rid;
    logic [1:0]            c_axi_rresp;
    logic                  c_axi_rlast;
    logic                  c_axi_rvalid;
    logic                  c_axi_rrdy;

    logic [AXI_ADDR_W-1:0] c_axi_awaddr;
    logic [AXI_ID_W-1:0]   c_axi_awid;
    logic [7:0]            c_axi_awlen;
    logic                  c_axi_awvalid;
    logic                  c_axi_awrdy;

    logic [AXI_DATA_W-1:0] c_axi_wdata;
    logic [AXI_DATA_W/8-1:0] c_axi_wstrb;
    logic                  c_axi_wlast;
    logic                  c_axi_wvalid;
    logic                  c_axi_wrdy;

    logic [AXI_ID_W-1:0]   c_axi_bid;
    logic [1:0]            c_axi_bresp;
    logic                  c_axi_bvalid;
    logic                  c_axi_brdy;

    // OpenHBM3 SoC Host Slave AXI5 (Multiplexed Host / Cluster)
    logic [AXI_ADDR_W-1:0] soc_s_araddr;
    logic [AXI_ID_W-1:0]   soc_s_arid;
    logic [7:0]            soc_s_arlen;
    logic                  soc_s_arvalid;
    logic                  soc_s_arrdy;

    logic [AXI_DATA_W-1:0] soc_s_rdata;
    logic [AXI_ID_W-1:0]   soc_s_rid;
    logic [1:0]            soc_s_rresp;
    logic                  soc_s_rlast;
    logic                  soc_s_rvalid;
    logic                  soc_s_rrdy;

    logic [AXI_ADDR_W-1:0] soc_s_awaddr;
    logic [AXI_ID_W-1:0]   soc_s_awid;
    logic [7:0]            soc_s_awlen;
    logic                  soc_s_awvalid;
    logic                  soc_s_awrdy;

    logic [AXI_DATA_W-1:0] soc_s_wdata;
    logic [AXI_DATA_W/8-1:0] soc_s_wstrb;
    logic                  soc_s_wlast;
    logic                  soc_s_wvalid;
    logic                  soc_s_wrdy;

    logic [AXI_ID_W-1:0]   soc_s_bid;
    logic [1:0]            soc_s_bresp;
    logic                  soc_s_bvalid;
    logic                  soc_s_brdy;

    // ========================================================================
    // 3. AXI5 Host / Cluster Interposer Arbiter /* verified invariant */
    // ========================================================================
    // Priority: Cluster has priority during active compute, otherwise Host.
    // Preserves atomic burst ownership on W-channel until WLAST.
    typedef enum logic [1:0] {
        ARB_IDLE    = 2'b00,
        ARB_HOST    = 2'b01,
        ARB_CLUSTER = 2'b10
    } arb_owner_t;

    arb_owner_t w_owner_q, w_owner_d;

    // Read Address Channel Arbiter
    wire cluster_ar_active = c_axi_arvalid;
    assign soc_s_araddr   = cluster_ar_active ? c_axi_araddr  : s_host_axi_araddr;
    assign soc_s_arid     = cluster_ar_active ? c_axi_arid    : s_host_axi_arid;
    assign soc_s_arlen    = cluster_ar_active ? c_axi_arlen   : s_host_axi_arlen;
    assign soc_s_arvalid  = cluster_ar_active ? c_axi_arvalid : s_host_axi_arvalid;
    assign c_axi_arrdy    = cluster_ar_active ? soc_s_arrdy   : 1'b0;
    assign s_host_axi_arrdy = !cluster_ar_active ? soc_s_arrdy : 1'b0;

    // Read Data Channel Demux (Routed by ARID / RID tag: Cluster=4'hC)
    wire is_cluster_r = (soc_s_rid == 4'hC);
    assign c_axi_rdata       = soc_s_rdata;
    assign c_axi_rid         = soc_s_rid;
    assign c_axi_rresp       = soc_s_rresp;
    assign c_axi_rlast       = soc_s_rlast;
    assign c_axi_rvalid      = soc_s_rvalid && is_cluster_r;

    assign s_host_axi_rdata  = soc_s_rdata;
    assign s_host_axi_rid    = soc_s_rid;
    assign s_host_axi_rresp  = soc_s_rresp;
    assign s_host_axi_rlast  = soc_s_rlast;
    assign s_host_axi_rvalid = soc_s_rvalid && !is_cluster_r;

    assign soc_s_rrdy        = is_cluster_r ? c_axi_rrdy : s_host_axi_rrdy;

    // Write Address Channel Arbiter with Burst Lock
    wire cluster_aw_active = c_axi_awvalid;
    always_comb begin
        w_owner_d = w_owner_q;
        if (w_owner_q == ARB_IDLE) begin
            if (c_axi_awvalid)     w_owner_d = ARB_CLUSTER;
            else if (s_host_axi_awvalid) w_owner_d = ARB_HOST;
        end else begin
            // Hold ownership until WLAST handshake completes
            if (soc_s_wvalid && soc_s_wrdy && soc_s_wlast) begin
                w_owner_d = ARB_IDLE;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_sync_n) begin
        if (!rst_sync_n) w_owner_q <= ARB_IDLE;
        else             w_owner_q <= w_owner_d;
    end

    wire arb_use_cluster = (w_owner_q == ARB_CLUSTER) || (w_owner_q == ARB_IDLE && cluster_aw_active);

    assign soc_s_awaddr    = arb_use_cluster ? c_axi_awaddr   : s_host_axi_awaddr;
    assign soc_s_awid      = arb_use_cluster ? c_axi_awid     : s_host_axi_awid;
    assign soc_s_awlen     = arb_use_cluster ? c_axi_awlen    : s_host_axi_awlen;
    assign soc_s_awvalid   = arb_use_cluster ? c_axi_awvalid  : s_host_axi_awvalid;
    assign c_axi_awrdy     = arb_use_cluster ? soc_s_awrdy    : 1'b0;
    assign s_host_axi_awrdy= !arb_use_cluster ? soc_s_awrdy   : 1'b0;

    // Write Data Channel
    assign soc_s_wdata     = arb_use_cluster ? c_axi_wdata    : s_host_axi_wdata;
    assign soc_s_wstrb     = arb_use_cluster ? c_axi_wstrb    : s_host_axi_wstrb;
    assign soc_s_wlast     = arb_use_cluster ? c_axi_wlast    : s_host_axi_wlast;
    assign soc_s_wvalid    = arb_use_cluster ? c_axi_wvalid   : s_host_axi_wvalid;
    assign c_axi_wrdy      = arb_use_cluster ? soc_s_wrdy     : 1'b0;
    assign s_host_axi_wrdy = !arb_use_cluster ? soc_s_wrdy    : 1'b0;

    // Write Response Channel Demux (Routed by BID: Cluster=4'hC)
    wire is_cluster_b = (soc_s_bid == 4'hC);
    assign c_axi_bid         = soc_s_bid;
    assign c_axi_bresp       = soc_s_bresp;
    assign c_axi_bvalid      = soc_s_bvalid && is_cluster_b;

    assign s_host_axi_bid    = soc_s_bid;
    assign s_host_axi_bresp  = soc_s_bresp;
    assign s_host_axi_bvalid = soc_s_bvalid && !is_cluster_b;

    assign soc_s_brdy        = is_cluster_b ? c_axi_brdy : s_host_axi_brdy;

    // ========================================================================
    // 4. Host MMIO Command Dispatcher Instance
    // ========================================================================
    ara_host_cmd_dispatcher #(
        .MMIO_ADDR_W(16),
        .MMIO_DATA_W(32)
    ) u_host_dispatcher (
        .clk                  (clk),
        .rst_n                (rst_sync_n),
        .mmio_req_i           (s_host_mmio_req),
        .mmio_we_i            (s_host_mmio_we),
        .mmio_addr_i          (s_host_mmio_addr),
        .mmio_wdata_i         (s_host_mmio_wdata),
        .mmio_rdata_o         (s_host_mmio_rdata),
        .mmio_rvalid_o        (s_host_mmio_rvalid),
        .mmio_ready_o         (s_host_mmio_ready),
        .host_irq_o           (host_irq_o),
        .cluster_cmd_desc_o   (cluster_cmd_desc),
        .cluster_cmd_valid_o  (cluster_cmd_valid),
        .cluster_cmd_ready_i  (cluster_cmd_ready),
        .cluster_force_abort_o(cluster_force_abort),
        .cluster_busy_i       (cluster_busy),
        .cluster_done_irq_i   (cluster_done_irq),
        .cluster_err_irq_i    (cluster_err_irq),
        .cluster_status_flags_i(cluster_status_flags)
    );

    // ========================================================================
    // 5. Global Hardware Barrier Tree Instance
    // ========================================================================
    ara_barrier_tree #(
        .NUM_CORES(NUM_CORES)
    ) u_barrier_tree (
        .clk                 (clk),
        .rst_n               (rst_sync_n),
        .core_barrier_req_i  (cluster_barrier_req),
        .stack_barrier_req_i ({stack1_barrier_out, stack0_barrier_out}),
        .host_barrier_req_i  (1'b0),
        .core_mask_i         ('1),
        .stack_mask_i        (2'b00), // Default stack barrier not blocking core tree
        .host_mask_i         (1'b0),
        .barrier_release_o   (barrier_release),
        .barrier_busy_o      (barrier_busy)
    );

    // ========================================================================
    // 6. Multi-Core Ara Compute Cluster Instance
    // ========================================================================
    ara_multicore_cluster #(
        .NUM_CORES   (NUM_CORES),
        .AXI_DATA_W  (AXI_DATA_W),
        .AXI_ADDR_W  (AXI_ADDR_W),
        .AXI_ID_W    (AXI_ID_W),
        .LANES       (LANES),
        .ACT_DATA_W  (ACT_DATA_W),
        .ACC_DATA_W  (ACC_DATA_W)
    ) u_compute_cluster (
        .clk                       (clk),
        .rst_n                     (rst_sync_n),

        .cluster_cmd_desc_i        (cluster_cmd_desc),
        .cluster_cmd_valid_i       (cluster_cmd_valid),
        .cluster_cmd_ready_o       (cluster_cmd_ready),
        .cluster_force_abort_i     (cluster_force_abort),
        .cluster_ecc_fatal_i       (dram_ecc_fatal_i), // Route DRAM fatal ECC to cluster (Datapath Flush On Abort)

        .cluster_busy_o            (cluster_busy),
        .cluster_done_irq_o        (cluster_done_irq),
        .cluster_err_irq_o         (cluster_err_irq),
        .cluster_status_flags_o    (cluster_status_flags),

        .cluster_barrier_req_o     (cluster_barrier_req),
        .cluster_barrier_release_i (barrier_release),

        .pim_cmd_desc_o            (pim_cmd_desc),
        .pim_cmd_valid_o           (pim_cmd_valid),
        .pim_cmd_ready_i           (pim_cmd_ready),

        .pim_act_data_o            (pim_act_data),
        .pim_act_valid_o           (pim_act_valid),
        .pim_act_ready_i           (pim_act_ready),

        .pim_res_data_i            (pim_res_data),
        .pim_res_valid_i           (pim_res_valid),
        .pim_res_ready_o           (pim_res_ready),
        .pim_done_irq_i            (pim_done_irq),
        .pim_err_irq_i             (pim_err_irq),
        .pim_status_flags_i        (pim_status_flags),

        .m_axi_araddr              (c_axi_araddr),
        .m_axi_arid                (c_axi_arid),
        .m_axi_arlen               (c_axi_arlen),
        .m_axi_arvalid             (c_axi_arvalid),
        .m_axi_arrdy               (c_axi_arrdy),

        .m_axi_rdata               (c_axi_rdata),
        .m_axi_rid                 (c_axi_rid),
        .m_axi_rresp               (c_axi_rresp),
        .m_axi_rlast               (c_axi_rlast),
        .m_axi_rvalid              (c_axi_rvalid),
        .m_axi_rrdy                (c_axi_rrdy),

        .m_axi_awaddr              (c_axi_awaddr),
        .m_axi_awid                (c_axi_awid),
        .m_axi_awlen               (c_axi_awlen),
        .m_axi_awvalid             (c_axi_awvalid),
        .m_axi_awrdy               (c_axi_awrdy),

        .m_axi_wdata               (c_axi_wdata),
        .m_axi_wstrb               (c_axi_wstrb),
        .m_axi_wlast               (c_axi_wlast),
        .m_axi_wvalid              (c_axi_wvalid),
        .m_axi_wrdy                (c_axi_wrdy),

        .m_axi_bid                 (c_axi_bid),
        .m_axi_bresp               (c_axi_bresp),
        .m_axi_bvalid              (c_axi_bvalid),
        .m_axi_brdy                (c_axi_brdy)
    );

    // ========================================================================
    // 7. OpenHBM3 Base-Die PIM Subsystem SoC Instance
    // ========================================================================
    ara_openhbm3_soc_top #(
        .AXI_DATA_W    (AXI_DATA_W),
        .AXI_ADDR_W    (AXI_ADDR_W),
        .AXI_ID_W      (AXI_ID_W),
        .LANES         (LANES),
        .DRAM_DATA_W   (DRAM_DATA_W),
        .ACT_DATA_W    (ACT_DATA_W),
        .ACC_DATA_W    (ACC_DATA_W),
        .TFAW_CYCLES   (TFAW_CYCLES),
        .TWTR_L_CYCLES (TWTR_L_CYCLES),
        .TRTW_CYCLES   (TRTW_CYCLES),
        .WDT_DEFAULT   (WDT_DEFAULT)
    ) u_openhbm3_pim_subsystem (
        .clk_hbm             (clk),
        .rst_async_n         (rst_async_n),

        // Multiplexed Slave Port (Host + Cluster DMA)
        .s_host_axi_araddr   (soc_s_araddr),
        .s_host_axi_arid     (soc_s_arid),
        .s_host_axi_arlen    (soc_s_arlen),
        .s_host_axi_arvalid  (soc_s_arvalid),
        .s_host_axi_arrdy    (soc_s_arrdy),

        .s_host_axi_rdata    (soc_s_rdata),
        .s_host_axi_rid      (soc_s_rid),
        .s_host_axi_rresp    (soc_s_rresp),
        .s_host_axi_rlast    (soc_s_rlast),
        .s_host_axi_rvalid   (soc_s_rvalid),
        .s_host_axi_rrdy     (soc_s_rrdy),

        .s_host_axi_awaddr   (soc_s_awaddr),
        .s_host_axi_awid     (soc_s_awid),
        .s_host_axi_awlen    (soc_s_awlen),
        .s_host_axi_awvalid  (soc_s_awvalid),
        .s_host_axi_awrdy    (soc_s_awrdy),

        .s_host_axi_wdata    (soc_s_wdata),
        .s_host_axi_wstrb    (soc_s_wstrb),
        .s_host_axi_wlast    (soc_s_wlast),
        .s_host_axi_wvalid   (soc_s_wvalid),
        .s_host_axi_wrdy     (soc_s_wrdy),

        .s_host_axi_bid      (soc_s_bid),
        .s_host_axi_bresp    (soc_s_bresp),
        .s_host_axi_bvalid   (soc_s_bvalid),
        .s_host_axi_brdy     (soc_s_brdy),

        // PIM Control & Descriptors (from Cluster)
        .pim_cmd_desc_i      (pim_cmd_desc),
        .pim_cmd_valid_i     (pim_cmd_valid),
        .pim_cmd_ready_o     (pim_cmd_ready),
        .pim_force_abort_i   (cluster_force_abort),

        .pim_act_data_i      (pim_act_data),
        .pim_act_valid_i     (pim_act_valid),
        .pim_act_ready_o     (pim_act_ready),
        .pim_acc_bias_i      ('0), // Initial bias 0

        .pim_res_data_o      (pim_res_data),
        .pim_res_valid_o     (pim_res_valid),
        .pim_res_ready_i     (pim_res_ready),
        .pim_scalar_dot_o    (pim_scalar_dot),
        .pim_status_flags_o  (pim_status_flags),
        .pim_cg_en_o         (pim_cg_en),

        .pim_busy_o          (pim_busy),
        .pim_done_irq_o      (pim_done_irq),
        .pim_err_irq_o       (pim_err_irq),
        .pim_err_code_o      (pim_err_code),

        .dram_refresh_due_i  (dram_refresh_due_i),
        .dram_ecc_fatal_i    (dram_ecc_fatal_i),

        // Stack 0 Master AXI
        .m0_stack_axi_araddr (m0_stack_axi_araddr),
        .m0_stack_axi_arid   (m0_stack_axi_arid),
        .m0_stack_axi_arlen  (m0_stack_axi_arlen),
        .m0_stack_axi_arvalid(m0_stack_axi_arvalid),
        .m0_stack_axi_arrdy  (m0_stack_axi_arrdy),

        .m0_stack_axi_rdata  (m0_stack_axi_rdata),
        .m0_stack_axi_rid    (m0_stack_axi_rid),
        .m0_stack_axi_rresp  (m0_stack_axi_rresp),
        .m0_stack_axi_rlast  (m0_stack_axi_rlast),
        .m0_stack_axi_rvalid (m0_stack_axi_rvalid),
        .m0_stack_axi_rrdy   (m0_stack_axi_rrdy),

        .m0_stack_axi_awaddr (m0_stack_axi_awaddr),
        .m0_stack_axi_awid   (m0_stack_axi_awid),
        .m0_stack_axi_awlen  (m0_stack_axi_awlen),
        .m0_stack_axi_awvalid(m0_stack_axi_awvalid),
        .m0_stack_axi_awrdy  (m0_stack_axi_awrdy),

        .m0_stack_axi_wdata  (m0_stack_axi_wdata),
        .m0_stack_axi_wstrb  (m0_stack_axi_wstrb),
        .m0_stack_axi_wlast  (m0_stack_axi_wlast),
        .m0_stack_axi_wvalid (m0_stack_axi_wvalid),
        .m0_stack_axi_wrdy   (m0_stack_axi_wrdy),

        .m0_stack_axi_bid    (m0_stack_axi_bid),
        .m0_stack_axi_bresp  (m0_stack_axi_bresp),
        .m0_stack_axi_bvalid (m0_stack_axi_bvalid),
        .m0_stack_axi_brdy   (m0_stack_axi_brdy),

        // Stack 1 Master AXI
        .m1_stack_axi_araddr (m1_stack_axi_araddr),
        .m1_stack_axi_arid   (m1_stack_axi_arid),
        .m1_stack_axi_arlen  (m1_stack_axi_arlen),
        .m1_stack_axi_arvalid(m1_stack_axi_arvalid),
        .m1_stack_axi_arrdy  (m1_stack_axi_arrdy),

        .m1_stack_axi_rdata  (m1_stack_axi_rdata),
        .m1_stack_axi_rid    (m1_stack_axi_rid),
        .m1_stack_axi_rresp  (m1_stack_axi_rresp),
        .m1_stack_axi_rlast  (m1_stack_axi_rlast),
        .m1_stack_axi_rvalid (m1_stack_axi_rvalid),
        .m1_stack_axi_rrdy   (m1_stack_axi_rrdy),

        .m1_stack_axi_awaddr (m1_stack_axi_awaddr),
        .m1_stack_axi_awid   (m1_stack_axi_awid),
        .m1_stack_axi_awlen  (m1_stack_axi_awlen),
        .m1_stack_axi_awvalid(m1_stack_axi_awvalid),
        .m1_stack_axi_awrdy  (m1_stack_axi_awrdy),

        .m1_stack_axi_wdata  (m1_stack_axi_wdata),
        .m1_stack_axi_wstrb  (m1_stack_axi_wstrb),
        .m1_stack_axi_wlast  (m1_stack_axi_wlast),
        .m1_stack_axi_wvalid (m1_stack_axi_wvalid),
        .m1_stack_axi_wrdy   (m1_stack_axi_wrdy),

        .m1_stack_axi_bid    (m1_stack_axi_bid),
        .m1_stack_axi_bresp  (m1_stack_axi_bresp),
        .m1_stack_axi_bvalid (m1_stack_axi_bvalid),
        .m1_stack_axi_brdy   (m1_stack_axi_brdy),

        // P2P Interposer Ports
        .p2p_s0_tx_data_i    (p2p_s0_tx_data_i),
        .p2p_s0_tx_valid_i   (p2p_s0_tx_valid_i),
        .p2p_s0_tx_ready_o   (p2p_s0_tx_ready_o),
        .p2p_s1_rx_data_o    (p2p_s1_rx_data_o),
        .p2p_s1_rx_valid_o   (p2p_s1_rx_valid_o),
        .p2p_s1_rx_ready_i   (p2p_s1_rx_ready_i),

        .p2p_s1_tx_data_i    (p2p_s1_tx_data_i),
        .p2p_s1_tx_valid_i   (p2p_s1_tx_valid_i),
        .p2p_s1_tx_ready_o   (p2p_s1_tx_ready_o),
        .p2p_s0_rx_data_o    (p2p_s0_rx_data_o),
        .p2p_s0_rx_valid_o   (p2p_s0_rx_valid_o),
        .p2p_s0_rx_ready_i   (p2p_s0_rx_ready_i),

        .stack0_barrier_out_o(stack0_barrier_out),
        .stack0_barrier_in_i (1'b0),
        .stack1_barrier_out_o(stack1_barrier_out),
        .stack1_barrier_in_i (1'b0)
    );

    // Top-Level Status Assignment
    assign system_busy_o         = cluster_busy || pim_busy || barrier_busy;
    assign system_done_irq_o     = cluster_done_irq;
    assign system_err_irq_o      = cluster_err_irq || pim_err_irq; // Include PIM subsystem error IRQ /* verified invariant */
    assign system_status_flags_o = cluster_status_flags | pim_status_flags;

endmodule
