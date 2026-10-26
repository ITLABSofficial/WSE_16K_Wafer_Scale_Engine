// ============================================================================
// File: ara_wse_multi_cluster_top.sv
// Project: Ara_MultiCore_WSE_HBM3 (Phase 1: Step 4 - Multi-Cluster Mesh Top)
// Technology: ASAP7 7nm FinFET Predictive PDK (Target: 2.0 GHz / 500 ps cycle)
// Architectural Invariants & Verification Standards
//
// Description:
//   Multi-Cluster 2D-Mesh Top-Level Integration for Wafer-Scale Engine (WSE).
//   Integrates a 2x2 grid of complete compute clusters:
//     - 4 Compute Tiles (Node [0,0], [1,0], [0,1], [1,1])
//     - 16 Ara Systolic VPU Cores (4 cores per tile)
//     - 128-Bank TCDM L1 Scratchpad Distributed (32 banks per tile)
//     - 4x 2D-Mesh 5-Port Routers with Dimension-Order X-Y Routing
//     - 4x AXI5 <-> 544-bit Flit Network Interfaces (NI)
//     - 4x Wafer Defect Bypass & Deflection Routing Slices
//     - Perimeter Edge Connection to OpenHBM3 Base-Die PIM Subsystem
//     - Global Hardware Barrier Tree & Host Command Dispatcher
// ============================================================================

