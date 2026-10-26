// ============================================================================
// File: ara_noc_ni.sv
// Project: Ara_MultiCore_WSE_HBM3 (Phase 1: NoC Mesh Fabric - Step 2)
// Technology: ASAP7 7nm FinFET Predictive PDK (Target: 2.0 GHz / 500 ps cycle)
// Specification: Architectural Invariants & Verification Standards
// Architectural Invariants & Verification Standards
//
// Description:
//   Bidirectional AXI5 <-> 544-bit Flit Network Interface (NI):
//   1. Ingress Master Path (Cluster AXI Master -> NoC TX):
//      - Translates Cluster AW/W write transactions into VC0 Request Flits.
//      - Translates Cluster AR read transactions into VC0 Request Flits.
//      - Extracts Dest_X = Addr[39:34], Dest_Y = Addr[33:28].
//      - Embeds Src_X, Src_Y and AXI ID in Flit header for return routing.
//   2. Ingress Slave Path (NoC RX VC0 Requests -> Local Cluster AXI Slave):
//      - Demultiplexes incoming write flits into local AXI AW + W transactions.
//      - Demultiplexes incoming read flits into local AXI AR transactions.
//   3. Egress Response Path (Local AXI Slave Responses -> NoC TX VC1):
//      - Converts local AXI B responses into VC1 Write Response Flits.
//      - Converts local AXI R read data beats into VC1 Read Response Flits.
//   4. Egress Master Completion Path (NoC RX VC1 Responses -> Cluster Master):
//      - Routes VC1 Write Responses to Cluster AXI B channel.
//      - Routes VC1 Read Responses to Cluster AXI R channel.
// ============================================================================

