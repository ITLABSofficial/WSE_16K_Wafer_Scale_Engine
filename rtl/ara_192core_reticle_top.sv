// ============================================================================
// File: ara_192core_reticle_top.sv
// Project: Ara_MultiCore_WSE_HBM3
// Architecture: 192-Core High-Density Reticle SoC (8x6 NoC Mesh Grid)
// Technology: ASAP7 7nm FinFET Predictive PDK (2.0 GHz Target)
// Specification: Architectural Invariants & Verification Standards
// Defensive Rules: ARCHITECTURE.md compliance
//
// Description:
//   Flagship 192-Core Reticle-Limit AI Accelerator SoC:
//     - 192 Ara VPU Cores across 48 Compute Tiles (8x6 2D-Mesh Grid)
//     - 3,072 Systolic Vector Matrix Engines (16 PEs per Core x 192 Cores)
//     - 196.6 TFLOPS FP32 / 393.2 TOPS INT8 Compute Throughput at 2.0 GHz
//     - 6.144 MB Distributed L1 TCDM SRAM (48 Clusters x 32 Banks x 4 KB)
//     - 6x JEDEC HBM3 Stacks (192 GB Capacity, 3.53 TB/s Aggregate Bandwidth)
//     - Dual PCIe Gen5 x16 DMA Controllers (128 GB/s Bi-Directional Host Fabric)
//     - 48-Domain Staggered PDN Inrush Controller & GaN IVR Power Stage
//     - Distributed Digital Thermal (DTS) & Voltage Droop (DVS) Sensor Mesh
//     - Central Non-Blocking Telemetry Hub with Lossless FIFO & CRC-8 Verification
// ============================================================================

