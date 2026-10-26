// ============================================================================
// File: ara_64core_durum_b_top.sv
// Project: Ara_MultiCore_WSE_HBM3 (DURUM B+: 64-Core 4x4 NoC + 128 GB HBM3e SoC)
// Technology: ASAP7 7nm FinFET Predictive PDK (Target: 2.0 GHz / 500 ps cycle)
// Specification: Architectural Invariants & Verification Standards
// Architectural Invariants & Verification Standards
//
// Description:
//   Flagship SoC Top-Level Architecture for DURUM B+:
//     - 64 Ara VPU Cores across 16 Compute Tiles (4x4 2D-Mesh Grid)
//     - 1,024 Vector Lanes (16 Lanes per Core x 64 Cores)
//     - 64x 16x16 Systolic Matrix Tensor Engines (512 FLOP/cycle per Core)
//     - 128 GB JEDEC HBM3e Subsystem (4 Stacks x 32 GB, 16 Pseudo-Channels each)
//     - 4x Base-Die PIM (Processing-In-Memory) Scaled Reduction Engines
//     - PCIe Gen5 x16 DMA Engine with Hardware Watchdog Timer (Anti-Hang WDT)
//     - 16-Domain Power Distribution Network (PDN) Inrush Stagger Controller
//     - 16-Leaf Binary Reduction Barrier Tree
// ============================================================================

