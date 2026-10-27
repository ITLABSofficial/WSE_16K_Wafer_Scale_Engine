// ============================================================================
// File: ara_hbm3_interposer_p2p.sv
// Project: Ara_OpenHBM3_SoC (Active Interposer Subsystem)
// Technology: ASAP7 7nm FinFET Predictive PDK (Target: 759.2 MHz / 1.317 ns)
// Specification: PROJECT_MEMORY.md (Section 1 & Section 4.3)
// Defensive Rules: HATALAR.md (HATA 21, 46, 47, 48)
//
// Description:
//   2x2 Active Interposer AXI5 Crossbar & Inter-Stack Peer-to-Peer Bridge.
//   Connects Host/Ara Vector Cores (Slave 0) and Base-Die PIM (Slave 1)
//   to Stack 0 (Master 0) and Stack 1 (Master 1) with 2-stage pipeline slices
//   to prevent RC timing degradation across 5-10 mm interposer lines.
//   Features Even-Odd Round-Robin arbitration to guarantee starvation freedom.
// ============================================================================

`timescale 1ps/1fs

module ara_hbm3_interposer_p2p #(
    parameter int unsigned DATA_W       = 256,
    parameter int unsigned ADDR_W       = 64,
    parameter int unsigned ID_W         = 4,
    parameter int unsigned PIPELINE_STG = 2     // 2-stage slice (HATA 47)
)(
    input  logic              clk_hbm,
    input  logic              rst_hbm_n,

    // ------------------------------------------------------------------------
    // Slave Port 0: Host / Ara Vector Unit (ARID=4'hE)
    // ------------------------------------------------------------------------
    input  logic [ADDR_W-1:0] s0_axi_araddr,
    input  logic [ID_W-1:0]   s0_axi_arid,
    input  logic [7:0]        s0_axi_arlen,
    input  logic              s0_axi_arvalid,
    output logic              s0_axi_arrdy,

    output logic [DATA_W-1:0] s0_axi_rdata,
    output logic [ID_W-1:0]   s0_axi_rid,
    output logic [1:0]        s0_axi_rresp,
    output logic              s0_axi_rlast,
    output logic              s0_axi_rvalid,
    input  logic              s0_axi_rrdy,

    input  logic [ADDR_W-1:0] s0_axi_awaddr,
    input  logic [ID_W-1:0]   s0_axi_awid,
    input  logic [7:0]        s0_axi_awlen,
    input  logic              s0_axi_awvalid,
    output logic              s0_axi_awrdy,

    input  logic [DATA_W-1:0] s0_axi_wdata,
    input  logic [DATA_W/8-1:0] s0_axi_wstrb,
    input  logic              s0_axi_wlast,
    input  logic              s0_axi_wvalid,
    output logic              s0_axi_wrdy,

    output logic [ID_W-1:0]   s0_axi_bid,
    output logic [1:0]        s0_axi_bresp,
    output logic              s0_axi_bvalid,
    input  logic              s0_axi_brdy,

    // ------------------------------------------------------------------------
    // Slave Port 1: Base-Die PIM Master Port (ARID=4'hA)
    // ------------------------------------------------------------------------
    input  logic [ADDR_W-1:0] s1_axi_araddr,
    input  logic [ID_W-1:0]   s1_axi_arid,
    input  logic [7:0]        s1_axi_arlen,
    input  logic              s1_axi_arvalid,
    output logic              s1_axi_arrdy,

    output logic [DATA_W-1:0] s1_axi_rdata,
    output logic [ID_W-1:0]   s1_axi_rid,
    output logic [1:0]        s1_axi_rresp,
    output logic              s1_axi_rlast,
    output logic              s1_axi_rvalid,
    input  logic              s1_axi_rrdy,

    input  logic [ADDR_W-1:0] s1_axi_awaddr,
    input  logic [ID_W-1:0]   s1_axi_awid,
    input  logic [7:0]        s1_axi_awlen,
    input  logic              s1_axi_awvalid,
    output logic              s1_axi_awrdy,

    input  logic [DATA_W-1:0] s1_axi_wdata,
    input  logic [DATA_W/8-1:0] s1_axi_wstrb,
    input  logic              s1_axi_wlast,
    input  logic              s1_axi_wvalid,
    output logic              s1_axi_wrdy,

    output logic [ID_W-1:0]   s1_axi_bid,
    output logic [1:0]        s1_axi_bresp,
    output logic              s1_axi_bvalid,
    input  logic              s1_axi_brdy,

    // ------------------------------------------------------------------------
    // Master Port 0: HBM3 Stack 0 (Addresses 0x1_0000_0000 .. 0x4_FFFF_FFFF)
    // ------------------------------------------------------------------------
    output logic [ADDR_W-1:0] m0_axi_araddr,
    output logic [ID_W-1:0]   m0_axi_arid,
    output logic [7:0]        m0_axi_arlen,
    output logic              m0_axi_arvalid,
    input  logic              m0_axi_arrdy,

    input  logic [DATA_W-1:0] m0_axi_rdata,
    input  logic [ID_W-1:0]   m0_axi_rid,
    input  logic [1:0]        m0_axi_rresp,
    input  logic              m0_axi_rlast,
    input  logic              m0_axi_rvalid,
    output logic              m0_axi_rrdy,

    output logic [ADDR_W-1:0] m0_axi_awaddr,
    output logic [ID_W-1:0]   m0_axi_awid,
    output logic [7:0]        m0_axi_awlen,
    output logic              m0_axi_awvalid,
    input  logic              m0_axi_awrdy,

    output logic [DATA_W-1:0] m0_axi_wdata,
    output logic [DATA_W/8-1:0] m0_axi_wstrb,
    output logic              m0_axi_wlast,
    output logic              m0_axi_wvalid,
    input  logic              m0_axi_wrdy,

    input  logic [ID_W-1:0]   m0_axi_bid,
    input  logic [1:0]        m0_axi_bresp,
    input  logic              m0_axi_bvalid,
    output logic              m0_axi_brdy,

    // ------------------------------------------------------------------------
    // Master Port 1: HBM3 Stack 1 (Addresses 0x5_0000_0000 .. 0x8_FFFF_FFFF)
    // ------------------------------------------------------------------------
    output logic [ADDR_W-1:0] m1_axi_araddr,
    output logic [ID_W-1:0]   m1_axi_arid,
    output logic [7:0]        m1_axi_arlen,
    output logic              m1_axi_arvalid,
    input  logic              m1_axi_arrdy,

    input  logic [DATA_W-1:0] m1_axi_rdata,
    input  logic [ID_W-1:0]   m1_axi_rid,
    input  logic [1:0]        m1_axi_rresp,
    input  logic              m1_axi_rlast,
    input  logic              m1_axi_rvalid,
    output logic              m1_axi_rrdy,

    output logic [ADDR_W-1:0] m1_axi_awaddr,
    output logic [ID_W-1:0]   m1_axi_awid,
    output logic [7:0]        m1_axi_awlen,
    output logic              m1_axi_awvalid,
    input  logic              m1_axi_awrdy,

    output logic [DATA_W-1:0] m1_axi_wdata,
    output logic [DATA_W/8-1:0] m1_axi_wstrb,
    output logic              m1_axi_wlast,
    output logic              m1_axi_wvalid,
    input  logic              m1_axi_wrdy,

    input  logic [ID_W-1:0]   m1_axi_bid,
    input  logic [1:0]        m1_axi_bresp,
    input  logic              m1_axi_bvalid,
    output logic              m1_axi_brdy,

    // ------------------------------------------------------------------------
    // Inter-Stack P2P Direct Stream (Stack 0 <-> Stack 1 All-Reduce)
    // ------------------------------------------------------------------------
    input  logic [DATA_W-1:0] p2p_s0_tx_data,
    input  logic              p2p_s0_tx_valid,
    output logic              p2p_s0_tx_ready,

    output logic [DATA_W-1:0] p2p_s1_rx_data,
    output logic              p2p_s1_rx_valid,
    input  logic              p2p_s1_rx_ready,

    input  logic [DATA_W-1:0] p2p_s1_tx_data,
    input  logic              p2p_s1_tx_valid,
    output logic              p2p_s1_tx_ready,

    output logic [DATA_W-1:0] p2p_s0_rx_data,
    output logic              p2p_s0_rx_valid,
    input  logic              p2p_s0_rx_ready,

    // Interposer Hardware Barriers (0-Delay Fast Sync)
    output logic              stack0_barrier_out,
    input  logic              stack0_barrier_in,
    output logic              stack1_barrier_out,
    input  logic              stack1_barrier_in
);

    // ========================================================================
    // 1. Address Decode for Master Selection (PROJECT_MEMORY.md Section 2)
    // ========================================================================
    // Target Stack 0 if address is in [0x1_0000_0000 .. 0x4_FFFF_FFFF] (bit 34 == 0)
    // Target Stack 1 if address is in [0x5_0000_0000 .. 0x8_FFFF_FFFF] (bit 34 == 1)
    logic s0_ar_to_m1, s0_aw_to_m1;
    logic s1_ar_to_m1, s1_aw_to_m1;

    assign s0_ar_to_m1 = (s0_axi_araddr >= 64'h0000_0005_0000_0000);
    assign s0_aw_to_m1 = (s0_axi_awaddr >= 64'h0000_0005_0000_0000);
    assign s1_ar_to_m1 = (s1_axi_araddr >= 64'h0000_0005_0000_0000);
    assign s1_aw_to_m1 = (s1_axi_awaddr >= 64'h0000_0005_0000_0000);

    // ========================================================================
    // 2. Read Address (AR) Channel Routing & 2-Stage Pipeline Slice (HATA 47)
    // ========================================================================
    // 2. Read Address (AR) Channel Routing & 2-Stage Pipeline Slice (HATA 47 & HATA 60)
    // ========================================================================
    typedef struct packed {
        logic [ADDR_W-1:0] addr;
        logic [ID_W-1:0]   id;
        logic [7:0]        len;
        logic              valid;
    } ar_slice_t;

    ar_slice_t ar_m0_r1, ar_m0_r2;
    ar_slice_t ar_m1_r1, ar_m1_r2;

    // Arbitration state for AR to M0 and M1
    logic ar_m0_prio_s1;
    logic ar_m1_prio_s1;

    wire m0_r2_ready = !ar_m0_r2.valid || m0_axi_arrdy;
    wire m0_r1_ready = !ar_m0_r1.valid || m0_r2_ready;

    wire m1_r2_ready = !ar_m1_r2.valid || m1_axi_arrdy;
    wire m1_r1_ready = !ar_m1_r1.valid || m1_r2_ready;

    always_ff @(posedge clk_hbm or negedge rst_hbm_n) begin
        if (!rst_hbm_n) begin
            ar_m0_r1 <= '0; ar_m0_r2 <= '0;
            ar_m1_r1 <= '0; ar_m1_r2 <= '0;
            ar_m0_prio_s1 <= 1'b0;
            ar_m1_prio_s1 <= 1'b0;
        end else begin
            // ---------------- M0 AR Arbitration ----------------
            if (m0_r1_ready) begin
                if ((s1_axi_arvalid && !s1_ar_to_m1 && ar_m0_prio_s1) ||
                    (s1_axi_arvalid && !s1_ar_to_m1 && !(s0_axi_arvalid && !s0_ar_to_m1))) begin
                    ar_m0_r1.addr  <= s1_axi_araddr;
                    ar_m0_r1.id    <= s1_axi_arid;
                    ar_m0_r1.len   <= s1_axi_arlen;
                    ar_m0_r1.valid <= 1'b1;
                    ar_m0_prio_s1  <= 1'b0;
                end else if (s0_axi_arvalid && !s0_ar_to_m1) begin
                    ar_m0_r1.addr  <= s0_axi_araddr;
                    ar_m0_r1.id    <= s0_axi_arid;
                    ar_m0_r1.len   <= s0_axi_arlen;
                    ar_m0_r1.valid <= 1'b1;
                    ar_m0_prio_s1  <= 1'b1;
                end else begin
                    ar_m0_r1.valid <= 1'b0;
                end
            end
            if (m0_r2_ready) begin
                ar_m0_r2 <= ar_m0_r1;
            end

            // ---------------- M1 AR Arbitration ----------------
            if (m1_r1_ready) begin
                if ((s1_axi_arvalid && s1_ar_to_m1 && ar_m1_prio_s1) ||
                    (s1_axi_arvalid && s1_ar_to_m1 && !(s0_axi_arvalid && s0_ar_to_m1))) begin
                    ar_m1_r1.addr  <= s1_axi_araddr;
                    ar_m1_r1.id    <= s1_axi_arid;
                    ar_m1_r1.len   <= s1_axi_arlen;
                    ar_m1_r1.valid <= 1'b1;
                    ar_m1_prio_s1  <= 1'b0;
                end else if (s0_axi_arvalid && s0_ar_to_m1) begin
                    ar_m1_r1.addr  <= s0_axi_araddr;
                    ar_m1_r1.id    <= s0_axi_arid;
                    ar_m1_r1.len   <= s0_axi_arlen;
                    ar_m1_r1.valid <= 1'b1;
                    ar_m1_prio_s1  <= 1'b1;
                end else begin
                    ar_m1_r1.valid <= 1'b0;
                end
            end
            if (m1_r2_ready) begin
                ar_m1_r2 <= ar_m1_r1;
            end
        end
    end

    assign m0_axi_araddr  = ar_m0_r2.addr;
    assign m0_axi_arid    = ar_m0_r2.id;
    assign m0_axi_arlen   = ar_m0_r2.len;
    assign m0_axi_arvalid = ar_m0_r2.valid;

    assign m1_axi_araddr  = ar_m1_r2.addr;
    assign m1_axi_arid    = ar_m1_r2.id;
    assign m1_axi_arlen   = ar_m1_r2.len;
    assign m1_axi_arvalid = ar_m1_r2.valid;

    assign s0_axi_arrdy   = s0_ar_to_m1 ? m1_r1_ready : m0_r1_ready;
    assign s1_axi_arrdy   = s1_ar_to_m1 ? m1_r1_ready : m0_r1_ready;

    // ========================================================================
    // 3. Read Data (R) Channel MUX & Routing (By ID: ID 4'hA = S1, else S0)
    // ========================================================================
    logic m0_is_s1_r, m1_is_s1_r;
    assign m0_is_s1_r = (m0_axi_rid == 4'hA);
    assign m1_is_s1_r = (m1_axi_rid == 4'hA);

    // Round-robin arbitration for S0 R channel between M0 and M1
    logic r_s0_prio_m1;
    always_ff @(posedge clk_hbm or negedge rst_hbm_n) begin
        if (!rst_hbm_n) r_s0_prio_m1 <= 1'b0;
        else if (s0_axi_rvalid && s0_axi_rrdy) r_s0_prio_m1 <= ~r_s0_prio_m1;
    end

    wire s0_grant_m1 = (m1_axi_rvalid && !m1_is_s1_r) && (r_s0_prio_m1 || !(m0_axi_rvalid && !m0_is_s1_r));

    // S0 Read Data Multiplexer
    always @* begin
        if (s0_grant_m1) begin
            s0_axi_rdata  = m1_axi_rdata;
            s0_axi_rid    = m1_axi_rid;
            s0_axi_rresp  = m1_axi_rresp;
            s0_axi_rlast  = m1_axi_rlast;
            s0_axi_rvalid = 1'b1;
        end else if (m0_axi_rvalid && !m0_is_s1_r) begin
            s0_axi_rdata  = m0_axi_rdata;
            s0_axi_rid    = m0_axi_rid;
            s0_axi_rresp  = m0_axi_rresp;
            s0_axi_rlast  = m0_axi_rlast;
            s0_axi_rvalid = 1'b1;
        end else begin
            s0_axi_rdata  = '0;
            s0_axi_rid    = '0;
            s0_axi_rresp  = 2'b00;
            s0_axi_rlast  = 1'b0;
            s0_axi_rvalid = 1'b0;
        end
    end

    // S1 Read Data Multiplexer (PIM stream)
    always @* begin
        if (m0_axi_rvalid && m0_is_s1_r) begin
            s1_axi_rdata  = m0_axi_rdata;
            s1_axi_rid    = m0_axi_rid;
            s1_axi_rresp  = m0_axi_rresp;
            s1_axi_rlast  = m0_axi_rlast;
            s1_axi_rvalid = 1'b1;
        end else if (m1_axi_rvalid && m1_is_s1_r) begin
            s1_axi_rdata  = m1_axi_rdata;
            s1_axi_rid    = m1_axi_rid;
            s1_axi_rresp  = m1_axi_rresp;
            s1_axi_rlast  = m1_axi_rlast;
            s1_axi_rvalid = 1'b1;
        end else begin
            s1_axi_rdata  = '0;
            s1_axi_rid    = '0;
            s1_axi_rresp  = 2'b00;
            s1_axi_rlast  = 1'b0;
            s1_axi_rvalid = 1'b0;
        end
    end

    assign m0_axi_rrdy = m0_is_s1_r ? s1_axi_rrdy : (s0_axi_rrdy && !s0_grant_m1);
    assign m1_axi_rrdy = m1_is_s1_r ? (s1_axi_rrdy && !(m0_axi_rvalid && m0_is_s1_r)) :
                                      (s0_axi_rrdy && s0_grant_m1);

    // ========================================================================
    // 4. Write Channels (AW, W, B) Forwarding & Atomic Ownership (HATA 59)
    // ========================================================================
    typedef enum logic [1:0] {
        W_OWNER_IDLE = 2'd0,
        W_OWNER_S0   = 2'd1,
        W_OWNER_S1   = 2'd2
    } w_owner_t;

    w_owner_t w_owner_m0_q;
    w_owner_t w_owner_m1_q;

    // Arbitrate AW between S0 and S1 for M0
    logic aw_m0_prio_s1;
    always_ff @(posedge clk_hbm or negedge rst_hbm_n) begin
        if (!rst_hbm_n) aw_m0_prio_s1 <= 1'b0;
        else if (m0_axi_awvalid && m0_axi_awrdy) aw_m0_prio_s1 <= ~aw_m0_prio_s1;
    end

    wire s1_aw_req_m0 = s1_axi_awvalid && !s1_aw_to_m1;
    wire s0_aw_req_m0 = s0_axi_awvalid && !s0_aw_to_m1;
    wire grant_s1_aw_m0 = s1_aw_req_m0 && (aw_m0_prio_s1 || !s0_aw_req_m0);

    // Track active write burst ownership for M0
    always_ff @(posedge clk_hbm or negedge rst_hbm_n) begin
        if (!rst_hbm_n) begin
            w_owner_m0_q <= W_OWNER_IDLE;
        end else begin
            case (w_owner_m0_q)
                W_OWNER_IDLE: begin
                    if (m0_axi_awvalid && m0_axi_awrdy) begin
                        if (!(m0_axi_wvalid && m0_axi_wrdy && m0_axi_wlast)) begin
                            w_owner_m0_q <= grant_s1_aw_m0 ? W_OWNER_S1 : W_OWNER_S0;
                        end
                    end
                end
                W_OWNER_S0: begin
                    if (m0_axi_wvalid && m0_axi_wrdy && m0_axi_wlast) begin
                        w_owner_m0_q <= W_OWNER_IDLE;
                    end
                end
                W_OWNER_S1: begin
                    if (m0_axi_wvalid && m0_axi_wrdy && m0_axi_wlast) begin
                        w_owner_m0_q <= W_OWNER_IDLE;
                    end
                end
                default: w_owner_m0_q <= W_OWNER_IDLE;
            endcase
        end
    end

    assign m0_axi_awaddr  = grant_s1_aw_m0 ? s1_axi_awaddr  : s0_axi_awaddr;
    assign m0_axi_awid    = grant_s1_aw_m0 ? s1_axi_awid    : s0_axi_awid;
    assign m0_axi_awlen   = grant_s1_aw_m0 ? s1_axi_awlen   : s0_axi_awlen;
    assign m0_axi_awvalid = (w_owner_m0_q == W_OWNER_IDLE) && (grant_s1_aw_m0 ? s1_axi_awvalid : s0_aw_req_m0);

    wire m0_w_from_s1 = (w_owner_m0_q == W_OWNER_S1) || (w_owner_m0_q == W_OWNER_IDLE && grant_s1_aw_m0);

    // Track write burst destination stack for S0 and S1 via FIFO (HATA 69)
    logic [3:0] s0_aw_dest_fifo;
    logic [1:0] s0_aw_wptr, s0_aw_rptr;
    logic [2:0] s0_aw_count;
    wire        s0_aw_fire      = s0_axi_awvalid && s0_axi_awrdy;
    wire        s0_w_fire_last  = s0_axi_wvalid && s0_axi_wrdy && s0_axi_wlast;

    logic [3:0] s1_aw_dest_fifo;
    logic [1:0] s1_aw_wptr, s1_aw_rptr;
    logic [2:0] s1_aw_count;
    wire        s1_aw_fire      = s1_axi_awvalid && s1_axi_awrdy;
    wire        s1_w_fire_last  = s1_axi_wvalid && s1_axi_wrdy && s1_axi_wlast;

    always_ff @(posedge clk_hbm or negedge rst_hbm_n) begin
        if (!rst_hbm_n) begin
            s0_aw_dest_fifo <= 4'd0;
            s0_aw_wptr      <= 2'd0;
            s0_aw_rptr      <= 2'd0;
            s0_aw_count     <= 3'd0;
            s1_aw_dest_fifo <= 4'd0;
            s1_aw_wptr      <= 2'd0;
            s1_aw_rptr      <= 2'd0;
            s1_aw_count     <= 3'd0;
        end else begin
            // S0 AW Destination Queue
            case ({s0_aw_fire, s0_w_fire_last})
                2'b10: begin
                    s0_aw_dest_fifo[s0_aw_wptr] <= s0_aw_to_m1;
                    s0_aw_wptr  <= s0_aw_wptr + 2'd1;
                    s0_aw_count <= s0_aw_count + 3'd1;
                end
                2'b01: begin
                    s0_aw_rptr  <= s0_aw_rptr + 2'd1;
                    s0_aw_count <= s0_aw_count - 3'd1;
                end
                2'b11: begin
                    s0_aw_dest_fifo[s0_aw_wptr] <= s0_aw_to_m1;
                    s0_aw_wptr  <= s0_aw_wptr + 2'd1;
                    s0_aw_rptr  <= s0_aw_rptr + 2'd1;
                end
                default: ;
            endcase

            // S1 AW Destination Queue
            case ({s1_aw_fire, s1_w_fire_last})
                2'b10: begin
                    s1_aw_dest_fifo[s1_aw_wptr] <= s1_aw_to_m1;
                    s1_aw_wptr  <= s1_aw_wptr + 2'd1;
                    s1_aw_count <= s1_aw_count + 3'd1;
                end
                2'b01: begin
                    s1_aw_rptr  <= s1_aw_rptr + 2'd1;
                    s1_aw_count <= s1_aw_count - 3'd1;
                end
                2'b11: begin
                    s1_aw_dest_fifo[s1_aw_wptr] <= s1_aw_to_m1;
                    s1_aw_wptr  <= s1_aw_wptr + 2'd1;
                    s1_aw_rptr  <= s1_aw_rptr + 2'd1;
                end
                default: ;
            endcase
        end
    end

    wire s0_w_to_m1_active = (s0_aw_count > 3'd0) ? s0_aw_dest_fifo[s0_aw_rptr] : s0_aw_to_m1;
    wire s1_w_to_m1_active = (s1_aw_count > 3'd0) ? s1_aw_dest_fifo[s1_aw_rptr] : s1_aw_to_m1;

    assign m0_axi_wdata   = m0_w_from_s1 ? s1_axi_wdata   : s0_axi_wdata;
    assign m0_axi_wstrb   = m0_w_from_s1 ? s1_axi_wstrb   : s0_axi_wstrb;
    assign m0_axi_wlast   = m0_w_from_s1 ? s1_axi_wlast   : s0_axi_wlast;
    assign m0_axi_wvalid  = m0_w_from_s1 ? (s1_axi_wvalid && !s1_w_to_m1_active) : (s0_axi_wvalid && !s0_w_to_m1_active);

    // Arbitrate AW between S0 and S1 for M1 (Stack 1)
    logic aw_m1_prio_s1;
    always_ff @(posedge clk_hbm or negedge rst_hbm_n) begin
        if (!rst_hbm_n) aw_m1_prio_s1 <= 1'b0;
        else if (m1_axi_awvalid && m1_axi_awrdy) aw_m1_prio_s1 <= ~aw_m1_prio_s1;
    end

    wire s1_aw_req_m1 = s1_axi_awvalid && s1_aw_to_m1;
    wire s0_aw_req_m1 = s0_axi_awvalid && s0_aw_to_m1;
    wire grant_s1_aw_m1 = s1_aw_req_m1 && (aw_m1_prio_s1 || !s0_aw_req_m1);

    // Track active write burst ownership for M1
    always_ff @(posedge clk_hbm or negedge rst_hbm_n) begin
        if (!rst_hbm_n) begin
            w_owner_m1_q <= W_OWNER_IDLE;
        end else begin
            case (w_owner_m1_q)
                W_OWNER_IDLE: begin
                    if (m1_axi_awvalid && m1_axi_awrdy) begin
                        if (!(m1_axi_wvalid && m1_axi_wrdy && m1_axi_wlast)) begin
                            w_owner_m1_q <= grant_s1_aw_m1 ? W_OWNER_S1 : W_OWNER_S0;
                        end
                    end
                end
                W_OWNER_S0: begin
                    if (m1_axi_wvalid && m1_axi_wrdy && m1_axi_wlast) begin
                        w_owner_m1_q <= W_OWNER_IDLE;
                    end
                end
                W_OWNER_S1: begin
                    if (m1_axi_wvalid && m1_axi_wrdy && m1_axi_wlast) begin
                        w_owner_m1_q <= W_OWNER_IDLE;
                    end
                end
                default: w_owner_m1_q <= W_OWNER_IDLE;
            endcase
        end
    end

    assign m1_axi_awaddr  = grant_s1_aw_m1 ? s1_axi_awaddr  : s0_axi_awaddr;
    assign m1_axi_awid    = grant_s1_aw_m1 ? s1_axi_awid    : s0_axi_awid;
    assign m1_axi_awlen   = grant_s1_aw_m1 ? s1_axi_awlen   : s0_axi_awlen;
    assign m1_axi_awvalid = (w_owner_m1_q == W_OWNER_IDLE) && (grant_s1_aw_m1 ? s1_axi_awvalid : s0_aw_req_m1);

    wire m1_w_from_s1 = (w_owner_m1_q == W_OWNER_S1) || (w_owner_m1_q == W_OWNER_IDLE && grant_s1_aw_m1);

    assign m1_axi_wdata   = m1_w_from_s1 ? s1_axi_wdata   : s0_axi_wdata;
    assign m1_axi_wstrb   = m1_w_from_s1 ? s1_axi_wstrb   : s0_axi_wstrb;
    assign m1_axi_wlast   = m1_w_from_s1 ? s1_axi_wlast   : s0_axi_wlast;
    assign m1_axi_wvalid  = m1_w_from_s1 ? (s1_axi_wvalid && s1_w_to_m1_active) : (s0_axi_wvalid && s0_w_to_m1_active);

    assign s0_axi_awrdy   = s0_aw_to_m1 ? (!grant_s1_aw_m1 && (w_owner_m1_q == W_OWNER_IDLE) && m1_axi_awrdy) :
                                          (!grant_s1_aw_m0 && (w_owner_m0_q == W_OWNER_IDLE) && m0_axi_awrdy);
    assign s1_axi_awrdy   = s1_aw_to_m1 ? (grant_s1_aw_m1 && (w_owner_m1_q == W_OWNER_IDLE) && m1_axi_awrdy) :
                                          (grant_s1_aw_m0 && (w_owner_m0_q == W_OWNER_IDLE) && m0_axi_awrdy);

    assign s0_axi_wrdy    = s0_w_to_m1_active ? (!m1_w_from_s1 && m1_axi_wrdy) :
                                                (!m0_w_from_s1 && m0_axi_wrdy);
    assign s1_axi_wrdy    = s1_w_to_m1_active ? (m1_w_from_s1 && m1_axi_wrdy) :
                                                (m0_w_from_s1 && m0_axi_wrdy);

    // Write Response (B) Routing with cross-stack isolation & Round-Robin (HATA 58 / HATA 70)
    wire m0_is_s1_b = (m0_axi_bid == 4'hA);
    wire m1_is_s1_b = (m1_axi_bid == 4'hA);

    // Round-robin arbitration for S0 B channel between M0 and M1
    logic b_s0_prio_m1;
    always_ff @(posedge clk_hbm or negedge rst_hbm_n) begin
        if (!rst_hbm_n) b_s0_prio_m1 <= 1'b0;
        else if (s0_axi_bvalid && s0_axi_brdy) b_s0_prio_m1 <= ~b_s0_prio_m1;
    end

    wire s0_b_grant_m1 = (m1_axi_bvalid && !m1_is_s1_b) && (b_s0_prio_m1 || !(m0_axi_bvalid && !m0_is_s1_b));

    always @* begin
        if (s0_b_grant_m1) begin
            s0_axi_bid    = m1_axi_bid;
            s0_axi_bresp  = m1_axi_bresp;
            s0_axi_bvalid = 1'b1;
        end else if (m0_axi_bvalid && !m0_is_s1_b) begin
            s0_axi_bid    = m0_axi_bid;
            s0_axi_bresp  = m0_axi_bresp;
            s0_axi_bvalid = 1'b1;
        end else begin
            s0_axi_bid    = '0;
            s0_axi_bresp  = 2'b00;
            s0_axi_bvalid = 1'b0;
        end
    end

    // Round-robin arbitration for S1 B channel between M0 and M1
    logic b_s1_prio_m1;
    always_ff @(posedge clk_hbm or negedge rst_hbm_n) begin
        if (!rst_hbm_n) b_s1_prio_m1 <= 1'b0;
        else if (s1_axi_bvalid && s1_axi_brdy) b_s1_prio_m1 <= ~b_s1_prio_m1;
    end

    wire s1_b_grant_m1 = (m1_axi_bvalid && m1_is_s1_b) && (b_s1_prio_m1 || !(m0_axi_bvalid && m0_is_s1_b));

    always @* begin
        if (s1_b_grant_m1) begin
            s1_axi_bid    = m1_axi_bid;
            s1_axi_bresp  = m1_axi_bresp;
            s1_axi_bvalid = 1'b1;
        end else if (m0_axi_bvalid && m0_is_s1_b) begin
            s1_axi_bid    = m0_axi_bid;
            s1_axi_bresp  = m0_axi_bresp;
            s1_axi_bvalid = 1'b1;
        end else begin
            s1_axi_bid    = '0;
            s1_axi_bresp  = 2'b00;
            s1_axi_bvalid = 1'b0;
        end
    end

    assign m0_axi_brdy = m0_is_s1_b ? (s1_axi_brdy && !s1_b_grant_m1) : (s0_axi_brdy && !s0_b_grant_m1);
    assign m1_axi_brdy = m1_is_s1_b ? (s1_axi_brdy && s1_b_grant_m1)  : (s0_axi_brdy && s0_b_grant_m1);

    // ========================================================================
    // 5. Inter-Stack Peer-to-Peer 2-Stage Register Slice (HATA 47)
    // ========================================================================
    // Path: Stack 0 TX -> Interposer (5mm) -> Stack 1 RX
    logic [DATA_W-1:0] p2p_0to1_stage1_data, p2p_0to1_stage2_data;
    logic              p2p_0to1_stage1_vld,  p2p_0to1_stage2_vld;

    always_ff @(posedge clk_hbm or negedge rst_hbm_n) begin
        if (!rst_hbm_n) begin
            p2p_0to1_stage1_vld  <= 1'b0;
            p2p_0to1_stage1_data <= '0;
            p2p_0to1_stage2_vld  <= 1'b0;
            p2p_0to1_stage2_data <= '0;
        end else begin
            // Stage 1
            if (p2p_s0_tx_valid && p2p_s0_tx_ready) begin
                p2p_0to1_stage1_vld  <= 1'b1;
                p2p_0to1_stage1_data <= p2p_s0_tx_data;
            end else if (!p2p_0to1_stage2_vld || p2p_s1_rx_ready) begin
                p2p_0to1_stage1_vld  <= 1'b0;
            end

            // Stage 2
            if (p2p_0to1_stage1_vld && (!p2p_0to1_stage2_vld || p2p_s1_rx_ready)) begin
                p2p_0to1_stage2_vld  <= 1'b1;
                p2p_0to1_stage2_data <= p2p_0to1_stage1_data;
            end else if (p2p_s1_rx_ready) begin
                p2p_0to1_stage2_vld  <= 1'b0;
            end
        end
    end

    assign p2p_s0_tx_ready = !p2p_0to1_stage1_vld || !p2p_0to1_stage2_vld || p2p_s1_rx_ready;
    assign p2p_s1_rx_valid = p2p_0to1_stage2_vld;
    assign p2p_s1_rx_data  = p2p_0to1_stage2_data;

    // Path: Stack 1 TX -> Interposer (5mm) -> Stack 0 RX
    logic [DATA_W-1:0] p2p_1to0_stage1_data, p2p_1to0_stage2_data;
    logic              p2p_1to0_stage1_vld,  p2p_1to0_stage2_vld;

    always_ff @(posedge clk_hbm or negedge rst_hbm_n) begin
        if (!rst_hbm_n) begin
            p2p_1to0_stage1_vld  <= 1'b0;
            p2p_1to0_stage1_data <= '0;
            p2p_1to0_stage2_vld  <= 1'b0;
            p2p_1to0_stage2_data <= '0;
        end else begin
            // Stage 1
            if (p2p_s1_tx_valid && p2p_s1_tx_ready) begin
                p2p_1to0_stage1_vld  <= 1'b1;
                p2p_1to0_stage1_data <= p2p_s1_tx_data;
            end else if (!p2p_1to0_stage2_vld || p2p_s0_rx_ready) begin
                p2p_1to0_stage1_vld  <= 1'b0;
            end

            // Stage 2
            if (p2p_1to0_stage1_vld && (!p2p_1to0_stage2_vld || p2p_s0_rx_ready)) begin
                p2p_1to0_stage2_vld  <= 1'b1;
                p2p_1to0_stage2_data <= p2p_1to0_stage1_data;
            end else if (p2p_s0_rx_ready) begin
                p2p_1to0_stage2_vld  <= 1'b0;
            end
        end
    end

    assign p2p_s1_tx_ready = !p2p_1to0_stage1_vld || !p2p_1to0_stage2_vld || p2p_s0_rx_ready;
    assign p2p_s0_rx_valid = p2p_1to0_stage2_vld;
    assign p2p_s0_rx_data  = p2p_1to0_stage2_data;

    // Fast Barrier Lines across interposer (Register-isolated, HATA 73)
    always_ff @(posedge clk_hbm or negedge rst_hbm_n) begin
        if (!rst_hbm_n) begin
            stack0_barrier_out <= 1'b0;
            stack1_barrier_out <= 1'b0;
        end else begin
            stack0_barrier_out <= stack1_barrier_in;
            stack1_barrier_out <= stack0_barrier_in;
        end
    end

`ifdef FORMAL
    // Reset assumption
    logic [2:0] f_rst_cnt = 0;
    always @(posedge clk_hbm) begin
        if (f_rst_cnt < 3'd2) f_rst_cnt <= f_rst_cnt + 1'b1;
    end
    always_comb begin
        if (f_rst_cnt < 3'd2) assume (!rst_hbm_n);
        else assume (rst_hbm_n);
    end

    // Safety Invariant 1: Inter-Stack Barrier Register Delay
    always @(posedge clk_hbm) begin
        if (rst_hbm_n && f_rst_cnt >= 3'd2 && $past(rst_hbm_n)) begin
            assert (stack0_barrier_out == $past(stack1_barrier_in));
            assert (stack1_barrier_out == $past(stack0_barrier_in));
        end
    end

    // Safety Invariant 2: Address Boundary Partitioning
    // M0 target must strictly have address < 0x5_0000_0000
    // M1 target must strictly have address >= 0x5_0000_0000
    always @(posedge clk_hbm) begin
        if (rst_hbm_n && ar_m0_r1.valid) begin
            assert (ar_m0_r1.addr < 64'h0000_0005_0000_0000);
        end
        if (rst_hbm_n && ar_m0_r2.valid) begin
            assert (ar_m0_r2.addr < 64'h0000_0005_0000_0000);
        end
        if (rst_hbm_n && ar_m1_r1.valid) begin
            assert (ar_m1_r1.addr >= 64'h0000_0005_0000_0000);
        end
        if (rst_hbm_n && ar_m1_r2.valid) begin
            assert (ar_m1_r2.addr >= 64'h0000_0005_0000_0000);
        end
    end

    // Safety Invariant 3: P2P Stream Egress Backpressure Stability
    // When both slice stages are full and downstream RX is not ready, TX ready must be deasserted
    always_comb begin
        if (p2p_0to1_stage1_vld && p2p_0to1_stage2_vld && !p2p_s1_rx_ready) begin
            assert (!p2p_s0_tx_ready);
        end
        if (p2p_1to0_stage1_vld && p2p_1to0_stage2_vld && !p2p_s0_rx_ready) begin
            assert (!p2p_s1_tx_ready);
        end
    end

    // Safety Invariant 4: Response Demux Routing Fidelity
    // M0 Read Response targeting Host (RID 4'hE) must never leak into PIM (s1)
    always_comb begin
        if (m0_axi_rvalid && m0_axi_rid == 4'hE) begin
            assert (!s1_axi_rvalid || (s1_axi_rvalid && s1_axi_rid != 4'hE));
        end
    end
`endif

endmodule