`timescale 1ps/1ps

module ara_192core_reticle_top #(
    parameter int unsigned GRID_X         = 8,
    parameter int unsigned GRID_Y         = 6,
    parameter int unsigned CORES_PER_TILE = 4,  // 8 x 6 x 4 = 192 Cores
    parameter int unsigned NUM_STACKS     = 6,  // 6 Stacks HBM3
    parameter int unsigned AXI_ADDR_W     = 40,
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
    // Wafer Defect Mask per Tile (8x6 = 48 Tiles)
    // ------------------------------------------------------------------------
    input  logic [GRID_X-1:0][GRID_Y-1:0] defect_mask_i,

    // ------------------------------------------------------------------------
    // Physical Environmental Stimulus (AMS Co-Sim / Silicon Calibration)
    // ------------------------------------------------------------------------
    input  logic [15:0]                  sim_ambient_temp_i,
    input  logic [11:0]                  sim_rail_vdd_i,
    input  logic                         sim_override_en_i,

    // ------------------------------------------------------------------------
    // Host MSI-X Interrupts & System Telemetry
    // ------------------------------------------------------------------------
    output logic                         soc_done_irq_o,
    output logic                         soc_err_irq_o,
    output logic                         soc_busy_o,
    output logic [3:0]                   soc_status_flags_o,
    output logic [GRID_X*GRID_Y-1:0]     pdn_domain_en_o,
    output logic                         pdn_safe_o,

    // Real-Time Hardware Sensor & Telemetry Telemetry
    output logic [15:0]                  max_junction_temp_q8_8_o,
    output logic [11:0]                  min_rail_voltage_mv_o,
    output logic                         irq_thermal_alert_o,
    output logic                         irq_voltage_droop_o,
    output logic                         emergency_choke_active_o
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
    // 2. MMIO Demux:
    //    0x0000..0x0FFF: Command Dispatcher & Task Queue
    //    0x1000..0x1FFF: PCIe Gen5 DMA Engine Controller
    //    0x2000..0x2FFF: Central On-Die Telemetry Hub (DTS/DVS/IVR)
    // ========================================================================
    wire is_dma_mmio   = (s_pcie_mmio_addr_i[15:12] == 4'h1);
    wire is_telem_mmio = (s_pcie_mmio_addr_i[15:12] == 4'h2);
    wire is_wse_mmio   = (s_pcie_mmio_addr_i[15:12] == 4'h0);

    // DMA MMIO Signals
    logic [31:0] dma_mmio_rdata;
    logic        dma_mmio_rvalid;
    logic        dma_mmio_ready;
    logic        dma_done_irq;
    logic        dma_err_irq;
    logic        dma_busy;

    // Telemetry Hub MMIO Signals
    logic [31:0] telem_mmio_rdata;
    logic        telem_mmio_rvalid;
    logic        telem_mmio_ready;

    // Cluster Top MMIO Signals
    logic [31:0] wse_mmio_rdata;
    logic        wse_done_irq;
    logic        wse_err_irq;
    logic        wse_busy;
    logic [3:0]  wse_status_flags;

    always_comb begin
        if (is_dma_mmio) begin
            s_pcie_mmio_rdata_o  = dma_mmio_rdata;
            s_pcie_mmio_rvalid_o = dma_mmio_rvalid;
            s_pcie_mmio_ready_o  = dma_mmio_ready;
        end else if (is_telem_mmio) begin
            s_pcie_mmio_rdata_o  = telem_mmio_rdata;
            s_pcie_mmio_rvalid_o = telem_mmio_rvalid;
            s_pcie_mmio_ready_o  = telem_mmio_ready;
        end else begin
            s_pcie_mmio_rdata_o  = wse_mmio_rdata;
            s_pcie_mmio_rvalid_o = 1'b1;
            s_pcie_mmio_ready_o  = 1'b1;
        end
    end

    // ========================================================================
    // 3. PCIe Gen5 x16 DMA Engine Instantiation
    // ========================================================================
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
        .active_channel_mask_o ()
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
    // 5. 192-Core (8x6 Mesh) Compute Grid Top Instantiation
    // ========================================================================
    logic [GRID_X*GRID_Y-1:0] mesh_pdn_domain_en;
    logic                     mesh_pdn_safe;

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
    ) u_192core_mesh (
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
        .pdn_domain_en_o     (mesh_pdn_domain_en),
        .pdn_safe_o          (mesh_pdn_safe)
    );

    assign pdn_domain_en_o = mesh_pdn_domain_en;
    assign pdn_safe_o      = mesh_pdn_safe;

    // ========================================================================
    // 6. DISTRIBUTED ON-DIE SENSORS & TELEMETRY HUB (DTS, DVS, IVR)
    // ========================================================================
    localparam int unsigned NUM_TOTAL_SENSORS = 4; // Representative telemetry channels (DTS, DVS, IVR, Ambient)

    logic [NUM_TOTAL_SENSORS-1:0]        hub_telem_valid;
    logic [NUM_TOTAL_SENSORS-1:0][31:0]  hub_telem_data;
    logic [NUM_TOTAL_SENSORS-1:0]        hub_telem_ready;

    // A. Digital Thermal Sensor Macro (DTS)
    logic [15:0] dts_temp_q8_8;
    logic        dts_alert_warn;
    logic        dts_alert_hot;
    logic        dts_alert_panic;
    logic        dts_clk_gate;
    logic        dts_choke;

    ara_digital_thermal_sensor #(
        .SENSOR_ID          (8'h01),
        .REF_WINDOW_CYCLES  (64),
        .DEFAULT_TH_WARN    (16'h5F00), // 95 C
        .DEFAULT_TH_HOT     (16'h6E00), // 110 C
        .DEFAULT_TH_PANIC   (16'h7D00)  // 125 C
    ) u_thermal_sensor (
        .clk                    (clk),
        .rst_n                  (rst_sync_n),
        .cfg_we_i               (1'b0),
        .cfg_th_warn_i          (16'h0),
        .cfg_th_hot_i           (16'h0),
        .cfg_th_panic_i         (16'h0),
        .cfg_throttle_mode_i    (2'b10),
        .sim_junction_temp_i    (sim_ambient_temp_i),
        .sim_temp_override_en_i (sim_override_en_i),
        .temp_q8_8_o            (dts_temp_q8_8),
        .temp_valid_o           (),
        .alert_warn_o           (dts_alert_warn),
        .alert_hot_o            (dts_alert_hot),
        .alert_panic_o          (dts_alert_panic),
        .throttle_clk_gate_o    (dts_clk_gate),
        .emergency_choke_o      (dts_choke),
        .telem_valid_o          (hub_telem_valid[0]),
        .telem_data_o           (hub_telem_data[0]),
        .telem_ready_i          (hub_telem_ready[0])
    );

    // B. Digital Voltage Droop Sensor Macro (DVS)
    logic [11:0] dvs_vdd_mv;
    logic [1:0]  dvs_droop_level;
    logic        dvs_droop_alert;
    logic        dvs_stretch_req;
    logic        dvs_ivr_boost_req;

    ara_digital_voltage_sensor #(
        .SENSOR_ID          (8'h02),
        .NOMINAL_VDD_MV     (12'd700),
        .DROOP_WARN_MV      (12'd650),
        .DROOP_CRIT_MV      (12'd600)
    ) u_voltage_sensor (
        .clk                    (clk),
        .rst_n                  (rst_sync_n),
        .cfg_we_i               (1'b0),
        .cfg_droop_warn_mv_i    (12'h0),
        .cfg_droop_crit_mv_i    (12'h0),
        .cfg_stretch_en_i       (1'b1),
        .sim_vdd_mv_i           (sim_rail_vdd_i),
        .sim_vdd_override_en_i  (sim_override_en_i),
        .vdd_mv_o               (dvs_vdd_mv),
        .droop_level_o          (dvs_droop_level),
        .droop_alert_o          (dvs_droop_alert),
        .stretch_req_o          (dvs_stretch_req),
        .ivr_boost_req_o        (dvs_ivr_boost_req),
        .telem_valid_o          (hub_telem_valid[1]),
        .telem_data_o           (hub_telem_data[1]),
        .telem_ready_i          (hub_telem_ready[1])
    );

    // C. Integrated Voltage Regulator Power Stage (IVR)
    logic [11:0] ivr_est_vdd_mv;
    logic [4:0]  ivr_active_phases;
    logic        ivr_rail_stable;

    ara_ivr_power_stage #(
        .RAIL_ID            (8'h03),
        .NUM_PHASES         (16),
        .TARGET_VDD_MV      (12'd700)
    ) u_ivr_power_stage (
        .clk                    (clk),
        .rst_n                  (rst_sync_n),
        .ivr_boost_req_i        (dvs_ivr_boost_req),
        .droop_level_i          (dvs_droop_level),
        .enable_i               (1'b1),
        .cfg_min_phases_i       (4'd4),
        .estimated_vdd_mv_o     (ivr_est_vdd_mv),
        .active_phases_o        (ivr_active_phases),
        .rail_stable_o          (ivr_rail_stable),
        .telem_valid_o          (hub_telem_valid[2]),
        .telem_data_o           (hub_telem_data[2]),
        .telem_ready_i          (hub_telem_ready[2])
    );

    // Tie off 4th channel
    assign hub_telem_valid[3] = 1'b0;
    assign hub_telem_data[3]  = 32'h0;

    // D. Central On-Die Telemetry Hub
    logic hub_irq_thermal;
    logic hub_irq_voltage;
    logic hub_global_choke;

    ara_telemetry_hub #(
        .NUM_SENSORS (NUM_TOTAL_SENSORS),
        .FIFO_DEPTH  (64)
    ) u_telemetry_hub (
        .clk                     (clk),
        .rst_n                   (rst_sync_n),
        .s_telem_valid_i         (hub_telem_valid),
        .s_telem_data_i          (hub_telem_data),
        .s_telem_ready_o         (hub_telem_ready),
        .irq_thermal_crit_o      (hub_irq_thermal),
        .irq_voltage_droop_o     (hub_irq_voltage),
        .global_emergency_choke_o(hub_global_choke),
        .mmio_req_i              (s_pcie_mmio_req_i && is_telem_mmio),
        .mmio_we_i               (s_pcie_mmio_we_i),
        .mmio_addr_i             (s_pcie_mmio_addr_i),
        .mmio_wdata_i            (s_pcie_mmio_wdata_i),
        .mmio_rdata_o            (telem_mmio_rdata),
        .mmio_rvalid_o           (telem_mmio_rvalid),
        .mmio_ready_o            (telem_mmio_ready)
    );

    // Sensor Outputs to Top Level
    assign max_junction_temp_q8_8_o = dts_temp_q8_8;
    assign min_rail_voltage_mv_o    = dvs_vdd_mv;
    assign irq_thermal_alert_o      = hub_irq_thermal || dts_alert_hot || dts_alert_panic;
    assign irq_voltage_droop_o      = hub_irq_voltage || dvs_droop_alert;
    assign emergency_choke_active_o = hub_global_choke || dts_choke;

    // ========================================================================
    // 7. Aggregate System Status & Interrupts
    // ========================================================================
    assign soc_done_irq_o     = wse_done_irq || dma_done_irq;
    assign soc_err_irq_o      = wse_err_irq  || dma_err_irq || emergency_choke_active_o;
    assign soc_busy_o         = wse_busy     || dma_busy;
    assign soc_status_flags_o = wse_status_flags | {dma_err_irq || emergency_choke_active_o, irq_thermal_alert_o, dma_busy, irq_voltage_droop_o};

endmodule