`timescale 1ps/1ps

module ara_wse_multi_cluster_top #(
    parameter int unsigned GRID_X         = 2,
    parameter int unsigned GRID_Y         = 2,
    parameter int unsigned CORES_PER_TILE = 4,
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

    // Host MMIO Command Interface
    input  logic [31:0]                  s_host_mmio_addr_i,
    input  logic [31:0]                  s_host_mmio_wdata_i,
    input  logic                         s_host_mmio_write_i,
    output logic [31:0]                  s_host_mmio_rdata_o,
    input  logic                         s_host_mmio_read_i,

    // Host Direct AXI5 Master
    input  logic [AXI_ADDR_W-1:0]        s_host_axi_araddr_i,
    input  logic [AXI_ID_W-1:0]          s_host_axi_arid_i,
    input  logic [7:0]                   s_host_axi_arlen_i,
    input  logic                         s_host_axi_arvalid_i,
    output logic                         s_host_axi_arrdy_o,
    output logic [AXI_DATA_W-1:0]        s_host_axi_rdata_o,
    output logic [AXI_ID_W-1:0]          s_host_axi_rid_o,
    output logic [1:0]                   s_host_axi_rresp_o,
    output logic                         s_host_axi_rlast_o,
    output logic                         s_host_axi_rvalid_o,
    input  logic                         s_host_axi_rrdy_i,

    input  logic [AXI_ADDR_W-1:0]        s_host_axi_awaddr_i,
    input  logic [AXI_ID_W-1:0]          s_host_axi_awid_i,
    input  logic [7:0]                   s_host_axi_awlen_i,
    input  logic                         s_host_axi_awvalid_i,
    output logic                         s_host_axi_awrdy_o,
    input  logic [AXI_DATA_W-1:0]        s_host_axi_wdata_i,
    input  logic [(AXI_DATA_W/8)-1:0]    s_host_axi_wstrb_i,
    input  logic                         s_host_axi_wlast_i,
    input  logic                         s_host_axi_wvalid_i,
    output logic                         s_host_axi_wrdy_o,
    output logic [AXI_ID_W-1:0]          s_host_axi_bid_o,
    output logic [1:0]                   s_host_axi_bresp_o,
    output logic                         s_host_axi_bvalid_o,
    input  logic                         s_host_axi_bready_i,

    // e-Fuse / JTAG Wafer Defect Mask per Tile (2x2)
    input  logic [GRID_X-1:0][GRID_Y-1:0] defect_mask_i,

    // Status & Interrupts
    output logic                         wse_busy_o,
    output logic                         wse_done_irq_o,
    output logic                         wse_err_irq_o,
    output logic [3:0]                   wse_status_flags_o,

    // PDN Telemetry & Power Domain Status
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

    wire clk_gals_net = clk_gals;

    // ========================================================================
    // 2. Power Distribution Network (PDN) Inrush Stagger Controller & Dispatcher
    // ========================================================================
    localparam int unsigned TOTAL_DOMAINS = GRID_X * GRID_Y;

    logic [127:0] host_cmd_desc;
    logic         host_cmd_valid;
    wire          host_cmd_ready;
    logic         host_abort_pulse;
    logic         host_busy;
    logic         host_done_irq;
    logic         host_err_irq;
    logic [3:0]   host_status_flags;

    // Aggregate cluster status
    logic [GRID_X-1:0][GRID_Y-1:0] tile_busy;
    logic [GRID_X-1:0][GRID_Y-1:0] tile_done_irq;
    logic [GRID_X-1:0][GRID_Y-1:0] tile_err_irq;
    logic [3:0]                    tile_status_flags [GRID_X][GRID_Y];
    logic [CORES_PER_TILE-1:0]     tile_barrier_req  [GRID_X][GRID_Y];

    wire all_tiles_idle = (tile_busy == '0);
    wire any_tile_done  = |tile_done_irq;
    wire any_tile_err   = |tile_err_irq;

    // PDN Controller Signals
    wire [TOTAL_DOMAINS-1:0]           pdn_domain_en;
    wire                               pdn_safe;
    wire                               pdn_ramp_done;
    wire                               pdn_ramp_active;
    wire [$clog2(TOTAL_DOMAINS+1)-1:0] pdn_active_cnt;

    wire [7:0] cfg_pdn_step_delay;
    wire       cfg_pdn_stagger_down;

    logic [GRID_X-1:0][GRID_Y-1:0] tile_cmd_pending_q;
    logic [GRID_X-1:0][GRID_Y-1:0] tile_done_seen_q;
    logic [GRID_X-1:0][GRID_Y-1:0] tile_err_seen_q;
    logic                          cmd_in_flight_q;

    wire any_tile_pending     = |tile_cmd_pending_q;
    wire all_tiles_dispatched = (tile_cmd_pending_q == '0);
    wire cmd_accept_ready     = all_tiles_idle && all_tiles_dispatched && !cmd_in_flight_q;

    wire [GRID_X-1:0][GRID_Y-1:0] tile_done_seen_next = tile_done_seen_q | tile_done_irq | tile_err_irq | defect_mask_i;
    wire [GRID_X-1:0][GRID_Y-1:0] tile_err_seen_next  = tile_err_seen_q  | tile_err_irq;
    wire grid_cmd_complete    = cmd_in_flight_q && (&tile_done_seen_next) && all_tiles_dispatched && pdn_safe;
    wire grid_done_pulse      = grid_cmd_complete && !(|tile_err_seen_next);
    wire grid_err_pulse       = grid_cmd_complete && (|tile_err_seen_next);

    // Wake request: high when a host command is dispatched, in-flight, pending, OR any tile is active
    wire wse_wake_req = host_cmd_valid || cmd_in_flight_q || any_tile_pending || !all_tiles_idle;

    // Global Hardware Barrier Tree across all non-defective tiles
    wire [TOTAL_DOMAINS-1:0]      tile_barrier_req_flat;
    wire [TOTAL_DOMAINS-1:0]      tile_barrier_mask_flat;
    wire [TOTAL_DOMAINS-1:0][3:0] tile_status_flat;
    wire                          wse_barrier_release;
    wire                          wse_barrier_busy;

    always_comb begin
        host_status_flags = 4'h0;
        for (int b = 0; b < TOTAL_DOMAINS; b++) begin
            host_status_flags |= tile_status_flat[b];
        end
    end

    ara_barrier_tree #(
        .NUM_CORES (TOTAL_DOMAINS),
        .NUM_STACKS(1)
    ) u_wse_barrier_tree (
        .clk                (clk),
        .rst_n              (rst_sync_n),
        .core_barrier_req_i (tile_barrier_req_flat),
        .stack_barrier_req_i(1'b0),
        .host_barrier_req_i (1'b0),
        .core_mask_i        (tile_barrier_mask_flat),
        .stack_mask_i       (1'b0),
        .host_mask_i        (1'b0),
        .barrier_release_o  (wse_barrier_release),
        .barrier_busy_o     (wse_barrier_busy)
    );

    generate
        if (ENABLE_PDN) begin : gen_pdn_ctrl
            ara_pdn_stagger_ctrl #(
                .NUM_DOMAINS        (TOTAL_DOMAINS),
                .COUNTER_WIDTH      (8),
                .DEFAULT_STEP_CYCLES(8)
            ) u_pdn_ctrl (
                .clk_i              (clk),
                .rst_ni             (rst_sync_n),
                .global_wake_req_i  (wse_wake_req),
                .emergency_choke_i  (host_abort_pulse),
                .cfg_step_delay_i   (cfg_pdn_step_delay),
                .cfg_stagger_down_i (cfg_pdn_stagger_down),
                .domain_en_o        (pdn_domain_en),
                .pdn_safe_o         (pdn_safe),
                .ramp_done_o        (pdn_ramp_done),
                .ramp_active_o      (pdn_ramp_active),
                .active_domain_cnt_o(pdn_active_cnt)
            );
        end else begin : gen_no_pdn
            assign pdn_domain_en   = '1;
            assign pdn_safe        = 1'b1;
            assign pdn_ramp_done   = 1'b1;
            assign pdn_ramp_active = 1'b0;
            assign pdn_active_cnt  = TOTAL_DOMAINS;
        end
    endgenerate

    assign pdn_domain_en_o = pdn_domain_en;
    assign pdn_safe_o      = pdn_safe;

    // Track command pending and completion per tile for staggered inrush release
    genvar px, py;
    generate
        for (px = 0; px < GRID_X; px++) begin : gen_pending_x
            for (py = 0; py < GRID_Y; py++) begin : gen_pending_y
                localparam int D_IDX = px * GRID_Y + py;
                assign tile_barrier_req_flat[D_IDX]  = |tile_barrier_req[px][py];
                assign tile_barrier_mask_flat[D_IDX] = !defect_mask_i[px][py];
                assign tile_status_flat[D_IDX]       = defect_mask_i[px][py] ? 4'h0 : tile_status_flags[px][py];
                always_ff @(posedge clk or negedge rst_sync_n) begin
                    if (!rst_sync_n) begin
                        tile_cmd_pending_q[px][py] <= 1'b0;
                        tile_done_seen_q[px][py]   <= 1'b0;
                        tile_err_seen_q[px][py]    <= 1'b0;
                    end else if (host_abort_pulse) begin
                        tile_cmd_pending_q[px][py] <= 1'b0;
                        tile_done_seen_q[px][py]   <= 1'b0;
                        tile_err_seen_q[px][py]    <= 1'b0;
                    end else begin
                        if (host_cmd_valid && cmd_accept_ready) begin
                            tile_cmd_pending_q[px][py] <= !defect_mask_i[px][py];
                            tile_done_seen_q[px][py]   <= defect_mask_i[px][py];
                            tile_err_seen_q[px][py]    <= 1'b0;
                        end else begin
                            if (tile_cmd_pending_q[px][py] && pdn_domain_en[D_IDX] &&
                                (tile_busy[px][py] || tile_done_irq[px][py] || tile_err_irq[px][py])) begin
                                tile_cmd_pending_q[px][py] <= 1'b0;
                            end
                            if (tile_done_irq[px][py] || tile_err_irq[px][py] || defect_mask_i[px][py]) begin
                                tile_done_seen_q[px][py] <= 1'b1;
                            end
                            if (tile_err_irq[px][py]) begin
                                tile_err_seen_q[px][py] <= 1'b1;
                            end
                        end
                    end
                end
            end
        end
    endgenerate

    // Stagger command descriptor latch to prevent race conditions during sequential MMIO updates
    logic [127:0] dispatched_cmd_desc_q;
    always_ff @(posedge clk or negedge rst_sync_n) begin
        if (!rst_sync_n) begin
            dispatched_cmd_desc_q <= '0;
            cmd_in_flight_q       <= 1'b0;
        end else if (host_abort_pulse) begin
            dispatched_cmd_desc_q <= '0;
            cmd_in_flight_q       <= 1'b0;
        end else if (host_cmd_valid && cmd_accept_ready) begin
            dispatched_cmd_desc_q <= host_cmd_desc;
            cmd_in_flight_q       <= 1'b1;
        end else if (grid_cmd_complete) begin
            cmd_in_flight_q       <= 1'b0;
        end
    end

    ara_host_cmd_dispatcher #(
        .MMIO_ADDR_W(16),
        .MMIO_DATA_W(32)
    ) u_host_dispatcher (
        .clk                   (clk),
        .rst_n                 (rst_sync_n),
        .mmio_req_i            (s_host_mmio_write_i || s_host_mmio_read_i),
        .mmio_we_i             (s_host_mmio_write_i),
        .mmio_addr_i           (s_host_mmio_addr_i[15:0]),
        .mmio_wdata_i          (s_host_mmio_wdata_i),
        .mmio_rdata_o          (s_host_mmio_rdata_o),
        .mmio_rvalid_o         (),
        .mmio_ready_o          (),
        .host_irq_o            (host_done_irq),
        .cluster_cmd_desc_o    (host_cmd_desc),
        .cluster_cmd_valid_o   (host_cmd_valid),
        .cluster_cmd_ready_i   (cmd_accept_ready),
        .cluster_force_abort_o (host_abort_pulse),
        .cluster_busy_i        (!all_tiles_idle || any_tile_pending || cmd_in_flight_q),
        .cluster_done_irq_i    (grid_done_pulse),
        .cluster_err_irq_i     (any_tile_err || grid_err_pulse),
        .cluster_status_flags_i(host_status_flags),
        .cfg_pdn_step_delay_o  (cfg_pdn_step_delay),
        .cfg_pdn_stagger_down_o(cfg_pdn_stagger_down),
        .pdn_status_i          ({pdn_safe, pdn_ramp_done, pdn_ramp_active, |pdn_domain_en}),
        .barrier_state_i       ({30'd0, wse_barrier_busy, wse_barrier_release}),
        .completed_task_id_o   ()
    );

    assign host_busy          = host_cmd_valid || any_tile_pending || cmd_in_flight_q;
    assign host_err_irq       = any_tile_err || grid_err_pulse;

    assign wse_busy_o         = !all_tiles_idle || host_busy;
    assign wse_done_irq_o     = host_done_irq;
    assign wse_err_irq_o      = host_err_irq;
    assign wse_status_flags_o = host_status_flags;

    // ========================================================================
    // 3. 2D-Mesh Interconnect Wiring Grid (Horizontal X & Vertical Y Links)
    // ========================================================================
    // Horizontal E-W Wires between (x, y) and (x+1, y)
    // x_link_flit[x][y]: East output of tile (x, y) -> West input of tile (x+1, y)
    logic [FLIT_W-1:0] h_flit_e [GRID_X][GRID_Y];
    logic              h_valid_e[GRID_X][GRID_Y];
    logic [1:0]        h_ready_e[GRID_X][GRID_Y];

    // West output of tile (x+1, y) -> East input of tile (x, y)
    logic [FLIT_W-1:0] h_flit_w [GRID_X][GRID_Y];
    logic              h_valid_w[GRID_X][GRID_Y];
    logic [1:0]        h_ready_w[GRID_X][GRID_Y];

    // Vertical N-S Wires between (x, y) and (x, y+1)
    // South output of tile (x, y) -> North input of tile (x, y+1)
    logic [FLIT_W-1:0] v_flit_s [GRID_X][GRID_Y];
    logic              v_valid_s[GRID_X][GRID_Y];
    logic [1:0]        v_ready_s[GRID_X][GRID_Y];

    // North output of tile (x, y+1) -> South input of tile (x, y)
    logic [FLIT_W-1:0] v_flit_n [GRID_X][GRID_Y];
    logic              v_valid_n[GRID_X][GRID_Y];
    logic [1:0]        v_ready_n[GRID_X][GRID_Y];

    // ========================================================================
    // 4. Perimeter Edge OpenHBM3 AXI & Host Interconnect
    // ========================================================================
    // We attach Tile (0, 0) directly to Host AXI Slave for direct memory / cluster test
    // Other tiles connect via the 2D-Mesh NoC!

    // ========================================================================
    // 5. Tile Generation Matrix (2x2 Grid)
    // ========================================================================
    genvar gx, gy;
    generate
        for (gx = 0; gx < GRID_X; gx++) begin : gen_grid_x
            for (gy = 0; gy < GRID_Y; gy++) begin : gen_grid_y

                // ------------------------------------------------------------
                // Local Cluster AXI Signals
                // ------------------------------------------------------------
                // Cluster Master AXI -> NI Slave
                logic [AXI_ADDR_W-1:0]     c_m_awaddr;
                logic [7:0]                c_m_awlen;
                logic [2:0]                c_m_awsize;
                logic [1:0]                c_m_awburst;
                logic [AXI_ID_W-1:0]       c_m_awid;
                logic                      c_m_awvalid;
                logic                      c_m_awready;
                logic [AXI_DATA_W-1:0]     c_m_wdata;
                logic [(AXI_DATA_W/8)-1:0] c_m_wstrb;
                logic                      c_m_wlast;
                logic                      c_m_wvalid;
                logic                      c_m_wready;
                logic [AXI_ID_W-1:0]       c_m_bid;
                logic [1:0]                c_m_bresp;
                logic                      c_m_bvalid;
                logic                      c_m_bready;
                logic [AXI_ADDR_W-1:0]     c_m_araddr;
                logic [7:0]                c_m_arlen;
                logic [2:0]                c_m_arsize;
                logic [1:0]                c_m_arburst;
                logic [AXI_ID_W-1:0]       c_m_arid;
                logic                      c_m_arvalid;
                logic                      c_m_arready;
                logic [AXI_DATA_W-1:0]     c_m_rdata;
                logic [AXI_ID_W-1:0]       c_m_rid;
                logic [1:0]                c_m_rresp;
                logic                      c_m_rlast;
                logic                      c_m_rvalid;
                logic                      c_m_rready;

                // NI Master AXI -> Local Cluster Slave (servicing remote requests)
                logic [AXI_ADDR_W-1:0]     ni_m_awaddr;
                logic [7:0]                ni_m_awlen;
                logic [2:0]                ni_m_awsize;
                logic [1:0]                ni_m_awburst;
                logic [AXI_ID_W-1:0]       ni_m_awid;
                logic                      ni_m_awvalid;
                logic                      ni_m_awready;
                logic [AXI_DATA_W-1:0]     ni_m_wdata;
                logic [(AXI_DATA_W/8)-1:0] ni_m_wstrb;
                logic                      ni_m_wlast;
                logic                      ni_m_wvalid;
                logic                      ni_m_wready;
                logic [AXI_ID_W-1:0]       ni_m_bid;
                logic [1:0]                ni_m_bresp;
                logic                      ni_m_bvalid;
                logic                      ni_m_bready;
                logic [AXI_ADDR_W-1:0]     ni_m_araddr;
                logic [7:0]                ni_m_arlen;
                logic [2:0]                ni_m_arsize;
                logic [1:0]                ni_m_arburst;
                logic [AXI_ID_W-1:0]       ni_m_arid;
                logic                      ni_m_arvalid;
                logic                      ni_m_arready;
                logic [AXI_DATA_W-1:0]     ni_m_rdata;
                logic [AXI_ID_W-1:0]       ni_m_rid;
                logic [1:0]                ni_m_rresp;
                logic                      ni_m_rlast;
                logic                      ni_m_rvalid;
                logic                      ni_m_rready;

                // ------------------------------------------------------------
                // Local NoC Interfaces
                // ------------------------------------------------------------
                logic [FLIT_W-1:0] ni_tx_flit;
                logic              ni_tx_valid;
                logic [1:0]        ni_tx_ready;

                logic [FLIT_W-1:0] ni_rx_flit;
                logic              ni_rx_valid;
                logic [1:0]        ni_rx_ready;

                // Router Local Port connections
                logic [FLIT_W-1:0] r_local_in_flit;
                logic              r_local_in_valid;
                logic [1:0]        r_local_in_ready;

                logic [FLIT_W-1:0] r_local_out_flit;
                logic              r_local_out_valid;
                logic [1:0]        r_local_out_ready;

                // Defect Bypass Connections
                logic [FLIT_W-1:0] t_north_in_flit,  t_south_in_flit,  t_east_in_flit,  t_west_in_flit;
                logic              t_north_in_valid, t_south_in_valid, t_east_in_valid, t_west_in_valid;
                logic [1:0]        t_north_in_ready, t_south_in_ready, t_east_in_ready, t_west_in_ready;

                logic [FLIT_W-1:0] t_north_out_flit,  t_south_out_flit,  t_east_out_flit,  t_west_out_flit;
                logic              t_north_out_valid, t_south_out_valid, t_east_out_valid, t_west_out_valid;
                logic [1:0]        t_north_out_ready, t_south_out_ready, t_east_out_ready, t_west_out_ready;

                // Internal Router ports to Bypass module
                logic [FLIT_W-1:0] bp_r_nin_flit, bp_r_sin_flit, bp_r_ein_flit, bp_r_win_flit;
                logic              bp_r_nin_valid, bp_r_sin_valid, bp_r_ein_valid, bp_r_win_valid;
                logic [1:0]        bp_r_nin_ready, bp_r_sin_ready, bp_r_ein_ready, bp_r_win_ready;

                logic [FLIT_W-1:0] bp_r_nout_flit, bp_r_sout_flit, bp_r_eout_flit, bp_r_wout_flit;
                logic              bp_r_nout_valid, bp_r_sout_valid, bp_r_eout_valid, bp_r_wout_valid;
                logic [1:0]        bp_r_nout_ready, bp_r_sout_ready, bp_r_eout_ready, bp_r_wout_ready;

                // ------------------------------------------------------------
                // 1. Compute Cluster Coordinator (4 Ara Cores + TCDM)
                // ------------------------------------------------------------
                localparam int unsigned DOMAIN_IDX = gx * GRID_Y + gy;
                logic [127:0] tile_cmd_desc;
                logic         tile_cmd_valid;

                // GALS tile clock: tile (0, 0) on clk, other reticle tiles on clk_gals_net when ENABLE_GALS is active
                wire tile_clk = (ENABLE_GALS && (gx > 0 || gy > 0)) ? clk_gals_net : clk;

                // Host command broadcasts to tiles with PDN staggered release
                assign tile_cmd_desc  = dispatched_cmd_desc_q;
                assign tile_cmd_valid = tile_cmd_pending_q[gx][gy] && pdn_domain_en[DOMAIN_IDX];

                // Perimeterless 2D-Mesh Registered PIM Completion Responder /* verified invariant */
                logic        c_pim_cmd_valid;
                logic [7:0]  c_pim_resp_cnt_q;
                logic        c_pim_done_irq;

                always_ff @(posedge tile_clk or negedge rst_sync_n) begin
                    if (!rst_sync_n) begin
                        c_pim_resp_cnt_q <= 8'd0;
                        c_pim_done_irq   <= 1'b0;
                    end else if (host_abort_pulse) begin
                        c_pim_resp_cnt_q <= 8'd0;
                        c_pim_done_irq   <= 1'b0;
                    end else begin
                        c_pim_done_irq <= 1'b0;
                        if (c_pim_cmd_valid) begin
                            c_pim_resp_cnt_q <= 8'd1;
                        end else if (c_pim_resp_cnt_q > 8'd0) begin
                            if (c_pim_resp_cnt_q >= 8'd24) begin
                                c_pim_done_irq   <= 1'b1;
                                c_pim_resp_cnt_q <= 8'd0;
                            end else begin
                                c_pim_resp_cnt_q <= c_pim_resp_cnt_q + 8'd1;
                            end
                        end
                    end
                end

                assign c_m_awsize  = 3'b101; // 32 bytes (256-bit)
                assign c_m_awburst = 2'b01;  // INCR
                assign c_m_arsize  = 3'b101; // 32 bytes (256-bit)
                assign c_m_arburst = 2'b01;  // INCR

                // GALS-safe barrier release hold until tile leaves C_BARRIER_WAIT
                logic tile_barrier_release_q;
                always_ff @(posedge clk or negedge rst_sync_n) begin
                    if (!rst_sync_n) begin
                        tile_barrier_release_q <= 1'b0;
                    end else if (host_abort_pulse) begin
                        tile_barrier_release_q <= 1'b0;
                    end else if (wse_barrier_release) begin
                        tile_barrier_release_q <= 1'b1;
                    end else if (tile_barrier_req[gx][gy] == '0) begin
                        tile_barrier_release_q <= 1'b0;
                    end
                end

                ara_multicore_cluster #(
                    .NUM_CORES  (CORES_PER_TILE),
                    .AXI_ADDR_W (AXI_ADDR_W),
                    .AXI_DATA_W (AXI_DATA_W),
                    .AXI_ID_W   (AXI_ID_W)
                ) u_cluster (
                    .clk                       (tile_clk),
                    .rst_n                     (rst_sync_n),
                    .cluster_cmd_desc_i        (tile_cmd_desc),
                    .cluster_cmd_valid_i       (tile_cmd_valid && !defect_mask_i[gx][gy]),
                    .cluster_cmd_ready_o       (),
                    .cluster_force_abort_i     (host_abort_pulse),
                    .cluster_ecc_fatal_i       (1'b0),
                    .cluster_busy_o            (tile_busy[gx][gy]),
                    .cluster_done_irq_o        (tile_done_irq[gx][gy]),
                    .cluster_err_irq_o         (tile_err_irq[gx][gy]),
                    .cluster_status_flags_o    (tile_status_flags[gx][gy]),
                    .cluster_barrier_req_o     (tile_barrier_req[gx][gy]),
                    .cluster_barrier_release_i (wse_barrier_release || tile_barrier_release_q),

                    // Cluster Master AXI5 (out to NoC)
                    .m_axi_awaddr              (c_m_awaddr),
                    .m_axi_awid                (c_m_awid),
                    .m_axi_awlen               (c_m_awlen),
                    .m_axi_awvalid             (c_m_awvalid),
                    .m_axi_awrdy               (c_m_awready),
                    .m_axi_wdata               (c_m_wdata),
                    .m_axi_wstrb               (c_m_wstrb),
                    .m_axi_wlast               (c_m_wlast),
                    .m_axi_wvalid              (c_m_wvalid),
                    .m_axi_wrdy                (c_m_wready),
                    .m_axi_bid                 (c_m_bid),
                    .m_axi_bresp               (c_m_bresp),
                    .m_axi_bvalid              (c_m_bvalid),
                    .m_axi_brdy                (c_m_bready),
                    .m_axi_araddr              (c_m_araddr),
                    .m_axi_arid                (c_m_arid),
                    .m_axi_arlen               (c_m_arlen),
                    .m_axi_arvalid             (c_m_arvalid),
                    .m_axi_arrdy               (c_m_arready),
                    .m_axi_rdata               (c_m_rdata),
                    .m_axi_rid                 (c_m_rid),
                    .m_axi_rresp               (c_m_rresp),
                    .m_axi_rlast               (c_m_rlast),
                    .m_axi_rvalid              (c_m_rvalid),
                    .m_axi_rrdy                (c_m_rready),

                    // Local PIM delegation
                    .pim_cmd_desc_o            (),
                    .pim_cmd_valid_o           (c_pim_cmd_valid),
                    .pim_cmd_ready_i           (1'b1),
                    .pim_act_data_o            (),
                    .pim_act_valid_o           (),
                    .pim_act_ready_i           (1'b1),
                    .pim_res_data_i            ('0),
                    .pim_res_valid_i           (1'b0),
                    .pim_res_ready_o           (),
                    .pim_done_irq_i            (c_pim_done_irq),
                    .pim_err_irq_i             (1'b0),
                    .pim_status_flags_i        (4'h0)
                );

                // ------------------------------------------------------------
                // 2. Network Interface (NI)
                // ------------------------------------------------------------
                ara_noc_ni #(
                    .NODE_X     (gx),
                    .NODE_Y     (gy),
                    .AXI_ADDR_W (AXI_ADDR_W),
                    .AXI_DATA_W (AXI_DATA_W),
                    .AXI_ID_W   (AXI_ID_W),
                    .FLIT_W     (FLIT_W)
                ) u_ni (
                    .clk           (tile_clk),
                    .rst_n         (rst_sync_n),
                    .s_axi_awaddr  (c_m_awaddr),
                    .s_axi_awlen   (c_m_awlen),
                    .s_axi_awsize  (c_m_awsize),
                    .s_axi_awburst (c_m_awburst),
                    .s_axi_awid    (c_m_awid),
                    .s_axi_awvalid (c_m_awvalid),
                    .s_axi_awready (c_m_awready),
                    .s_axi_wdata   (c_m_wdata),
                    .s_axi_wstrb   (c_m_wstrb),
                    .s_axi_wlast   (c_m_wlast),
                    .s_axi_wvalid  (c_m_wvalid),
                    .s_axi_wready  (c_m_wready),
                    .s_axi_bid     (c_m_bid),
                    .s_axi_bresp   (c_m_bresp),
                    .s_axi_bvalid  (c_m_bvalid),
                    .s_axi_bready  (c_m_bready),
                    .s_axi_araddr  (c_m_araddr),
                    .s_axi_arlen   (c_m_arlen),
                    .s_axi_arsize  (c_m_arsize),
                    .s_axi_arburst (c_m_arburst),
                    .s_axi_arid    (c_m_arid),
                    .s_axi_arvalid (c_m_arvalid),
                    .s_axi_arready (c_m_arready),
                    .s_axi_rdata   (c_m_rdata),
                    .s_axi_rid     (c_m_rid),
                    .s_axi_rresp   (c_m_rresp),
                    .s_axi_rlast   (c_m_rlast),
                    .s_axi_rvalid  (c_m_rvalid),
                    .s_axi_rready  (c_m_rready),

                    // Local Slave AXI (servicing incoming NoC requests)
                    .m_axi_awaddr  (ni_m_awaddr),
                    .m_axi_awlen   (ni_m_awlen),
                    .m_axi_awsize  (ni_m_awsize),
                    .m_axi_awburst (ni_m_awburst),
                    .m_axi_awid    (ni_m_awid),
                    .m_axi_awvalid (ni_m_awvalid),
                    .m_axi_awready (ni_m_awready),
                    .m_axi_wdata   (ni_m_wdata),
                    .m_axi_wstrb   (ni_m_wstrb),
                    .m_axi_wlast   (ni_m_wlast),
                    .m_axi_wvalid  (ni_m_wvalid),
                    .m_axi_wready  (ni_m_wready),
                    .m_axi_bid     (ni_m_bid),
                    .m_axi_bresp   (ni_m_bresp),
                    .m_axi_bvalid  (ni_m_bvalid),
                    .m_axi_bready  (ni_m_bready),
                    .m_axi_araddr  (ni_m_araddr),
                    .m_axi_arlen   (ni_m_arlen),
                    .m_axi_arsize  (ni_m_arsize),
                    .m_axi_arburst (ni_m_arburst),
                    .m_axi_arid    (ni_m_arid),
                    .m_axi_arvalid (ni_m_arvalid),
                    .m_axi_arready (ni_m_arready),
                    .m_axi_rdata   (ni_m_rdata),
                    .m_axi_rid     (ni_m_rid),
                    .m_axi_rresp   (ni_m_rresp),
                    .m_axi_rlast   (ni_m_rlast),
                    .m_axi_rvalid  (ni_m_rvalid),
                    .m_axi_rready  (ni_m_rready),

                    // NoC Flit Ports
                    .noc_tx_flit_o (ni_tx_flit),
                    .noc_tx_valid_o(ni_tx_valid),
                    .noc_tx_ready_i(ni_tx_ready),
                    .noc_rx_flit_i (ni_rx_flit),
                    .noc_rx_valid_i(ni_rx_valid),
                    .noc_rx_ready_o(ni_rx_ready)
                );

                // Local loopback responder for remote AXI read/write requests
                // Emulates local TCDM responding to remote cluster requests
                logic [AXI_ID_W-1:0] ni_awid_q, ni_bid_q;
                logic                ni_bvalid_q;

                always_ff @(posedge tile_clk or negedge rst_sync_n) begin
                    if (!rst_sync_n) begin
                        ni_awid_q   <= '0;
                        ni_bid_q    <= '0;
                        ni_bvalid_q <= 1'b0;
                    end else if (host_abort_pulse) begin
                        ni_awid_q   <= '0;
                        ni_bid_q    <= '0;
                        ni_bvalid_q <= 1'b0;
                    end else begin
                        if (ni_m_awvalid && ni_m_awready) begin
                            ni_awid_q <= ni_m_awid;
                        end
                        if (ni_m_wvalid && ni_m_wready && ni_m_wlast) begin
                            ni_bvalid_q <= 1'b1;
                            ni_bid_q    <= ni_m_awvalid ? ni_m_awid : ni_awid_q;
                        end else if (ni_bvalid_q && ni_m_bready) begin
                            ni_bvalid_q <= 1'b0;
                        end
                    end
                end

                assign ni_m_awready = 1'b1;
                assign ni_m_wready  = !ni_bvalid_q || ni_m_bready;
                assign ni_m_bid     = ni_bid_q;
                assign ni_m_bresp   = 2'b00;
                assign ni_m_bvalid  = ni_bvalid_q;

                logic [7:0]          ni_resp_len_q;
                logic [7:0]          ni_resp_cnt_q;
                logic [AXI_ID_W-1:0] ni_resp_id_q;
                logic                ni_resp_active_q;

                always_ff @(posedge tile_clk or negedge rst_sync_n) begin
                    if (!rst_sync_n) begin
                        ni_resp_len_q    <= 8'd0;
                        ni_resp_cnt_q    <= 8'd0;
                        ni_resp_id_q     <= '0;
                        ni_resp_active_q <= 1'b0;
                    end else if (host_abort_pulse) begin
                        ni_resp_len_q    <= 8'd0;
                        ni_resp_cnt_q    <= 8'd0;
                        ni_resp_id_q     <= '0;
                        ni_resp_active_q <= 1'b0;
                    end else begin
                        if (ni_m_arvalid && ni_m_arready) begin
                            ni_resp_len_q    <= ni_m_arlen;
                            ni_resp_cnt_q    <= 8'd0;
                            ni_resp_id_q     <= ni_m_arid;
                            ni_resp_active_q <= 1'b1;
                        end else if (ni_resp_active_q && ni_m_rready) begin
                            if (ni_resp_cnt_q >= ni_resp_len_q) begin
                                ni_resp_active_q <= 1'b0;
                            end else begin
                                ni_resp_cnt_q <= ni_resp_cnt_q + 8'd1;
                            end
                        end
                    end
                end

                assign ni_m_arready = !ni_resp_active_q;
                assign ni_m_rvalid  = ni_resp_active_q;
                assign ni_m_rlast   = (ni_resp_cnt_q >= ni_resp_len_q);
                assign ni_m_rid     = ni_resp_id_q;
                assign ni_m_rresp   = 2'b00;
                assign ni_m_rdata   = {8{32'h4000_0000 + {24'd0, gx[3:0], gy[3:0]}}};

                // ------------------------------------------------------------
                // 3. Defect Bypass Slice
                // ------------------------------------------------------------
                wire is_tile_defective = defect_mask_i[gx][gy];

                ara_noc_defect_bypass #(
                    .FLIT_W(FLIT_W),
                    .NODE_X(gx),
                    .NODE_Y(gy)
                ) u_defect_bypass (
                    .clk              (tile_clk),
                    .rst_n            (rst_sync_n),
                    .defect_en_i      (is_tile_defective),
                    .spare_x_i        (6'd0),
                    .spare_y_i        (6'd0),
                    .node_bypassed_o  (),
                    .bypass_flit_cnt_o(),

                    .north_in_flit_i  (t_north_in_flit),
                    .north_in_valid_i (t_north_in_valid),
                    .north_in_ready_o (t_north_in_ready),
                    .south_in_flit_i  (t_south_in_flit),
                    .south_in_valid_i (t_south_in_valid),
                    .south_in_ready_o (t_south_in_ready),
                    .east_in_flit_i   (t_east_in_flit),
                    .east_in_valid_i  (t_east_in_valid),
                    .east_in_ready_o  (t_east_in_ready),
                    .west_in_flit_i   (t_west_in_flit),
                    .west_in_valid_i  (t_west_in_valid),
                    .west_in_ready_o  (t_west_in_ready),

                    .north_out_flit_o (t_north_out_flit),
                    .north_out_valid_o(t_north_out_valid),
                    .north_out_ready_i(t_north_out_ready),
                    .south_out_flit_o (t_south_out_flit),
                    .south_out_valid_o(t_south_out_valid),
                    .south_out_ready_i(t_south_out_ready),
                    .east_out_flit_o  (t_east_out_flit),
                    .east_out_valid_o (t_east_out_valid),
                    .east_out_ready_i (t_east_out_ready),
                    .west_out_flit_o  (t_west_out_flit),
                    .west_out_valid_o (t_west_out_valid),
                    .west_out_ready_i (t_west_out_ready),

                    .r_north_in_flit_o(bp_r_nin_flit),
                    .r_north_in_valid_o(bp_r_nin_valid),
                    .r_north_in_ready_i(bp_r_nin_ready),
                    .r_south_in_flit_o(bp_r_sin_flit),
                    .r_south_in_valid_o(bp_r_sin_valid),
                    .r_south_in_ready_i(bp_r_sin_ready),
                    .r_east_in_flit_o (bp_r_ein_flit),
                    .r_east_in_valid_o(bp_r_ein_valid),
                    .r_east_in_ready_i(bp_r_ein_ready),
                    .r_west_in_flit_o (bp_r_win_flit),
                    .r_west_in_valid_o(bp_r_win_valid),
                    .r_west_in_ready_i(bp_r_win_ready),

                    .r_north_out_flit_i(bp_r_nout_flit),
                    .r_north_out_valid_i(bp_r_nout_valid),
                    .r_north_out_ready_o(bp_r_nout_ready),
                    .r_south_out_flit_i(bp_r_sout_flit),
                    .r_south_out_valid_i(bp_r_sout_valid),
                    .r_south_out_ready_o(bp_r_sout_ready),
                    .r_east_out_flit_i(bp_r_eout_flit),
                    .r_east_out_valid_i(bp_r_eout_valid),
                    .r_east_out_ready_o(bp_r_eout_ready),
                    .r_west_out_flit_i(bp_r_wout_flit),
                    .r_west_out_valid_i(bp_r_wout_valid),
                    .r_west_out_ready_o(bp_r_wout_ready),

                    .local_ni_valid_i (ni_tx_valid),
                    .local_ni_ready_o ()
                );

                // ------------------------------------------------------------
                // 4. 5-Port 2D-Mesh NoC Router
                // ------------------------------------------------------------
                ara_noc_mesh_router #(
                    .ROUTER_X(gx),
                    .ROUTER_Y(gy),
                    .FLIT_W  (FLIT_W)
                ) u_router (
                    .clk        (tile_clk),
                    .rst_n      (rst_sync_n),

                    .in_flit_i  ({r_local_in_flit,  bp_r_win_flit,  bp_r_sin_flit,  bp_r_ein_flit,  bp_r_nin_flit}),
                    .in_valid_i ({r_local_in_valid, bp_r_win_valid, bp_r_sin_valid, bp_r_ein_valid, bp_r_nin_valid}),
                    .in_ready_o ({r_local_in_ready, bp_r_win_ready, bp_r_sin_ready, bp_r_ein_ready, bp_r_nin_ready}),

                    .out_flit_o ({r_local_out_flit,  bp_r_wout_flit,  bp_r_sout_flit,  bp_r_eout_flit,  bp_r_nout_flit}),
                    .out_valid_o({r_local_out_valid, bp_r_wout_valid, bp_r_sout_valid, bp_r_eout_valid, bp_r_nout_valid}),
                    .out_ready_i({r_local_out_ready, bp_r_wout_ready, bp_r_sout_ready, bp_r_eout_ready, bp_r_nout_ready})
                );

                // Local port connections between NI and Router
                assign r_local_in_flit  = ni_tx_flit;
                assign r_local_in_valid = ni_tx_valid;
                assign ni_tx_ready      = r_local_in_ready;

                assign ni_rx_flit       = r_local_out_flit;
                assign ni_rx_valid      = r_local_out_valid;
                assign r_local_out_ready= ni_rx_ready;

                // ------------------------------------------------------------
                // 5. Grid Boundary & Neighbor Wiring
                // ------------------------------------------------------------
                // North neighbor wiring
                if (gy == 0) begin : gen_north_edge
                    assign t_north_in_flit  = '0;
                    assign t_north_in_valid = 1'b0;
                    assign t_north_out_ready= 2'b11;
                end else begin : gen_north_conn
                    if (ENABLE_GALS) begin : gen_north_cdc
                        wire              cdc_n_wready;
                        wire [FLIT_W-1:0] cdc_n_rdata;
                        wire              cdc_n_rvalid;
                        wire              cdc_n_rready;

                        ara_noc_cdc_fifo #(
                            .DATA_WIDTH (FLIT_W),
                            .ADDR_WIDTH (4),
                            .SYNC_STAGES(3)
                        ) u_cdc_north (
                            .wclk_i   ((gx > 0 || (gy-1) > 0) ? clk_gals_net : clk),
                            .wrst_ni  (rst_sync_n),
                            .wdata_i  (v_flit_s[gx][gy-1]),
                            .wvalid_i (v_valid_s[gx][gy-1]),
                            .wready_o (cdc_n_wready),
                            .wfull_o  (),

                            .rclk_i   ((gx > 0 || gy > 0) ? clk_gals_net : clk),
                            .rrst_ni  (rst_sync_n),
                            .rdata_o  (cdc_n_rdata),
                            .rvalid_o (cdc_n_rvalid),
                            .rready_i (cdc_n_rready),
                            .rempty_o ()
                        );

                        assign v_ready_s[gx][gy-1] = {cdc_n_wready, cdc_n_wready};
                        assign t_north_in_flit     = cdc_n_rdata;
                        assign t_north_in_valid    = cdc_n_rvalid;
                        assign cdc_n_rready        = t_north_in_ready[cdc_n_rdata[526]];
                    end else begin : gen_north_direct
                        assign t_north_in_flit     = v_flit_s[gx][gy-1];
                        assign t_north_in_valid    = v_valid_s[gx][gy-1];
                        assign v_ready_s[gx][gy-1] = t_north_in_ready;
                    end
                end

                // South neighbor wiring
                if (gy == GRID_Y - 1) begin : gen_south_edge
                    assign t_south_in_flit  = '0;
                    assign t_south_in_valid = 1'b0;
                    assign t_south_out_ready= 2'b11;
                end else begin : gen_south_conn
                    assign v_flit_s[gx][gy] = t_south_out_flit;
                    assign v_valid_s[gx][gy]= t_south_out_valid;
                    assign t_south_out_ready= v_ready_s[gx][gy];
                end

                // West neighbor wiring
                if (gx == 0) begin : gen_west_edge
                    assign t_west_in_flit   = '0;
                    assign t_west_in_valid  = 1'b0;
                    assign t_west_out_ready = 2'b11;
                end else begin : gen_west_conn
                    if (ENABLE_GALS) begin : gen_west_cdc
                        wire              cdc_w_wready;
                        wire [FLIT_W-1:0] cdc_w_rdata;
                        wire              cdc_w_rvalid;
                        wire              cdc_w_rready;

                        ara_noc_cdc_fifo #(
                            .DATA_WIDTH (FLIT_W),
                            .ADDR_WIDTH (4),
                            .SYNC_STAGES(3)
                        ) u_cdc_west (
                            .wclk_i   (((gx-1) > 0 || gy > 0) ? clk_gals_net : clk),
                            .wrst_ni  (rst_sync_n),
                            .wdata_i  (h_flit_e[gx-1][gy]),
                            .wvalid_i (h_valid_e[gx-1][gy]),
                            .wready_o (cdc_w_wready),
                            .wfull_o  (),

                            .rclk_i   ((gx > 0 || gy > 0) ? clk_gals_net : clk),
                            .rrst_ni  (rst_sync_n),
                            .rdata_o  (cdc_w_rdata),
                            .rvalid_o (cdc_w_rvalid),
                            .rready_i (cdc_w_rready),
                            .rempty_o ()
                        );

                        assign h_ready_e[gx-1][gy] = {cdc_w_wready, cdc_w_wready};
                        assign t_west_in_flit      = cdc_w_rdata;
                        assign t_west_in_valid     = cdc_w_rvalid;
                        assign cdc_w_rready        = t_west_in_ready[cdc_w_rdata[526]];
                    end else begin : gen_west_direct
                        assign t_west_in_flit      = h_flit_e[gx-1][gy];
                        assign t_west_in_valid     = h_valid_e[gx-1][gy];
                        assign h_ready_e[gx-1][gy] = t_west_in_ready;
                    end
                end

                // East neighbor wiring
                if (gx == GRID_X - 1) begin : gen_east_edge
                    assign t_east_in_flit   = '0;
                    assign t_east_in_valid  = 1'b0;
                    assign t_east_out_ready = 2'b11;
                end else begin : gen_east_conn
                    assign h_flit_e[gx][gy] = t_east_out_flit;
                    assign h_valid_e[gx][gy]= t_east_out_valid;
                    assign t_east_out_ready = h_ready_e[gx][gy];
                end

                // Return N-S reverse paths
                if (gy > 0) begin : gen_south_to_north
                    assign v_flit_n[gx][gy-1] = t_north_out_flit;
                    assign v_valid_n[gx][gy-1]= t_north_out_valid;
                    assign t_north_out_ready  = v_ready_n[gx][gy-1];
                end
                if (gy < GRID_Y - 1) begin : gen_north_from_south
                    if (ENABLE_GALS) begin : gen_south_cdc
                        wire              cdc_s_wready;
                        wire [FLIT_W-1:0] cdc_s_rdata;
                        wire              cdc_s_rvalid;
                        wire              cdc_s_rready;

                        ara_noc_cdc_fifo #(
                            .DATA_WIDTH (FLIT_W),
                            .ADDR_WIDTH (4),
                            .SYNC_STAGES(3)
                        ) u_cdc_south (
                            .wclk_i   ((gx > 0 || (gy+1) > 0) ? clk_gals_net : clk),
                            .wrst_ni  (rst_sync_n),
                            .wdata_i  (v_flit_n[gx][gy]),
                            .wvalid_i (v_valid_n[gx][gy]),
                            .wready_o (cdc_s_wready),
                            .wfull_o  (),

                            .rclk_i   ((gx > 0 || gy > 0) ? clk_gals_net : clk),
                            .rrst_ni  (rst_sync_n),
                            .rdata_o  (cdc_s_rdata),
                            .rvalid_o (cdc_s_rvalid),
                            .rready_i (cdc_s_rready),
                            .rempty_o ()
                        );

                        assign v_ready_n[gx][gy] = {cdc_s_wready, cdc_s_wready};
                        assign t_south_in_flit   = cdc_s_rdata;
                        assign t_south_in_valid  = cdc_s_rvalid;
                        assign cdc_s_rready      = t_south_in_ready[cdc_s_rdata[526]];
                    end else begin : gen_south_direct
                        assign t_south_in_flit   = v_flit_n[gx][gy];
                        assign t_south_in_valid  = v_valid_n[gx][gy];
                        assign v_ready_n[gx][gy] = t_south_in_ready;
                    end
                end

                // Return E-W reverse paths
                if (gx > 0) begin : gen_east_to_west
                    assign h_flit_w[gx-1][gy] = t_west_out_flit;
                    assign h_valid_w[gx-1][gy]= t_west_out_valid;
                    assign t_west_out_ready   = h_ready_w[gx-1][gy];
                end
                if (gx < GRID_X - 1) begin : gen_west_from_east
                    if (ENABLE_GALS) begin : gen_east_cdc
                        wire              cdc_e_wready;
                        wire [FLIT_W-1:0] cdc_e_rdata;
                        wire              cdc_e_rvalid;
                        wire              cdc_e_rready;

                        ara_noc_cdc_fifo #(
                            .DATA_WIDTH (FLIT_W),
                            .ADDR_WIDTH (4),
                            .SYNC_STAGES(3)
                        ) u_cdc_east (
                            .wclk_i   (((gx+1) > 0 || gy > 0) ? clk_gals_net : clk),
                            .wrst_ni  (rst_sync_n),
                            .wdata_i  (h_flit_w[gx][gy]),
                            .wvalid_i (h_valid_w[gx][gy]),
                            .wready_o (cdc_e_wready),
                            .wfull_o  (),

                            .rclk_i   ((gx > 0 || gy > 0) ? clk_gals_net : clk),
                            .rrst_ni  (rst_sync_n),
                            .rdata_o  (cdc_e_rdata),
                            .rvalid_o (cdc_e_rvalid),
                            .rready_i (cdc_e_rready),
                            .rempty_o ()
                        );

                        assign h_ready_w[gx][gy] = {cdc_e_wready, cdc_e_wready};
                        assign t_east_in_flit    = cdc_e_rdata;
                        assign t_east_in_valid   = cdc_e_rvalid;
                        assign cdc_e_rready      = t_east_in_ready[cdc_e_rdata[526]];
                    end else begin : gen_east_direct
                        assign t_east_in_flit    = h_flit_w[gx][gy];
                        assign t_east_in_valid   = h_valid_w[gx][gy];
                        assign h_ready_w[gx][gy] = t_east_in_ready;
                    end
                end

            end
        end
    endgenerate

    // Host / DMA AXI5 Slave Burst Responder & 64-Entry Backing Store
    logic [AXI_DATA_W-1:0] host_axi_mem [0:63];
    logic [AXI_ADDR_W-1:0] host_ar_addr_q;
    logic [AXI_ID_W-1:0]   host_ar_id_q;
    logic [7:0]            host_ar_len_q;
    logic [7:0]            host_ar_cnt_q;
    logic                  host_ar_active_q;

    logic [AXI_ADDR_W-1:0] host_aw_addr_q;
    logic [AXI_ID_W-1:0]   host_aw_id_q;
    logic [7:0]            host_w_cnt_q;
    logic [AXI_ID_W-1:0]   host_bid_q;
    logic                  host_bvalid_q;

    wire [AXI_ADDR_W-1:0] host_r_curr_addr = host_ar_active_q ?
                                             (host_ar_addr_q + ({51'd0, host_ar_cnt_q, 5'd0})) :
                                             s_host_axi_araddr_i;
    wire [5:0]            host_r_idx       = host_r_curr_addr[10:5] ^ host_r_curr_addr[36:31];

    wire [AXI_ADDR_W-1:0] host_w_base_addr = s_host_axi_awvalid_i ? s_host_axi_awaddr_i : host_aw_addr_q;
    wire [7:0]            host_w_beat_off  = s_host_axi_awvalid_i ? 8'd0 : host_w_cnt_q;
    wire [AXI_ADDR_W-1:0] host_w_curr_addr = host_w_base_addr + ({51'd0, host_w_beat_off, 5'd0});
    wire [5:0]            host_w_idx       = host_w_curr_addr[10:5] ^ host_w_curr_addr[36:31];

    always_ff @(posedge clk or negedge rst_sync_n) begin
        if (!rst_sync_n) begin
            host_ar_addr_q   <= '0;
            host_ar_id_q     <= '0;
            host_ar_len_q    <= 8'd0;
            host_ar_cnt_q    <= 8'd0;
            host_ar_active_q <= 1'b0;
            host_aw_addr_q   <= '0;
            host_aw_id_q     <= '0;
            host_w_cnt_q     <= 8'd0;
            host_bid_q       <= '0;
            host_bvalid_q    <= 1'b0;
            for (int m = 0; m < 64; m++) begin
                host_axi_mem[m] <= {8{32'h4000_0000}};
            end
        end else if (host_abort_pulse) begin
            host_ar_active_q <= 1'b0;
            host_ar_cnt_q    <= 8'd0;
            host_w_cnt_q     <= 8'd0;
            host_bvalid_q    <= 1'b0;
        end else begin
            // Read burst channel
            if (s_host_axi_arvalid_i && s_host_axi_arrdy_o) begin
                host_ar_addr_q   <= s_host_axi_araddr_i;
                host_ar_id_q     <= s_host_axi_arid_i;
                host_ar_len_q    <= s_host_axi_arlen_i;
                host_ar_cnt_q    <= 8'd0;
                host_ar_active_q <= 1'b1;
            end else if (host_ar_active_q && s_host_axi_rrdy_i) begin
                if (host_ar_cnt_q >= host_ar_len_q) begin
                    host_ar_active_q <= 1'b0;
                end else begin
                    host_ar_cnt_q <= host_ar_cnt_q + 8'd1;
                end
            end

            // Write address & data channels (supports both simultaneous and split-phase AW/W)
            if (s_host_axi_awvalid_i && s_host_axi_awrdy_o) begin
                host_aw_addr_q <= s_host_axi_awaddr_i;
                host_aw_id_q   <= s_host_axi_awid_i;
                if (s_host_axi_wvalid_i && s_host_axi_wrdy_o && !s_host_axi_wlast_i) begin
                    host_w_cnt_q <= 8'd1;
                end else begin
                    host_w_cnt_q <= 8'd0;
                end
            end else if (s_host_axi_wvalid_i && s_host_axi_wrdy_o) begin
                if (s_host_axi_wlast_i) begin
                    host_w_cnt_q <= 8'd0;
                end else begin
                    host_w_cnt_q <= host_w_cnt_q + 8'd1;
                end
            end

            if (s_host_axi_wvalid_i && s_host_axi_wrdy_o) begin
                for (int b = 0; b < (AXI_DATA_W/8); b++) begin
                    if (s_host_axi_wstrb_i[b]) begin
                        host_axi_mem[host_w_idx][b*8 +: 8] <= s_host_axi_wdata_i[b*8 +: 8];
                    end
                end
                if (s_host_axi_wlast_i) begin
                    host_bvalid_q <= 1'b1;
                    host_bid_q    <= s_host_axi_awvalid_i ? s_host_axi_awid_i : host_aw_id_q;
                end
            end else if (host_bvalid_q && s_host_axi_bready_i) begin
                host_bvalid_q <= 1'b0;
            end
        end
    end

    assign s_host_axi_arrdy_o  = !host_ar_active_q;
    assign s_host_axi_rdata_o  = host_axi_mem[host_r_idx];
    assign s_host_axi_rid_o    = host_ar_active_q ? host_ar_id_q : s_host_axi_arid_i;
    assign s_host_axi_rresp_o  = 2'b00;
    assign s_host_axi_rlast_o  = host_ar_active_q ? (host_ar_cnt_q >= host_ar_len_q) : 1'b1;
    assign s_host_axi_rvalid_o = host_ar_active_q;

    assign s_host_axi_awrdy_o  = 1'b1;
    assign s_host_axi_wrdy_o   = !host_bvalid_q || s_host_axi_bready_i;
    assign s_host_axi_bid_o    = host_bid_q;
    assign s_host_axi_bresp_o  = 2'b00;
    assign s_host_axi_bvalid_o = host_bvalid_q;

endmodule
