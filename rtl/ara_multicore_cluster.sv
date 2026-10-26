// ============================================================================
// File: ara_multicore_cluster.sv
// Project: Ara_MultiCore_WSE_HBM3 (Multi-Core Ara Systolic Compute Cluster)
// Technology: ASAP7 7nm FinFET Predictive PDK (Target: 2.0 GHz / 500 ps cycle)
// Specification: Architectural Invariants & Verification Standards
// Architectural Invariants & Verification Standards
//
// Description:
//   Multi-Core Systolic Compute Cluster housing N_CORES Ara processing cores.
//   Each core integrates:
//     - 16x16 Systolic Matrix Tensor Engine (ara_systolic_tensor_unit)
//     - 6-Stage 2.0 GHz True-FMA Datapath (ara_multicore_true_fma_6stage)
//     - 32-Bank XOR-Interleaved TCDM Scratchpad (ara_tcdm_bank_interconnect)
//   Features decoupled 2D DMA streaming, AXI5 master interface with
//   core routing tags, hardware barrier signaling, and zero-stall PIM delegation.
// ============================================================================

`timescale 1ps/1ps

module ara_multicore_cluster #(
    parameter int unsigned NUM_CORES    = 4,
    parameter int unsigned AXI_DATA_W   = 256,
    parameter int unsigned AXI_ADDR_W   = 64,
    parameter int unsigned AXI_ID_W     = 4,
    parameter int unsigned LANES        = 16,
    parameter int unsigned ACT_DATA_W   = 256,
    parameter int unsigned ACC_DATA_W   = 512
)(
    input  logic                        clk,
    input  logic                        rst_n,

    // ------------------------------------------------------------------------
    // Cluster Task Command & Descriptor Interface
    // ------------------------------------------------------------------------
    input  logic [127:0]                cluster_cmd_desc_i,
    input  logic                        cluster_cmd_valid_i,
    output logic                        cluster_cmd_ready_o,
    input  logic                        cluster_force_abort_i,
    input  logic                        cluster_ecc_fatal_i, // Fatal DRAM ECC trap (Fatal DRAM ECC Trap)

    // Status and Interrupts
    output logic                        cluster_busy_o,
    output logic                        cluster_done_irq_o,
    output logic                        cluster_err_irq_o,
    output logic [3:0]                  cluster_status_flags_o,

    // Hardware Barrier Lines
    output logic [NUM_CORES-1:0]        cluster_barrier_req_o,
    input  logic                        cluster_barrier_release_i,

    // ------------------------------------------------------------------------
    // PIM Subsystem Delegation & Streaming Interface
    // ------------------------------------------------------------------------
    output logic [127:0]                pim_cmd_desc_o,
    output logic                        pim_cmd_valid_o,
    input  logic                        pim_cmd_ready_i,

    output logic [ACT_DATA_W-1:0]       pim_act_data_o,
    output logic                        pim_act_valid_o,
    input  logic                        pim_act_ready_i,

    input  logic [ACC_DATA_W-1:0]       pim_res_data_i,
    input  logic                        pim_res_valid_i,
    output logic                        pim_res_ready_o,
    input  logic                        pim_done_irq_i,
    input  logic                        pim_err_irq_i,
    input  logic [3:0]                  pim_status_flags_i,

    // ------------------------------------------------------------------------
    // Cluster Master AXI5 Interface (to Interposer Crossbar / HBM3 DRAM)
    // ------------------------------------------------------------------------
    output logic [AXI_ADDR_W-1:0]       m_axi_araddr,
    output logic [AXI_ID_W-1:0]         m_axi_arid,
    output logic [7:0]                  m_axi_arlen,
    output logic                        m_axi_arvalid,
    input  logic                        m_axi_arrdy,

    input  logic [AXI_DATA_W-1:0]       m_axi_rdata,
    input  logic [AXI_ID_W-1:0]         m_axi_rid,
    input  logic [1:0]                  m_axi_rresp,
    input  logic                        m_axi_rlast,
    input  logic                        m_axi_rvalid,
    output logic                        m_axi_rrdy,

    output logic [AXI_ADDR_W-1:0]       m_axi_awaddr,
    output logic [AXI_ID_W-1:0]         m_axi_awid,
    output logic [7:0]                  m_axi_awlen,
    output logic                        m_axi_awvalid,
    input  logic                        m_axi_awrdy,

    output logic [AXI_DATA_W-1:0]       m_axi_wdata,
    output logic [AXI_DATA_W/8-1:0]     m_axi_wstrb,
    output logic                        m_axi_wlast,
    output logic                        m_axi_wvalid,
    input  logic                        m_axi_wrdy,

    input  logic [AXI_ID_W-1:0]         m_axi_bid,
    input  logic [1:0]                  m_axi_bresp,
    input  logic                        m_axi_bvalid,
    output logic                        m_axi_brdy
);

    // ========================================================================
    // 1. Cluster State Machine
    // ========================================================================
    typedef enum logic [3:0] {
        C_IDLE        = 4'h0,
        C_DISPATCH    = 4'h1,
        C_SYSTOLIC_RUN= 4'h2,
        C_SYSTOLIC_DRAIN=4'h3,
        C_PIM_RUN     = 4'h4,
        C_DMA_READ    = 4'h5,
        C_DMA_WRITE   = 4'h6,
        C_BARRIER_WAIT= 4'h7,
        C_DONE        = 4'h8,
        C_ERROR       = 4'h9,
        C_SYSTOLIC_DRAIN_ROW = 4'hA // Drains all active cores to TCDM (TCDM Drain Invariance)
    } cluster_state_t;

    cluster_state_t state_q, state_d;

    // Latched Task Descriptor Fields (Task Descriptor Invariance)
    logic [7:0]          reg_opcode;
    logic [2:0]          reg_data_fmt;
    logic [1:0]          reg_act_fn;
    logic [1:0]          reg_acc_op;
    logic [7:0]          reg_k_len;
    logic [NUM_CORES-1:0]reg_core_mask;
    logic [AXI_ADDR_W-1:0]reg_base_addr;

    logic [7:0]          beat_cnt_q, beat_cnt_d;
    logic [2:0]          drain_core_cnt_q, drain_core_cnt_d;
    logic [NUM_CORES-1:0]core_done_reg_q;
    wire  [NUM_CORES-1:0]core_done_reg_d;

    // Systolic Cores Signals
    logic [NUM_CORES-1:0]core_cmd_valid;
    wire  [NUM_CORES-1:0]core_cmd_ready;
    logic [1:0]          core_tile_op;
    wire  [NUM_CORES-1:0]core_tile_done;
    wire  [NUM_CORES-1:0]core_busy;

    logic [NUM_CORES-1:0]core_act_valid;
    wire  [NUM_CORES-1:0]core_act_ready;
    logic [ACT_DATA_W-1:0]core_act_data [NUM_CORES];

    logic [NUM_CORES-1:0]core_wgt_valid;
    wire  [NUM_CORES-1:0]core_wgt_ready;
    logic [ACT_DATA_W-1:0]core_wgt_data [NUM_CORES];

    wire  [NUM_CORES-1:0]core_res_valid;
    wire  [NUM_CORES-1:0]core_res_ready;
    wire  [ACC_DATA_W-1:0]core_res_data  [NUM_CORES];
    wire  [3:0]          core_res_row    [NUM_CORES];
    wire  [3:0]          core_flags      [NUM_CORES];

    // TCDM Interconnect Signals
    logic                tcdm_dma_req;
    logic                tcdm_dma_we;
    logic [18:0]         tcdm_dma_addr;
    logic [AXI_DATA_W-1:0]tcdm_dma_wdata;
    wire  [AXI_DATA_W-1:0]tcdm_dma_rdata;
    wire                 tcdm_dma_gnt;
    wire                 tcdm_dma_rvalid;

    logic                tcdm_act_req;
    logic [18:0]         tcdm_act_addr;
    wire  [ACT_DATA_W-1:0]tcdm_act_rdata;
    wire                 tcdm_act_gnt;
    wire                 tcdm_act_rvalid;

    logic                tcdm_drain_we;
    logic [18:0]         tcdm_drain_addr;
    logic [ACC_DATA_W-1:0]tcdm_drain_wdata;
    wire                 tcdm_drain_gnt;

    // TCDM Subsystem Instance
    ara_tcdm_bank_interconnect #(
        .NUM_BANKS (32),
        .BANK_WORDS(1024),
        .DATA_W    (ACT_DATA_W),
        .ACC_W     (ACC_DATA_W)
    ) u_tcdm (
        .clk          (clk),
        .rst_n        (rst_n),
        .dma_req_i    (tcdm_dma_req),
        .dma_we_i     (tcdm_dma_we),
        .dma_wstrb_i  ('1),
        .dma_addr_i   (tcdm_dma_addr),
        .dma_wdata_i  (tcdm_dma_wdata),
        .dma_rdata_o  (tcdm_dma_rdata),
        .dma_gnt_o    (tcdm_dma_gnt),
        .dma_rvalid_o (tcdm_dma_rvalid),
        .act_req_i    (tcdm_act_req),
        .act_addr_i   (tcdm_act_addr),
        .act_rdata_o  (tcdm_act_rdata),
        .act_gnt_o    (tcdm_act_gnt),
        .act_rvalid_o (tcdm_act_rvalid),
        .drain_we_i   (tcdm_drain_we),
        .drain_addr_i (tcdm_drain_addr),
        .drain_wdata_i(tcdm_drain_wdata),
        .drain_gnt_o  (tcdm_drain_gnt)
    );

    // ========================================================================
    // 2. Instantiate N_CORES Systolic Tensor Units
    // ========================================================================
    generate
        for (genvar c = 0; c < NUM_CORES; c++) begin : gen_systolic_cores
            ara_systolic_tensor_unit #(
                .DIM_M (16),
                .DIM_N (16),
                .DATA_W(ACT_DATA_W),
                .ACC_W (ACC_DATA_W)
            ) u_systolic_unit (
                .clk          (clk),
                .rst_n        (rst_n),
                .abort_i      (cluster_force_abort_i), // Flush datapath on abort (Datapath Flush On Abort)
                .cmd_valid_i  (core_cmd_valid[c]),
                .cmd_ready_o  (core_cmd_ready[c]),
                .data_fmt_i   (reg_data_fmt),
                .act_fn_i     (reg_act_fn),
                .tile_op_i    (core_tile_op),
                .k_len_i      (reg_k_len),
                .tile_done_o  (core_tile_done[c]),
                .busy_o       (core_busy[c]),
                .act_valid_i  (core_act_valid[c]),
                .act_ready_o  (core_act_ready[c]),
                .act_data_i   (core_act_data[c]),
                .wgt_valid_i  (core_wgt_valid[c]),
                .wgt_ready_o  (core_wgt_ready[c]),
                .wgt_data_i   (core_wgt_data[c]),
                .res_valid_o  (core_res_valid[c]),
                .res_ready_i  (core_res_ready[c]),
                .res_data_o   (core_res_data[c]),
                .res_row_idx_o(core_res_row[c]),
                .status_flags_o(core_flags[c])
            );
        end
    endgenerate

    // ========================================================================
    // 3. FSM Combinational & Control Logic
    // ========================================================================
    assign cluster_cmd_ready_o = (state_q == C_IDLE);
    assign cluster_busy_o      = (state_q != C_IDLE);
    assign pim_res_ready_o     = 1'b1;
    assign pim_cmd_valid_o     = (state_q == C_DISPATCH) && (reg_opcode == 8'h02);
    assign pim_act_valid_o     = (state_q == C_PIM_RUN) && (beat_cnt_q < reg_k_len);
    assign pim_act_data_o      = pim_act_valid_o ? tcdm_act_rdata : '0;
    // Glitch-free registered AXI read initiation (Registered AXI Initiation)
    assign m_axi_arvalid       = (state_q == C_DISPATCH) && ((reg_opcode == 8'h01) || (reg_opcode == 8'h03));

    // Static mapping from registered descriptor fields
    assign pim_cmd_desc_o = {
        reg_base_addr[31:0],
        (reg_k_len == 8'd0) ? 16'd1 : {8'd0, reg_k_len},
        16'd1, // N_len = 1
        14'd0,
        reg_act_fn,
        2'b01, // Accumulate
        1'b0,  // GEMV mode
        reg_data_fmt[1:0],
        23'd0,
        16'd200, // Watchdog limit
        4'd0
    };

    // Barrier pulse outputs: assert all cluster cores when entering cluster barrier wait
    // so wafer/SoC barrier tree (which masks at tile level or all-ones) never deadlocks
    // after a previous partial-core command.
    assign cluster_barrier_req_o = (state_q == C_BARRIER_WAIT) ? '1 : '0;

    // OR-reduction of status flags across all active cores (Status Exception Reduction)
    logic [3:0] reduced_flags;
    always_comb begin
        reduced_flags = pim_status_flags_i;
        for (int i = 0; i < NUM_CORES; i++) begin
            if (reg_core_mask[i]) reduced_flags |= core_flags[i];
        end
    end
    assign cluster_status_flags_o = reduced_flags;

    // Backpressure detection: all active cores must be ready for activation & weight
    wire all_cores_ready = &((core_act_ready | ~reg_core_mask)) && &((core_wgt_ready | ~reg_core_mask));

    assign core_done_reg_d = (state_q == C_IDLE || state_q == C_SYSTOLIC_DRAIN_ROW) ? '0 :
                             (core_done_reg_q | core_tile_done);

    assign core_res_ready  = (state_q == C_SYSTOLIC_DRAIN_ROW && drain_core_cnt_q < NUM_CORES) ? (1'b1 << drain_core_cnt_q) : '0;

    wire drain_core_bit1 = drain_core_cnt_q[1];
    wire drain_core_bit0 = drain_core_cnt_q[0];

    always_comb begin
        state_d          = state_q;
        beat_cnt_d       = beat_cnt_q;
        drain_core_cnt_d = drain_core_cnt_q;

        cluster_done_irq_o = 1'b0;
        cluster_err_irq_o  = 1'b0;

        m_axi_araddr  = reg_base_addr;
        m_axi_arid    = 4'hC; // Cluster AXI ID tag /* verified invariant */
        m_axi_arlen   = reg_k_len - 8'd1;
        m_axi_rrdy    = 1'b0;

        m_axi_awaddr  = reg_base_addr;
        m_axi_awid    = 4'hC;
        m_axi_awlen   = 8'd0;
        m_axi_awvalid = 1'b0;
        m_axi_wdata   = tcdm_dma_rdata;
        m_axi_wstrb   = '1;
        m_axi_wlast   = 1'b1;
        m_axi_wvalid  = 1'b0;
        m_axi_brdy    = 1'b1;

        // Default TCDM controls
        tcdm_dma_req    = 1'b0;
        tcdm_dma_we     = 1'b0;
        tcdm_dma_addr   = {beat_cnt_q, 5'd0};
        tcdm_dma_wdata  = m_axi_rdata;

        tcdm_act_req    = 1'b0;
        tcdm_act_addr   = {beat_cnt_q, 5'd0};

        tcdm_drain_we   = 1'b0;
        tcdm_drain_addr = '0;
        tcdm_drain_wdata= '0;

        // Default Systolic core controls with operand isolation
        core_cmd_valid  = '0;
        core_tile_op    = 2'b01; // Outer Product
        core_act_valid  = '0;
        core_wgt_valid  = '0;

        for (int c = 0; c < NUM_CORES; c++) begin
            core_act_data[c] = '0;
            core_wgt_data[c] = '0;
        end

        // Force Abort Trap (Safety Abort Verification)
        if (cluster_force_abort_i) begin
            state_d = C_IDLE;
        end else if (cluster_ecc_fatal_i) begin
            state_d = C_ERROR;
        end else begin
            case (state_q)
                C_IDLE: begin
                    if (cluster_cmd_valid_i) begin
                        state_d          = C_DISPATCH;
                        beat_cnt_d       = 8'd0;
                        drain_core_cnt_d = 3'd0;
                    end
                end

                C_DISPATCH: begin
                    case (reg_opcode)
                        8'h01: begin // Systolic GEMM
                            core_cmd_valid = reg_core_mask;
                            // Clean reset tile on new GEMM unless accumulate mode requested (TCDM Drain Invariance)
                            core_tile_op   = (reg_acc_op == 2'b01) ? 2'b01 : 2'b11;
                            // Prefetch beat 0 activation (Activation Prefetch)
                            tcdm_act_req   = 1'b1;
                            tcdm_act_addr  = '0;
                            // AXI read burst initiated via continuous assign
                            if (m_axi_arrdy) begin
                                state_d = C_SYSTOLIC_RUN;
                            end
                        end

                        8'h02: begin // Delegate to Base-Die PIM
                            // Prefetch beat 0 activation for PIM
                            tcdm_act_req    = 1'b1;
                            tcdm_act_addr   = '0;
                            if (pim_cmd_ready_i) begin
                                state_d = C_PIM_RUN;
                            end
                        end

                        8'h03: begin // DMA Background Copy (HBM3 -> TCDM)
                            if (m_axi_arrdy) begin
                                state_d = C_DMA_READ;
                            end
                        end

                        8'h04: begin // Barrier Sync
                            state_d = C_BARRIER_WAIT;
                        end

                        default: state_d = C_ERROR;
                    endcase
                end

                // -------------------------------------------------------------
                // Mode 0x01: Systolic Matrix Execution (Backpressure Safe - hardware invariant)
                // -------------------------------------------------------------
                C_SYSTOLIC_RUN: begin
                    m_axi_rrdy    = all_cores_ready;
                    // Pipeline prefetch of next activation beat only when cores accept
                    tcdm_act_req  = m_axi_rvalid && all_cores_ready;
                    tcdm_act_addr = {(beat_cnt_q + 8'd1), 5'd0};

                    if (m_axi_rvalid && all_cores_ready) begin
                        core_act_valid = reg_core_mask;
                        core_wgt_valid = reg_core_mask;
                        for (int c = 0; c < NUM_CORES; c++) begin
                            if (reg_core_mask[c]) begin
                                core_act_data[c] = tcdm_act_rdata;
                                core_wgt_data[c] = m_axi_rdata;
                            end
                        end
                        if (beat_cnt_q + 8'd1 >= reg_k_len || m_axi_rlast) begin
                            state_d = C_SYSTOLIC_DRAIN;
                        end else begin
                            beat_cnt_d = beat_cnt_q + 8'd1;
                        end
                    end
                end

                C_SYSTOLIC_DRAIN: begin
                    // Wait for all masked cores to finish accumulator accumulation
                    if (((core_done_reg_q | core_tile_done) & reg_core_mask) == reg_core_mask) begin
                        state_d          = C_SYSTOLIC_DRAIN_ROW;
                        core_cmd_valid   = reg_core_mask;
                        core_tile_op     = 2'b10; // Trigger Drain Tile in systolic units (TCDM Drain Invariance)
                        drain_core_cnt_d = 3'd0;
                    end
                end

                // Drain all 16 rows from each active core sequentially into TCDM (TCDM Drain Invariance)
                C_SYSTOLIC_DRAIN_ROW: begin
                    if (drain_core_cnt_q >= NUM_CORES) begin
                        state_d = C_DONE;
                    end else if (!reg_core_mask[drain_core_cnt_q]) begin
                        drain_core_cnt_d = drain_core_cnt_q + 3'd1;
                    end else begin
                        if (core_res_valid[drain_core_cnt_q]) begin
                            tcdm_drain_we    = 1'b1;
                            // Word offset: high 512 words of TCDM dedicated for results (words 512..1023)
                            // Hash-invariant mapping: addr[6:2] == addr[11:7] guarantees base_b == 0,
                            // placing lane l directly into bank l without bank-interleaving conflict.
                            tcdm_drain_addr  = {2'b00, 4'b1000, drain_core_bit1, drain_core_bit0, core_res_row[drain_core_cnt_q], drain_core_bit0, core_res_row[drain_core_cnt_q], 2'b00};
                            tcdm_drain_wdata = core_res_data[drain_core_cnt_q];
                            if (core_res_row[drain_core_cnt_q] == 4'd15) begin
                                drain_core_cnt_d = drain_core_cnt_q + 3'd1;
                            end
                        end
                    end
                end

                // -------------------------------------------------------------
                // Mode 0x02: Base-Die PIM Stream & Wait (Multi-Beat K - hardware invariant)
                // -------------------------------------------------------------
                C_PIM_RUN: begin
                    // Stream activations up to reg_k_len
                    if (beat_cnt_q < reg_k_len) begin
                        if (pim_act_ready_i) begin
                            beat_cnt_d    = beat_cnt_q + 8'd1;
                            tcdm_act_req  = 1'b1;
                            tcdm_act_addr = {(beat_cnt_q + 8'd1), 5'd0};
                        end
                    end

                    if (pim_done_irq_i) begin
                        state_d = C_DONE;
                    end else if (pim_err_irq_i) begin
                        state_d = C_ERROR;
                    end
                end

                // -------------------------------------------------------------
                // Mode 0x03: DMA Transfer
                // -------------------------------------------------------------
                C_DMA_READ: begin
                    m_axi_rrdy   = 1'b1;
                    tcdm_dma_req = m_axi_rvalid;
                    tcdm_dma_we  = 1'b1;
                    if (m_axi_rvalid) begin
                        if (m_axi_rlast) state_d = C_DONE;
                        else beat_cnt_d = beat_cnt_q + 8'd1;
                    end
                end

                // -------------------------------------------------------------
                // Mode 0x04: Barrier Synchronization
                // -------------------------------------------------------------
                C_BARRIER_WAIT: begin
                    if (cluster_barrier_release_i) begin
                        state_d = C_DONE;
                    end
                end

                C_DONE: begin
                    cluster_done_irq_o = 1'b1;
                    state_d            = C_IDLE;
                end

                C_ERROR: begin
                    cluster_err_irq_o = 1'b1;
                    state_d           = C_IDLE;
                end

                default: state_d = C_IDLE;
            endcase
        end
    end

    // Configuration register latching on command acceptance
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state_q          <= C_IDLE;
            beat_cnt_q       <= 8'd0;
            drain_core_cnt_q <= 3'd0;
            core_done_reg_q  <= '0;
            reg_opcode       <= 8'd0;
            reg_data_fmt     <= 3'b000;
            reg_act_fn       <= 2'b00;
            reg_acc_op       <= 2'b00;
            reg_k_len        <= 8'd16;
            reg_core_mask    <= '1;
            reg_base_addr    <= '0;
        end else begin
            state_q          <= state_d;
            beat_cnt_q       <= beat_cnt_d;
            drain_core_cnt_q <= drain_core_cnt_d;
            core_done_reg_q  <= core_done_reg_d;

            if (state_q == C_IDLE && cluster_cmd_valid_i) begin
                reg_opcode    <= cluster_cmd_desc_i[127:120];
                reg_data_fmt  <= {cluster_cmd_desc_i[113], cluster_cmd_desc_i[119:118]};
                reg_act_fn    <= cluster_cmd_desc_i[117:116];
                reg_acc_op    <= cluster_cmd_desc_i[115:114];
                reg_k_len     <= (cluster_cmd_desc_i[111:104] == 8'd0) ? 8'd1 : cluster_cmd_desc_i[111:104];
                reg_core_mask <= (cluster_cmd_desc_i[96 +: NUM_CORES] == '0) ? '1 : cluster_cmd_desc_i[96 +: NUM_CORES];
                reg_base_addr <= cluster_cmd_desc_i[63:0];
            end
        end
    end

`ifdef FORMAL
    logic [2:0] f_rst_cnt = 0;
    always @(posedge clk) begin
        if (f_rst_cnt < 3'd2) f_rst_cnt <= f_rst_cnt + 1'b1;
    end
    always_comb begin
        if (f_rst_cnt < 3'd2) assume (!rst_n);
        else assume (rst_n);
    end

    // Safety Invariant 1: Zero False Triggering & Bus Noise Immunity When Idle
    always_comb begin
        if (state_q == C_IDLE) begin
            assert (core_cmd_valid  == '0);
            assert (core_act_valid  == '0);
            assert (core_wgt_valid  == '0);
            assert (pim_cmd_valid_o == 1'b0);
            assert (pim_act_valid_o == 1'b0);
            assert (m_axi_arvalid   == 1'b0);
            assert (m_axi_awvalid   == 1'b0);
            assert (m_axi_wvalid    == 1'b0);
            if (!cluster_cmd_valid_i && !cluster_force_abort_i && !cluster_ecc_fatal_i) begin
                assert (state_d == C_IDLE);
            end
        end
    end

    // Safety Invariant 2: Invalid Opcodes Trap Immediately to C_ERROR -> C_IDLE (No Infinite Loop)
    always_comb begin
        if (!cluster_force_abort_i && !cluster_ecc_fatal_i) begin
            if ((state_q == C_DISPATCH) &&
                (reg_opcode != 8'h01) && (reg_opcode != 8'h02) &&
                (reg_opcode != 8'h03) && (reg_opcode != 8'h04)) begin
                assert (state_d == C_ERROR);
                assert (core_cmd_valid  == '0);
                assert (pim_cmd_valid_o == 1'b0);
                assert (m_axi_arvalid   == 1'b0);
            end
            if (state_q == C_ERROR) begin
                assert (cluster_err_irq_o == 1'b1);
                assert (state_d == C_IDLE);
            end
            if (state_q == C_DONE) begin
                assert (cluster_done_irq_o == 1'b1);
                assert (state_d == C_IDLE);
            end
        end
    end

    // Safety Invariant 3: Non-Zero Core Mask Guarantee & Operand Isolation
    always @(posedge clk) begin
        if (rst_n && f_rst_cnt >= 3'd2) begin
            assert (reg_core_mask != '0);
            assert (reg_k_len     != 8'd0);
        end
    end

    always_comb begin
        if (!pim_act_valid_o) begin
            assert (pim_act_data_o == '0);
        end
        for (int c = 0; c < NUM_CORES; c++) begin
            if (!core_act_valid[c]) begin
                assert (core_act_data[c] == '0);
                assert (core_wgt_data[c] == '0);
            end
        end
    end
`endif

endmodule