`timescale 1ps/1ps

module ara_64core_durum_b_top #(
    parameter int unsigned GRID_X         = 4,
    parameter int unsigned GRID_Y         = 4,
    parameter int unsigned CORES_PER_TILE = 4,  // 4 x 4 x 4 = 64 Cores
    parameter int unsigned NUM_STACKS     = 4,  // 4 Stacks = 128 GB HBM3e
    parameter int unsigned AXI_ADDR_W     = 40, // 1 TB Address Space
    parameter int unsigned AXI_DATA_W     = 256,
    parameter int unsigned AXI_ID_W       = 4,
    parameter int unsigned FLIT_W         = 544,
    parameter bit          ENABLE_GALS    = 0,
    parameter bit          ENABLE_PDN     = 1
)(
    input  logic                         clk,
    input  logic                         clk_gals,
    input  logic                         rst_async_n,

    // ------------------------------------------------------------------------
    // PCIe Gen5 x16 Host BAR0 MMIO Interface (Slave)
    // ------------------------------------------------------------------------
    input  logic                         s_pcie_mmio_req_i,
    input  logic                         s_pcie_mmio_we_i,
    input  logic [15:0]                  s_pcie_mmio_addr_i,
    input  logic [31:0]                  s_pcie_mmio_wdata_i,
    output logic [31:0]                  s_pcie_mmio_rdata_o,
    output logic                         s_pcie_mmio_rvalid_o,
    output logic                         s_pcie_mmio_ready_o,

    // ------------------------------------------------------------------------
    // PCIe Host Direct DMA AXI5 Slave Port
    // ------------------------------------------------------------------------
    input  logic [AXI_ADDR_W-1:0]        s_pcie_axi_araddr_i,
    input  logic [AXI_ID_W-1:0]          s_pcie_axi_arid_i,
    input  logic [7:0]                   s_pcie_axi_arlen_i,
    input  logic                         s_pcie_axi_arvalid_i,
    output logic                         s_pcie_axi_arrdy_o,
    output logic [AXI_DATA_W-1:0]        s_pcie_axi_rdata_o,
    output logic [AXI_ID_W-1:0]          s_pcie_axi_rid_o,
    output logic [1:0]                   s_pcie_axi_rresp_o,
    output logic                         s_pcie_axi_rlast_o,
    output logic                         s_pcie_axi_rvalid_o,
    input  logic                         s_pcie_axi_rrdy_i,

    input  logic [AXI_ADDR_W-1:0]        s_pcie_axi_awaddr_i,
    input  logic [AXI_ID_W-1:0]          s_pcie_axi_awid_i,
    input  logic [7:0]                   s_pcie_axi_awlen_i,
    input  logic                         s_pcie_axi_awvalid_i,
    output logic                         s_pcie_axi_awrdy_o,
    input  logic [AXI_DATA_W-1:0]        s_pcie_axi_wdata_i,
    input  logic [(AXI_DATA_W/8)-1:0]    s_pcie_axi_wstrb_i,
    input  logic                         s_pcie_axi_wlast_i,
    input  logic                         s_pcie_axi_wvalid_i,
    output logic                         s_pcie_axi_wrdy_o,
    output logic [AXI_ID_W-1:0]          s_pcie_axi_bid_o,
    output logic [1:0]                   s_pcie_axi_bresp_o,
    output logic                         s_pcie_axi_bvalid_o,
    input  logic                         s_pcie_axi_bready_i,

    // ------------------------------------------------------------------------
    // Wafer Defect Mask per Tile (4x4)
    // ------------------------------------------------------------------------
    input  logic [GRID_X-1:0][GRID_Y-1:0] defect_mask_i,

    // ------------------------------------------------------------------------
    // Host MSI-X Interrupts & System Telemetry
    // ------------------------------------------------------------------------
    output logic                         soc_done_irq_o,
    output logic                         soc_err_irq_o,
    output logic                         soc_busy_o,
    output logic [3:0]                   soc_status_flags_o,
    output logic [GRID_X*GRID_Y-1:0]     pdn_domain_en_o,
    output logic                         pdn_safe_o
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
    // 2. MMIO Demux: Dispatcher (0x0000..0x0FFF) vs PCIe DMA (0x1000..0x1FFF)
    // ========================================================================
    wire is_dma_mmio  = (s_pcie_mmio_addr_i[15:12] == 4'h1);
    wire is_wse_mmio  = (s_pcie_mmio_addr_i[15:12] == 4'h0);

    // DMA MMIO Signals
    logic [31:0] dma_mmio_rdata;
    logic        dma_mmio_rvalid;
    logic        dma_mmio_ready;
    logic        dma_done_irq;
    logic        dma_err_irq;
    logic        dma_busy;
    logic [3:0]  dma_active_channels;

    // Cluster Top MMIO Signals
    logic [31:0] wse_mmio_rdata;
    logic        wse_done_irq;
    logic        wse_err_irq;
    logic        wse_busy;
    logic [3:0]  wse_status_flags;

    assign s_pcie_mmio_rdata_o  = is_dma_mmio ? dma_mmio_rdata : wse_mmio_rdata;
    assign s_pcie_mmio_rvalid_o = is_dma_mmio ? dma_mmio_rvalid : 1'b1;
    assign s_pcie_mmio_ready_o  = is_dma_mmio ? dma_mmio_ready : 1'b1;

    // ========================================================================
    // 3. PCIe Gen5 x16 DMA Engine Instantiation
    // ========================================================================
    // DMA AXI5 Master Signals
    logic [AXI_ADDR_W-1:0]     dma_axi_araddr;
    logic [AXI_ID_W-1:0]       dma_axi_arid;
    logic [7:0]                dma_axi_arlen;
    logic [2:0]                dma_axi_arsize;
    logic [1:0]                dma_axi_arburst;
    logic                      dma_axi_arvalid;
    logic                      dma_axi_arready;
    logic [AXI_DATA_W-1:0]     dma_axi_rdata;
    logic [AXI_ID_W-1:0]       dma_axi_rid;
    logic [1:0]                dma_axi_rresp;
    logic                      dma_axi_rlast;
    logic                      dma_axi_rvalid;
    logic                      dma_axi_rready;

    logic [AXI_ADDR_W-1:0]     dma_axi_awaddr;
    logic [AXI_ID_W-1:0]       dma_axi_awid;
    logic [7:0]                dma_axi_awlen;
    logic [2:0]                dma_axi_awsize;
    logic [1:0]                dma_axi_awburst;
    logic                      dma_axi_awvalid;
    logic                      dma_axi_awready;
    logic [AXI_DATA_W-1:0]     dma_axi_wdata;
    logic [(AXI_DATA_W/8)-1:0] dma_axi_wstrb;
    logic                      dma_axi_wlast;
    logic                      dma_axi_wvalid;
    logic                      dma_axi_wready;
    logic [AXI_ID_W-1:0]       dma_axi_bid;
    logic [1:0]                dma_axi_bresp;
    logic                      dma_axi_bvalid;
    logic                      dma_axi_bready;

    ara_pcie_dma_engine #(
        .AXI_ADDR_W  (AXI_ADDR_W),
        .AXI_DATA_W  (AXI_DATA_W),
        .AXI_ID_W    (AXI_ID_W),
        .NUM_CHANNELS(4),
        .DEFAULT_WDT (65535)
    ) u_dma_engine (
        .clk                   (clk),
        .rst_n                 (rst_sync_n),
        .mmio_req_i            (s_pcie_mmio_req_i && is_dma_mmio),
        .mmio_we_i             (s_pcie_mmio_we_i),
        .mmio_addr_i           (s_pcie_mmio_addr_i),
        .mmio_wdata_i          (s_pcie_mmio_wdata_i),
        .mmio_rdata_o          (dma_mmio_rdata),
        .mmio_rvalid_o         (dma_mmio_rvalid),
        .mmio_ready_o          (dma_mmio_ready),
        .m_axi_araddr          (dma_axi_araddr),
        .m_axi_arid            (dma_axi_arid),
        .m_axi_arlen           (dma_axi_arlen),
        .m_axi_arsize          (dma_axi_arsize),
        .m_axi_arburst         (dma_axi_arburst),
        .m_axi_arvalid         (dma_axi_arvalid),
        .m_axi_arready         (dma_axi_arready),
        .m_axi_rdata           (dma_axi_rdata),
        .m_axi_rid             (dma_axi_rid),
        .m_axi_rresp           (dma_axi_rresp),
        .m_axi_rlast           (dma_axi_rlast),
        .m_axi_rvalid          (dma_axi_rvalid),
        .m_axi_rready          (dma_axi_rready),
        .m_axi_awaddr          (dma_axi_awaddr),
        .m_axi_awid            (dma_axi_awid),
        .m_axi_awlen           (dma_axi_awlen),
        .m_axi_awsize          (dma_axi_awsize),
        .m_axi_awburst         (dma_axi_awburst),
        .m_axi_awvalid         (dma_axi_awvalid),
        .m_axi_awready         (dma_axi_awready),
        .m_axi_wdata           (dma_axi_wdata),
        .m_axi_wstrb           (dma_axi_wstrb),
        .m_axi_wlast           (dma_axi_wlast),
        .m_axi_wvalid          (dma_axi_wvalid),
        .m_axi_wready          (dma_axi_wready),
        .m_axi_bid             (dma_axi_bid),
        .m_axi_bresp           (dma_axi_bresp),
        .m_axi_bvalid          (dma_axi_bvalid),
        .m_axi_bready          (dma_axi_bready),
        .msix_done_irq_o       (dma_done_irq),
        .msix_err_irq_o        (dma_err_irq),
        .dma_busy_o            (dma_busy),
        .active_channel_mask_o (dma_active_channels)
    );

    // ========================================================================
    // 4. AXI5 Master Arbitrator: PCIe Direct Slave vs DMA Engine Master
    // ========================================================================
    logic [AXI_ADDR_W-1:0]     wse_axi_araddr;
    logic [AXI_ID_W-1:0]       wse_axi_arid;
    logic [7:0]                wse_axi_arlen;
    logic                      wse_axi_arvalid;
    logic                      wse_axi_arrdy;
    logic [AXI_DATA_W-1:0]     wse_axi_rdata;
    logic [AXI_ID_W-1:0]       wse_axi_rid;
    logic [1:0]                wse_axi_rresp;
    logic                      wse_axi_rlast;
    logic                      wse_axi_rvalid;
    logic                      wse_axi_rrdy;

    logic [AXI_ADDR_W-1:0]     wse_axi_awaddr;
    logic [AXI_ID_W-1:0]       wse_axi_awid;
    logic [7:0]                wse_axi_awlen;
    logic                      wse_axi_awvalid;
    logic                      wse_axi_awrdy;
    logic [AXI_DATA_W-1:0]     wse_axi_wdata;
    logic [(AXI_DATA_W/8)-1:0] wse_axi_wstrb;
    logic                      wse_axi_wlast;
    logic                      wse_axi_wvalid;
    logic                      wse_axi_wrdy;
    logic [AXI_ID_W-1:0]       wse_axi_bid;
    logic [1:0]                wse_axi_bresp;
    logic                      wse_axi_bvalid;
    logic                      wse_axi_bready;

    // Arbitration: Priority to DMA engine throughout entire split-phase transaction, else direct Host slave
    wire dma_req_active = dma_busy || dma_axi_arvalid || dma_axi_awvalid || dma_axi_wvalid;

    assign wse_axi_araddr   = dma_req_active ? dma_axi_araddr : s_pcie_axi_araddr_i;
    assign wse_axi_arid     = dma_req_active ? dma_axi_arid   : s_pcie_axi_arid_i;
    assign wse_axi_arlen    = dma_req_active ? dma_axi_arlen  : s_pcie_axi_arlen_i;
    assign wse_axi_arvalid  = dma_req_active ? dma_axi_arvalid: s_pcie_axi_arvalid_i;
    assign dma_axi_arready  = dma_req_active ? wse_axi_arrdy  : 1'b0;
    assign s_pcie_axi_arrdy_o = !dma_req_active ? wse_axi_arrdy: 1'b0;

    assign dma_axi_rdata    = wse_axi_rdata;
    assign dma_axi_rid      = wse_axi_rid;
    assign dma_axi_rresp    = wse_axi_rresp;
    assign dma_axi_rlast    = wse_axi_rlast;
    assign dma_axi_rvalid   = dma_req_active && wse_axi_rvalid;
    assign s_pcie_axi_rdata_o  = wse_axi_rdata;
    assign s_pcie_axi_rid_o    = wse_axi_rid;
    assign s_pcie_axi_rresp_o  = wse_axi_rresp;
    assign s_pcie_axi_rlast_o  = wse_axi_rlast;
    assign s_pcie_axi_rvalid_o = !dma_req_active && wse_axi_rvalid;
    assign wse_axi_rrdy     = dma_req_active ? dma_axi_rready : s_pcie_axi_rrdy_i;

    assign wse_axi_awaddr   = dma_req_active ? dma_axi_awaddr : s_pcie_axi_awaddr_i;
    assign wse_axi_awid     = dma_req_active ? dma_axi_awid   : s_pcie_axi_awid_i;
    assign wse_axi_awlen    = dma_req_active ? dma_axi_awlen  : s_pcie_axi_awlen_i;
    assign wse_axi_awvalid  = dma_req_active ? dma_axi_awvalid: s_pcie_axi_awvalid_i;
    assign dma_axi_awready  = dma_req_active ? wse_axi_awrdy  : 1'b0;
    assign s_pcie_axi_awrdy_o = !dma_req_active ? wse_axi_awrdy: 1'b0;

    assign wse_axi_wdata    = dma_req_active ? dma_axi_wdata  : s_pcie_axi_wdata_i;
    assign wse_axi_wstrb    = dma_req_active ? dma_axi_wstrb  : s_pcie_axi_wstrb_i;
    assign wse_axi_wlast    = dma_req_active ? dma_axi_wlast  : s_pcie_axi_wlast_i;
    assign wse_axi_wvalid   = dma_req_active ? dma_axi_wvalid : s_pcie_axi_wvalid_i;
    assign dma_axi_wready   = dma_req_active ? wse_axi_wrdy   : 1'b0;
    assign s_pcie_axi_wrdy_o = !dma_req_active ? wse_axi_wrdy : 1'b0;

    assign dma_axi_bid      = wse_axi_bid;
    assign dma_axi_bresp    = wse_axi_bresp;
    assign dma_axi_bvalid   = dma_req_active && wse_axi_bvalid;
    assign s_pcie_axi_bid_o = wse_axi_bid;
    assign s_pcie_axi_bresp_o = wse_axi_bresp;
    assign s_pcie_axi_bvalid_o= !dma_req_active && wse_axi_bvalid;
    assign wse_axi_bready   = dma_req_active ? dma_axi_bready : s_pcie_axi_bready_i;

    // ========================================================================
    // 5. 64-Core (4x4 Mesh) Compute Grid Top Instantiation
    // ========================================================================
    ara_wse_multi_cluster_top #(
        .GRID_X        (GRID_X),
        .GRID_Y        (GRID_Y),
        .CORES_PER_TILE(CORES_PER_TILE),
        .AXI_ADDR_W    (AXI_ADDR_W),
        .AXI_DATA_W    (AXI_DATA_W),
        .AXI_ID_W      (AXI_ID_W),
        .FLIT_W        (FLIT_W),
        .ENABLE_GALS   (ENABLE_GALS),
        .ENABLE_PDN    (ENABLE_PDN)
    ) u_64core_mesh (
        .clk                 (clk),
        .clk_gals            (clk_gals),
        .rst_async_n         (rst_async_n),

        // Host MMIO
        .s_host_mmio_addr_i  ({16'h0, s_pcie_mmio_addr_i}),
        .s_host_mmio_wdata_i (s_pcie_mmio_wdata_i),
        .s_host_mmio_write_i (s_pcie_mmio_req_i && s_pcie_mmio_we_i && is_wse_mmio),
        .s_host_mmio_rdata_o (wse_mmio_rdata),
        .s_host_mmio_read_i  (s_pcie_mmio_req_i && !s_pcie_mmio_we_i && is_wse_mmio),

        // Host Direct AXI5 Slave
        .s_host_axi_araddr_i (wse_axi_araddr),
        .s_host_axi_arid_i   (wse_axi_arid),
        .s_host_axi_arlen_i  (wse_axi_arlen),
        .s_host_axi_arvalid_i(wse_axi_arvalid),
        .s_host_axi_arrdy_o  (wse_axi_arrdy),
        .s_host_axi_rdata_o  (wse_axi_rdata),
        .s_host_axi_rid_o    (wse_axi_rid),
        .s_host_axi_rresp_o  (wse_axi_rresp),
        .s_host_axi_rlast_o  (wse_axi_rlast),
        .s_host_axi_rvalid_o (wse_axi_rvalid),
        .s_host_axi_rrdy_i   (wse_axi_rrdy),

        .s_host_axi_awaddr_i (wse_axi_awaddr),
        .s_host_axi_awid_i   (wse_axi_awid),
        .s_host_axi_awlen_i  (wse_axi_awlen),
        .s_host_axi_awvalid_i(wse_axi_awvalid),
        .s_host_axi_awrdy_o  (wse_axi_awrdy),
        .s_host_axi_wdata_i  (wse_axi_wdata),
        .s_host_axi_wstrb_i  (wse_axi_wstrb),
        .s_host_axi_wlast_i  (wse_axi_wlast),
        .s_host_axi_wvalid_i (wse_axi_wvalid),
        .s_host_axi_wrdy_o   (wse_axi_wrdy),
        .s_host_axi_bid_o    (wse_axi_bid),
        .s_host_axi_bresp_o  (wse_axi_bresp),
        .s_host_axi_bvalid_o (wse_axi_bvalid),
        .s_host_axi_bready_i (wse_axi_bready),

        // Defect Mask & Telemetry
        .defect_mask_i       (defect_mask_i),
        .wse_busy_o          (wse_busy),
        .wse_done_irq_o      (wse_done_irq),
        .wse_err_irq_o       (wse_err_irq),
        .wse_status_flags_o  (wse_status_flags),
        .pdn_domain_en_o     (pdn_domain_en_o),
        .pdn_safe_o          (pdn_safe_o)
    );

    // ========================================================================
    // 6. Aggregate System Status & Interrupts
    // ========================================================================
    assign soc_done_irq_o     = wse_done_irq || dma_done_irq;
    assign soc_err_irq_o      = wse_err_irq  || dma_err_irq;
    assign soc_busy_o         = wse_busy     || dma_busy;
    assign soc_status_flags_o = wse_status_flags | {dma_err_irq, 1'b0, dma_busy, 1'b0};

endmodule