`timescale 1ps/1ps

module ara_noc_ni #(
    parameter int unsigned NODE_X       = 0,
    parameter int unsigned NODE_Y       = 0,
    parameter int unsigned AXI_ADDR_W   = 40,
    parameter int unsigned AXI_DATA_W   = 256,
    parameter int unsigned AXI_ID_W     = 4,
    parameter int unsigned FLIT_W       = 544
)(
    input  logic                          clk,
    input  logic                          rst_n,

    // ------------------------------------------------------------------------
    // Cluster AXI5 Master Interface (Cluster initiates transactions)
    // ------------------------------------------------------------------------
    // Write Address Channel
    input  logic [AXI_ADDR_W-1:0]          s_axi_awaddr,
    input  logic [7:0]                     s_axi_awlen,
    input  logic [2:0]                     s_axi_awsize,
    input  logic [1:0]                     s_axi_awburst,
    input  logic [AXI_ID_W-1:0]            s_axi_awid,
    input  logic                           s_axi_awvalid,
    output logic                           s_axi_awready,

    // Write Data Channel
    input  logic [AXI_DATA_W-1:0]          s_axi_wdata,
    input  logic [(AXI_DATA_W/8)-1:0]      s_axi_wstrb,
    input  logic                           s_axi_wlast,
    input  logic                           s_axi_wvalid,
    output logic                           s_axi_wready,

    // Write Response Channel
    output logic [AXI_ID_W-1:0]            s_axi_bid,
    output logic [1:0]                     s_axi_bresp,
    output logic                           s_axi_bvalid,
    input  logic                           s_axi_bready,

    // Read Address Channel
    input  logic [AXI_ADDR_W-1:0]          s_axi_araddr,
    input  logic [7:0]                     s_axi_arlen,
    input  logic [2:0]                     s_axi_arsize,
    input  logic [1:0]                     s_axi_arburst,
    input  logic [AXI_ID_W-1:0]            s_axi_arid,
    input  logic                           s_axi_arvalid,
    output logic                           s_axi_arready,

    // Read Data Channel
    output logic [AXI_DATA_W-1:0]          s_axi_rdata,
    output logic [AXI_ID_W-1:0]            s_axi_rid,
    output logic [1:0]                     s_axi_rresp,
    output logic                           s_axi_rlast,
    output logic                           s_axi_rvalid,
    input  logic                           s_axi_rready,

    // ------------------------------------------------------------------------
    // Local Cluster AXI5 Slave Interface (NI targets local cluster resources)
    // ------------------------------------------------------------------------
    // Write Address Channel
    output logic [AXI_ADDR_W-1:0]          m_axi_awaddr,
    output logic [7:0]                     m_axi_awlen,
    output logic [2:0]                     m_axi_awsize,
    output logic [1:0]                     m_axi_awburst,
    output logic [AXI_ID_W-1:0]            m_axi_awid,
    output logic                           m_axi_awvalid,
    input  logic                           m_axi_awready,

    // Write Data Channel
    output logic [AXI_DATA_W-1:0]          m_axi_wdata,
    output logic [(AXI_DATA_W/8)-1:0]      m_axi_wstrb,
    output logic                           m_axi_wlast,
    output logic                           m_axi_wvalid,
    input  logic                           m_axi_wready,

    // Write Response Channel
    input  logic [AXI_ID_W-1:0]            m_axi_bid,
    input  logic [1:0]                     m_axi_bresp,
    input  logic                           m_axi_bvalid,
    output logic                           m_axi_bready,

    // Read Address Channel
    output logic [AXI_ADDR_W-1:0]          m_axi_araddr,
    output logic [7:0]                     m_axi_arlen,
    output logic [2:0]                     m_axi_arsize,
    output logic [1:0]                     m_axi_arburst,
    output logic [AXI_ID_W-1:0]            m_axi_arid,
    output logic                           m_axi_arvalid,
    input  logic                           m_axi_arready,

    // Read Data Channel
    input  logic [AXI_DATA_W-1:0]          m_axi_rdata,
    input  logic [AXI_ID_W-1:0]            m_axi_rid,
    input  logic [1:0]                     m_axi_rresp,
    input  logic                           m_axi_rlast,
    input  logic                           m_axi_rvalid,
    output logic                           m_axi_rready,

    // ------------------------------------------------------------------------
    // NoC Router Local Port Interface
    // ------------------------------------------------------------------------
    output logic [FLIT_W-1:0]              noc_tx_flit_o,
    output logic                           noc_tx_valid_o,
    input  logic [1:0]                     noc_tx_ready_i, // [1]: VC1, [0]: VC0

    input  logic [FLIT_W-1:0]              noc_rx_flit_i,
    input  logic                           noc_rx_valid_i,
    output logic [1:0]                     noc_rx_ready_o  // [1]: VC1, [0]: VC0
);

    // Flit Type Constants
    localparam logic [1:0] FLIT_HEAD   = 2'b00;
    localparam logic [1:0] FLIT_BODY   = 2'b01;
    localparam logic [1:0] FLIT_TAIL   = 2'b10;
    localparam logic [1:0] FLIT_SINGLE = 2'b11;

    // Command / Response Types
    localparam logic [2:0] CMD_WRITE_REQ = 3'd1;
    localparam logic [2:0] CMD_READ_REQ  = 3'd2;
    localparam logic [2:0] RSP_WRITE     = 3'd3;
    localparam logic [2:0] RSP_READ      = 3'd4;

    // Node Coordinates as logic vectors to eliminate constant selects in always_comb
    localparam logic [5:0] CURR_NODE_X = NODE_X[5:0];
    localparam logic [5:0] CURR_NODE_Y = NODE_Y[5:0];

    // ------------------------------------------------------------------------
    // 1. Ingress Master Path (Cluster -> NoC TX)
    // ------------------------------------------------------------------------
    // State machine to serialize AW+W burst into VC0 flits, and AR into VC0 flits
    typedef enum logic [2:0] {
        TX_IDLE,
        TX_WRITE_BURST,
        TX_READ_REQ,
        TX_SEND_FLIT
    } tx_fsm_e;

    tx_fsm_e tx_state_q, tx_state_d;

    // Registers to capture AXI write/read requests
    logic [AXI_ADDR_W-1:0] tx_addr_q;
    logic [7:0]            tx_len_q;
    logic [7:0]            tx_cnt_q;
    logic [2:0]            tx_size_q;
    logic [1:0]            tx_burst_q;
    logic [AXI_ID_W-1:0]   tx_id_q;
    logic                  tx_is_write_q;

    // Flit build buffers
    logic [FLIT_W-1:0]     tx_flit_buf_q;
    logic                  tx_flit_valid_q;
    logic                  tx_flit_vc_q; // 0=VC0, 1=VC1

    // Destination coordinate decoding: Dest_X = Addr[39:34], Dest_Y = Addr[33:28]
    wire [5:0] aw_dest_x = s_axi_awaddr[39:34];
    wire [5:0] aw_dest_y = s_axi_awaddr[33:28];
    wire [5:0] ar_dest_x = s_axi_araddr[39:34];
    wire [5:0] ar_dest_y = s_axi_araddr[33:28];
    wire [5:0] tx_dest_x = tx_addr_q[39:34];
    wire [5:0] tx_dest_y = tx_addr_q[33:28];

    // Priority between Write and Read ingress
    wire req_write_start = s_axi_awvalid && s_axi_wvalid && (tx_state_q == TX_IDLE);
    wire req_read_start  = s_axi_arvalid && !req_write_start && (tx_state_q == TX_IDLE);

    // TX Flit Queue: Separates generation from transmission
    logic [FLIT_W-1:0] tx_fifo_flit_in;
    logic              tx_fifo_push;
    wire               tx_fifo_ready;
    wire [FLIT_W-1:0]  tx_fifo_flit_out;
    wire               tx_fifo_valid;
    wire               tx_fifo_pop;

    ara_noc_fifo #(
        .DATA_W(FLIT_W),
        .DEPTH (4)
    ) u_tx_req_fifo (
        .clk         (clk),
        .rst_n       (rst_n),
        .push_data_i (tx_fifo_flit_in),
        .push_valid_i(tx_fifo_push),
        .push_ready_o(tx_fifo_ready),
        .pop_data_o  (tx_fifo_flit_out),
        .pop_valid_o (tx_fifo_valid),
        .pop_ready_i (tx_fifo_pop)
    );

    // Egress response flits (from local slave serving remote requests) on VC1
    logic [FLIT_W-1:0] tx_rsp_flit_in;
    logic              tx_rsp_push;
    wire               tx_rsp_ready;
    wire [FLIT_W-1:0]  tx_rsp_flit_out;
    wire               tx_rsp_valid;
    wire               tx_rsp_pop;

    ara_noc_fifo #(
        .DATA_W(FLIT_W),
        .DEPTH (4)
    ) u_tx_rsp_fifo (
        .clk         (clk),
        .rst_n       (rst_n),
        .push_data_i (tx_rsp_flit_in),
        .push_valid_i(tx_rsp_push),
        .push_ready_o(tx_rsp_ready),
        .pop_data_o  (tx_rsp_flit_out),
        .pop_valid_o (tx_rsp_valid),
        .pop_ready_i (tx_rsp_pop)
    );

    // Arbitration between VC1 (Responses) and VC0 (Requests) onto NoC TX
    // VC1 has priority /* verified invariant */
    wire tx_grant_vc1 = tx_rsp_valid && noc_tx_ready_i[1];
    wire tx_grant_vc0 = tx_fifo_valid && noc_tx_ready_i[0] && !tx_grant_vc1;

    assign noc_tx_valid_o = tx_grant_vc1 ? 1'b1 : (tx_grant_vc0 ? 1'b1 : 1'b0);
    assign noc_tx_flit_o  = tx_grant_vc1 ? tx_rsp_flit_out : tx_fifo_flit_out;
    assign tx_rsp_pop     = tx_grant_vc1;
    assign tx_fifo_pop    = tx_grant_vc0;

    // Ingress AXI Request State Machine
    always_comb begin
        tx_state_d      = tx_state_q;
        s_axi_awready   = 1'b0;
        s_axi_wready    = 1'b0;
        s_axi_arready   = 1'b0;
        tx_fifo_push    = 1'b0;
        tx_fifo_flit_in = '0;

        case (tx_state_q)
            TX_IDLE: begin
                if (s_axi_awvalid && s_axi_wvalid && tx_fifo_ready) begin
                    // Single or Multi-beat Write
                    s_axi_awready = 1'b1;
                    s_axi_wready  = 1'b1;
                    tx_fifo_push  = 1'b1;

                    if (s_axi_awlen == 8'd0) begin
                        // Single-flit write
                        tx_fifo_flit_in = {
                            FLIT_SINGLE,
                            aw_dest_x,
                            aw_dest_y,
                            4'h0, // VC0
                            {CURR_NODE_X, CURR_NODE_Y, 2'b00}, // Txn ID carries Src (X, Y)
                            // Payload [511:256]: Header metadata
                            {CMD_WRITE_REQ, s_axi_awaddr, s_axi_awlen, s_axi_awsize, s_axi_awburst, s_axi_awid, s_axi_wstrb, 164'd0},
                            // Payload [255:0]: Write Data
                            s_axi_wdata
                        };
                        tx_state_d = TX_IDLE;
                    end else begin
                        // First beat of multi-beat write -> FLIT_HEAD
                        tx_fifo_flit_in = {
                            FLIT_HEAD,
                            aw_dest_x,
                            aw_dest_y,
                            4'h0, // VC0
                            {CURR_NODE_X, CURR_NODE_Y, 2'b00},
                            {CMD_WRITE_REQ, s_axi_awaddr, s_axi_awlen, s_axi_awsize, s_axi_awburst, s_axi_awid, s_axi_wstrb, 164'd0},
                            s_axi_wdata
                        };
                        tx_state_d = TX_WRITE_BURST;
                    end
                end else if (s_axi_arvalid && tx_fifo_ready) begin
                    // Read Request -> always 1 flit (FLIT_SINGLE on VC0)
                    s_axi_arready = 1'b1;
                    tx_fifo_push  = 1'b1;
                    tx_fifo_flit_in = {
                        FLIT_SINGLE,
                        ar_dest_x,
                        ar_dest_y,
                        4'h0, // VC0
                        {CURR_NODE_X, CURR_NODE_Y, 2'b01},
                        {CMD_READ_REQ, s_axi_araddr, s_axi_arlen, s_axi_arsize, s_axi_arburst, s_axi_arid, 196'd0},
                        256'd0
                    };
                    tx_state_d = TX_IDLE;
                end
            end

            TX_WRITE_BURST: begin
                if (s_axi_wvalid && tx_fifo_ready) begin
                    s_axi_wready = 1'b1;
                    tx_fifo_push = 1'b1;

                    if (s_axi_wlast || (tx_cnt_q == tx_len_q)) begin
                        // Final beat -> FLIT_TAIL
                        tx_fifo_flit_in = {
                            FLIT_TAIL,
                            tx_dest_x,
                            tx_dest_y,
                            4'h0,
                            {CURR_NODE_X, CURR_NODE_Y, 2'b00},
                            {CMD_WRITE_REQ, tx_addr_q, tx_len_q, tx_size_q, tx_burst_q, tx_id_q, s_axi_wstrb, 164'd0},
                            s_axi_wdata
                        };
                        tx_state_d = TX_IDLE;
                    end else begin
                        // Intermediate beat -> FLIT_BODY
                        tx_fifo_flit_in = {
                            FLIT_BODY,
                            tx_dest_x,
                            tx_dest_y,
                            4'h0,
                            {CURR_NODE_X, CURR_NODE_Y, 2'b00},
                            {CMD_WRITE_REQ, tx_addr_q, tx_len_q, tx_size_q, tx_burst_q, tx_id_q, s_axi_wstrb, 164'd0},
                            s_axi_wdata
                        };
                        tx_state_d = TX_WRITE_BURST;
                    end
                end
            end

            default: tx_state_d = TX_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_state_q <= TX_IDLE;
            tx_addr_q  <= '0;
            tx_len_q   <= '0;
            tx_cnt_q   <= '0;
            tx_size_q  <= '0;
            tx_burst_q <= '0;
            tx_id_q    <= '0;
        end else begin
            tx_state_q <= tx_state_d;
            if ((tx_state_q == TX_IDLE) && s_axi_awvalid && s_axi_wvalid && tx_fifo_ready && (s_axi_awlen > 0)) begin
                tx_addr_q  <= s_axi_awaddr;
                tx_len_q   <= s_axi_awlen;
                tx_cnt_q   <= 8'd1;
                tx_size_q  <= s_axi_awsize;
                tx_burst_q <= s_axi_awburst;
                tx_id_q    <= s_axi_awid;
            end else if (tx_state_q == TX_WRITE_BURST) begin
                if (s_axi_wvalid && tx_fifo_ready) begin
                    tx_cnt_q <= tx_cnt_q + 1'b1;
                end
            end
        end
    end

    // ------------------------------------------------------------------------
    // 2. Ingress Slave Path (NoC RX VC0 Requests -> Local Cluster AXI Slave)
    // ------------------------------------------------------------------------
    // RX input buffer for VC0 and VC1
    wire [FLIT_W-1:0] rx_vc0_flit;
    wire              rx_vc0_valid;
    logic             rx_vc0_pop;

    wire [FLIT_W-1:0] rx_vc1_flit;
    wire              rx_vc1_valid;
    logic             rx_vc1_pop;

    wire rx_is_vc1 = noc_rx_flit_i[526];
    wire rx_push_vc0 = noc_rx_valid_i && !rx_is_vc1;
    wire rx_push_vc1 = noc_rx_valid_i && rx_is_vc1;

    ara_noc_fifo #(
        .DATA_W(FLIT_W),
        .DEPTH (4)
    ) u_rx_vc0_fifo (
        .clk         (clk),
        .rst_n       (rst_n),
        .push_data_i (noc_rx_flit_i),
        .push_valid_i(rx_push_vc0),
        .push_ready_o(noc_rx_ready_o[0]),
        .pop_data_o  (rx_vc0_flit),
        .pop_valid_o (rx_vc0_valid),
        .pop_ready_i (rx_vc0_pop)
    );

    ara_noc_fifo #(
        .DATA_W(FLIT_W),
        .DEPTH (4)
    ) u_rx_vc1_fifo (
        .clk         (clk),
        .rst_n       (rst_n),
        .push_data_i (noc_rx_flit_i),
        .push_valid_i(rx_push_vc1),
        .push_ready_o(noc_rx_ready_o[1]),
        .pop_data_o  (rx_vc1_flit),
        .pop_valid_o (rx_vc1_valid),
        .pop_ready_i (rx_vc1_pop)
    );

    // Unpack incoming VC0 request flit
    wire [1:0]  rx_req_ftype = rx_vc0_flit[543:542];
    wire [5:0]  rx_src_x     = rx_vc0_flit[525:520];
    wire [5:0]  rx_src_y     = rx_vc0_flit[519:514];
    wire [2:0]  rx_cmd_type  = rx_vc0_flit[511:509];
    wire [39:0] rx_addr      = rx_vc0_flit[508:469];
    wire [7:0]  rx_len       = rx_vc0_flit[468:461];
    wire [2:0]  rx_size      = rx_vc0_flit[460:458];
    wire [1:0]  rx_burst     = rx_vc0_flit[457:456];
    wire [3:0]  rx_id        = rx_vc0_flit[455:452];
    wire [31:0] rx_wstrb     = rx_vc0_flit[451:420];
    wire [255:0] rx_data     = rx_vc0_flit[255:0];

    // Local slave write registers for multi-beat bursts
    logic [5:0] rx_active_src_x_q;
    logic [5:0] rx_active_src_y_q;
    logic [3:0] rx_active_id_q;

    // FSM to drive local cluster AXI Slave
    typedef enum logic [2:0] {
        RX_IDLE,
        RX_WRITE_ADDR,
        RX_WRITE_DATA,
        RX_READ_ADDR,
        RX_READ_WAIT_RESP
    } rx_fsm_e;

    rx_fsm_e rx_state_q, rx_state_d;

    always_comb begin
        rx_state_d    = rx_state_q;
        rx_vc0_pop    = 1'b0;
        m_axi_awvalid = 1'b0;
        m_axi_wvalid  = 1'b0;
        m_axi_arvalid = 1'b0;

        m_axi_awaddr  = rx_addr;
        m_axi_awlen   = rx_len;
        m_axi_awsize  = rx_size;
        m_axi_awburst = rx_burst;
        m_axi_awid    = rx_id;

        m_axi_wdata   = rx_data;
        m_axi_wstrb   = rx_wstrb;
        m_axi_wlast   = (rx_req_ftype == FLIT_SINGLE) || (rx_req_ftype == FLIT_TAIL);

        m_axi_araddr  = rx_addr;
        m_axi_arlen   = rx_len;
        m_axi_arsize  = rx_size;
        m_axi_arburst = rx_burst;
        m_axi_arid    = rx_id;

        case (rx_state_q)
            RX_IDLE: begin
                if (rx_vc0_valid) begin
                    if (rx_cmd_type == CMD_WRITE_REQ) begin
                        m_axi_awvalid = 1'b1;
                        m_axi_wvalid  = 1'b1;
                        if (m_axi_awready && m_axi_wready) begin
                            rx_vc0_pop = 1'b1;
                            if ((rx_req_ftype == FLIT_HEAD)) begin
                                rx_state_d = RX_WRITE_DATA;
                            end else begin
                                rx_state_d = RX_IDLE; // SINGLE flit write complete
                            end
                        end else if (m_axi_awready) begin
                            // AW accepted, waiting for W
                            rx_state_d = RX_WRITE_DATA;
                        end else begin
                            rx_state_d = RX_WRITE_ADDR;
                        end
                    end else if (rx_cmd_type == CMD_READ_REQ) begin
                        m_axi_arvalid = 1'b1;
                        if (m_axi_arready) begin
                            rx_vc0_pop = 1'b1;
                            rx_state_d = RX_READ_WAIT_RESP;
                        end else begin
                            rx_state_d = RX_READ_ADDR;
                        end
                    end else begin
                        // Malformed / unknown command type: discard flit to prevent VC0 FIFO deadlock
                        rx_vc0_pop = 1'b1;
                    end
                end
            end

            RX_WRITE_ADDR: begin
                m_axi_awvalid = 1'b1;
                if (m_axi_awready) begin
                    rx_state_d = RX_WRITE_DATA;
                end
            end

            RX_WRITE_DATA: begin
                if (rx_vc0_valid) begin
                    m_axi_wvalid = 1'b1;
                    if (m_axi_wready) begin
                        rx_vc0_pop = 1'b1;
                        if ((rx_req_ftype == FLIT_TAIL) || (rx_req_ftype == FLIT_SINGLE)) begin
                            rx_state_d = RX_IDLE;
                        end
                    end
                end
            end

            RX_READ_ADDR: begin
                m_axi_arvalid = 1'b1;
                if (m_axi_arready) begin
                    rx_vc0_pop = 1'b1;
                    rx_state_d = RX_READ_WAIT_RESP;
                end
            end

            RX_READ_WAIT_RESP: begin
                // Hold lock until the slave responder completes the burst and transmits rlast
                if (m_axi_rvalid && tx_rsp_ready && m_axi_rlast) begin
                    rx_state_d = RX_IDLE;
                end
            end

            default: rx_state_d = RX_IDLE;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_state_q        <= RX_IDLE;
            rx_active_src_x_q <= '0;
            rx_active_src_y_q <= '0;
            rx_active_id_q    <= '0;
        end else begin
            rx_state_q <= rx_state_d;
            if ((rx_state_q == RX_IDLE) && rx_vc0_valid) begin
                rx_active_src_x_q <= rx_src_x;
                rx_active_src_y_q <= rx_src_y;
                rx_active_id_q    <= rx_id;
            end
        end
    end

    // Track read response burst beat counter to generate proper wormhole packet framing
    logic [7:0] rx_r_beat_cnt_q;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_r_beat_cnt_q <= 8'd0;
        end else begin
            if (m_axi_rvalid && tx_rsp_ready && !m_axi_bvalid) begin
                if (m_axi_rlast) begin
                    rx_r_beat_cnt_q <= 8'd0;
                end else begin
                    rx_r_beat_cnt_q <= rx_r_beat_cnt_q + 8'd1;
                end
            end
        end
    end

    logic [1:0] r_flit_type;
    always_comb begin
        if (rx_r_beat_cnt_q == 8'd0) begin
            r_flit_type = m_axi_rlast ? FLIT_SINGLE : FLIT_HEAD;
        end else begin
            r_flit_type = m_axi_rlast ? FLIT_TAIL : FLIT_BODY;
        end
    end

    // ------------------------------------------------------------------------
    // 3. Egress Response Path (Local Slave -> NoC TX VC1)
    // ------------------------------------------------------------------------
    // Returns write response (B channel) or read data (R channel) back to requester
    assign m_axi_bready = tx_rsp_ready;
    assign m_axi_rready = tx_rsp_ready && !m_axi_bvalid; // B has priority

    always_comb begin
        tx_rsp_push     = 1'b0;
        tx_rsp_flit_in  = '0;

        if (m_axi_bvalid && tx_rsp_ready) begin
            tx_rsp_push = 1'b1;
            tx_rsp_flit_in = {
                FLIT_SINGLE,
                rx_active_src_x_q,
                rx_active_src_y_q,
                4'h1, // VC1
                {CURR_NODE_X, CURR_NODE_Y, 2'b10},
                {RSP_WRITE, m_axi_bid, m_axi_bresp, 247'd0},
                256'd0
            };
        end else if (m_axi_rvalid && tx_rsp_ready) begin
            tx_rsp_push = 1'b1;
            tx_rsp_flit_in = {
                r_flit_type,
                rx_active_src_x_q,
                rx_active_src_y_q,
                4'h1, // VC1
                {CURR_NODE_X, CURR_NODE_Y, 2'b11},
                {RSP_READ, m_axi_rid, m_axi_rresp, m_axi_rlast, 246'd0},
                m_axi_rdata
            };
        end
    end

    // ------------------------------------------------------------------------
    // 4. Egress Master Completion Path (NoC RX VC1 -> Cluster Master)
    // ------------------------------------------------------------------------
    // Unpack VC1 responses and deliver to s_axi_b* or s_axi_r*
    wire [2:0]   vc1_rsp_type = rx_vc1_flit[511:509];
    wire [3:0]   vc1_id       = rx_vc1_flit[508:505];
    wire [1:0]   vc1_resp     = rx_vc1_flit[504:503];
    wire         vc1_rlast    = rx_vc1_flit[502];
    wire [255:0] vc1_rdata    = rx_vc1_flit[255:0];

    wire is_b_rsp = rx_vc1_valid && (vc1_rsp_type == RSP_WRITE);
    wire is_r_rsp = rx_vc1_valid && (vc1_rsp_type == RSP_READ);

    assign s_axi_bid    = vc1_id;
    assign s_axi_bresp  = vc1_resp;
    assign s_axi_bvalid = is_b_rsp;

    assign s_axi_rid    = vc1_id;
    assign s_axi_rresp  = vc1_resp;
    assign s_axi_rlast  = vc1_rlast;
    assign s_axi_rdata  = vc1_rdata;
    assign s_axi_rvalid = is_r_rsp;

    assign rx_vc1_pop = (is_b_rsp && s_axi_bready) || (is_r_rsp && s_axi_rready) ||
                        (rx_vc1_valid && !is_b_rsp && !is_r_rsp);

`ifdef FORMAL
    // Reset assumption
    logic [2:0] f_rst_cnt = 0;
    always @(posedge clk) begin
        if (f_rst_cnt < 3'd2) f_rst_cnt <= f_rst_cnt + 1'b1;
    end
    always_comb begin
        if (f_rst_cnt < 3'd2) assume (!rst_n);
        else assume (rst_n);
    end

    // Safety Invariant 1: Source Coordinate Authenticity
    // Any request packet queued in TX FIFO must carry the exact local node coordinates
    always_comb begin
        if (tx_fifo_valid) begin
            assert (tx_fifo_flit_out[525:520] == CURR_NODE_X);
            assert (tx_fifo_flit_out[519:514] == CURR_NODE_Y);
        end
    end

    // Safety Invariant 2: Virtual Channel Separation
    // Outbound requests must strictly be on VC0
    always_comb begin
        if (tx_fifo_valid) begin
            assert (tx_fifo_flit_out[526] == 1'b0);
        end
    end

    // Outbound responses must strictly be on VC1
    always_comb begin
        if (tx_rsp_valid) begin
            assert (tx_rsp_flit_out[526] == 1'b1);
        end
    end

    // Safety Invariant 3: Response Demux Mutual Exclusion
    // s_axi_bvalid and s_axi_rvalid can never both be asserted simultaneously from a single VC1 response
    always_comb begin
        assert (!(s_axi_bvalid && s_axi_rvalid));
    end

    // Safety Invariant 4: ID Match on Response
    always_comb begin
        if (s_axi_bvalid) begin
            assert (s_axi_bid == vc1_id);
        end
        if (s_axi_rvalid) begin
            assert (s_axi_rid == vc1_id);
        end
    end
`endif

endmodule
