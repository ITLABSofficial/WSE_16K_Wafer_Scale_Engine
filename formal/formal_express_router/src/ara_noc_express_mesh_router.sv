// ============================================================================
// File: ara_noc_express_mesh_router.sv
// Project: Ara_16384Core_WSE_OpenHBM_800G (Wafer-Scale Engine Hierarchical NoC)
// Technology: TSMC 5nm / ASAP7 7nm FinFET Predictive PDK (Target: 1.5 - 2.0 GHz)
// Specification: MIMARI_PLAN_WSE_16384CORE.md (Section 8.5 & HATA 129)
//
// Description:
//   Hierarchical 9-Port 2D-Mesh NoC Router with 8-Hop Express Skip Links:
//   - Ports 0..4 (Local Grid): 0=North, 1=East, 2=South, 3=West, 4=Local NI
//   - Ports 5..8 (Express Highway):
//       5 = Express North (Y - 8)
//       6 = Express East  (X + 8)
//       7 = Express South (Y + 8)
//       8 = Express West  (X - 8)
//
//   Key Features:
//   1. Dimension-Order Express Routing (DOR-Express):
//      - If |Dest_X - Curr_X| >= 8: Route to Express East/West (1-hop covers 8 tiles!).
//      - If |Dest_X - Curr_X| < 8 : Route to Local East/West.
//      - When Dest_X == Curr_X    : Turn to Y dimension (Express North/South or Local).
//      - Eliminates 254-hop network diameter bottleneck; collapses diameter to < 30 hops!
//   2. Provably Deadlock-Free DAG:
//      - Strict X-then-Y hierarchy preserved. No 180-degree U-turns.
//   3. Dual Virtual Channels (VC0=Request, VC1=Response):
//      - Dedicated queues prevent cross-protocol buffer saturation.
//   4. Decoupled Skid Buffering & Zero Combinational Loop Handshake (HATA 46, HATA 99).
// ============================================================================

`timescale 1ps/1fs

module ara_noc_express_mesh_router #(
    parameter int unsigned ROUTER_X      = 0,
    parameter int unsigned ROUTER_Y      = 0,
    parameter int unsigned FLIT_W        = 544,
    parameter int unsigned NUM_PORTS     = 9,      // 5 Local + 4 Express
    parameter int unsigned NUM_VCS       = 2,
    parameter int unsigned FIFO_DEPTH    = 4,
    parameter int unsigned EXPRESS_STEP  = 8       // Number of tiles skipped by express link
)(
    input  logic                                 clk,
    input  logic                                 rst_n,

    // Ingress Ports (9 Ports x 544b Flit, 1-bit Valid, 2-bit Ready [VC1, VC0])
    input  logic [NUM_PORTS-1:0][FLIT_W-1:0]     in_flit_i,
    input  logic [NUM_PORTS-1:0]                 in_valid_i,
    output logic [NUM_PORTS-1:0][NUM_VCS-1:0]    in_ready_o,

    // Egress Ports (9 Ports x 544b Flit, 1-bit Valid, 2-bit Ready [VC1, VC0])
    output logic [NUM_PORTS-1:0][FLIT_W-1:0]     out_flit_o,
    output logic [NUM_PORTS-1:0]                 out_valid_o,
    input  logic [NUM_PORTS-1:0][NUM_VCS-1:0]    out_ready_i,

    // Telemetry Statistics
    output logic [31:0]                          express_hops_cnt_o,
    output logic [31:0]                          local_hops_cnt_o
);

    // Port Index Constants
    localparam int unsigned PORT_NORTH   = 0;
    localparam int unsigned PORT_EAST    = 1;
    localparam int unsigned PORT_SOUTH   = 2;
    localparam int unsigned PORT_WEST    = 3;
    localparam int unsigned PORT_LOCAL   = 4;
    localparam int unsigned PORT_EXP_N   = 5;
    localparam int unsigned PORT_EXP_E   = 6;
    localparam int unsigned PORT_EXP_S   = 7;
    localparam int unsigned PORT_EXP_W   = 8;

    // Flit Type Constants
    localparam logic [1:0] FLIT_HEAD   = 2'b00;
    localparam logic [1:0] FLIT_BODY   = 2'b01;
    localparam logic [1:0] FLIT_TAIL   = 2'b10;
    localparam logic [1:0] FLIT_SINGLE = 2'b11;

    // ------------------------------------------------------------------------
    // 1. Ingress Synchronous FIFOs per Port and VC
    // ------------------------------------------------------------------------
    logic [FLIT_W-1:0] hol_flit        [NUM_PORTS-1:0][NUM_VCS-1:0];
    logic              hol_valid       [NUM_PORTS-1:0][NUM_VCS-1:0];
    logic              hol_pop         [NUM_PORTS-1:0][NUM_VCS-1:0];

    genvar p, v;
    generate
        for (p = 0; p < NUM_PORTS; p++) begin : gen_ingress_ports
            for (v = 0; v < NUM_VCS; v++) begin : gen_ingress_vcs
                wire vc_match   = (in_flit_i[p][526] == v[0]);
                wire push_valid = in_valid_i[p] && vc_match;

                ara_noc_fifo #(
                    .DATA_W(FLIT_W),
                    .DEPTH (FIFO_DEPTH)
                ) u_ingress_fifo (
                    .clk         (clk),
                    .rst_n       (rst_n),
                    .push_data_i (in_flit_i[p]),
                    .push_valid_i(push_valid),
                    .push_ready_o(in_ready_o[p][v]),
                    .pop_data_o  (hol_flit[p][v]),
                    .pop_valid_o (hol_valid[p][v]),
                    .pop_ready_i (hol_pop[p][v])
                );
            end
        end
    endgenerate

    // ------------------------------------------------------------------------
    // 2. Hierarchical Routing Computation (DOR with Express Skip Links)
    // ------------------------------------------------------------------------
    logic [3:0] hol_target_port [NUM_PORTS-1:0][NUM_VCS-1:0];

    generate
        for (p = 0; p < NUM_PORTS; p++) begin : gen_routing_p
            for (v = 0; v < NUM_VCS; v++) begin : gen_routing_v
                wire [5:0] dest_x = hol_flit[p][v][541:536];
                wire [5:0] dest_y = hol_flit[p][v][535:530];

                assign hol_target_port[p][v] =
                    (dest_x > ROUTER_X[5:0]) ?
                        (((dest_x - ROUTER_X[5:0]) >= EXPRESS_STEP[5:0]) ? PORT_EXP_E[3:0] : PORT_EAST[3:0]) :
                    (dest_x < ROUTER_X[5:0]) ?
                        (((ROUTER_X[5:0] - dest_x) >= EXPRESS_STEP[5:0]) ? PORT_EXP_W[3:0] : PORT_WEST[3:0]) :
                    (dest_y > ROUTER_Y[5:0]) ?
                        (((dest_y - ROUTER_Y[5:0]) >= EXPRESS_STEP[5:0]) ? PORT_EXP_S[3:0] : PORT_SOUTH[3:0]) :
                    (dest_y < ROUTER_Y[5:0]) ?
                        (((ROUTER_Y[5:0] - dest_y) >= EXPRESS_STEP[5:0]) ? PORT_EXP_N[3:0] : PORT_NORTH[3:0]) :
                        PORT_LOCAL[3:0];
            end
        end
    endgenerate

    // ------------------------------------------------------------------------
    // 3. Round-Robin Switch Allocation & Crossbar Forwarding
    // ------------------------------------------------------------------------
    logic [NUM_PORTS-1:0]       req_matrix    [NUM_PORTS-1:0]; // [out_port][in_port]
    logic [NUM_PORTS-1:0]       grant_matrix  [NUM_PORTS-1:0];
    logic [NUM_PORTS-1:0]       selected_vc   [NUM_PORTS-1:0]; // 0=VC0, 1=VC1
    logic [3:0]                 prio_ptr      [NUM_PORTS-1:0];

    // Wormhole Lock Registers
    logic                       locked        [NUM_PORTS-1:0];
    logic [3:0]                 locked_port   [NUM_PORTS-1:0];
    logic                       locked_vc     [NUM_PORTS-1:0];

    // Build Request Matrix (VC1 High Priority QoS) via generate to avoid Icarus constant-select warnings
    genvar g_op, g_ip;
    generate
        for (g_op = 0; g_op < NUM_PORTS; g_op++) begin : gen_req_op
            for (g_ip = 0; g_ip < NUM_PORTS; g_ip++) begin : gen_req_ip
                wire vc1_match = hol_valid[g_ip][1] && (hol_target_port[g_ip][1] == g_op[3:0]);
                wire vc0_match = hol_valid[g_ip][0] && (hol_target_port[g_ip][0] == g_op[3:0]);
                assign req_matrix[g_op][g_ip]  = vc1_match || vc0_match;
                assign selected_vc[g_op][g_ip] = vc1_match ? 1'b1 : 1'b0;
            end
        end
    endgenerate

    // Round-Robin Arbitration per Egress Port
    always_comb begin
        for (int op = 0; op < NUM_PORTS; op++) begin
            grant_matrix[op] = '0;

            if (locked[op]) begin
                // Hold lock for multi-flit wormhole packet
                grant_matrix[op][locked_port[op]] = 1'b1;
            end else begin
                // Strict Round-Robin based on prio_ptr
                for (int i = 0; i < NUM_PORTS; i++) begin
                    int cand_port;
                    cand_port = (prio_ptr[op] + i) % NUM_PORTS;
                    if (req_matrix[op][cand_port] && (grant_matrix[op] == '0)) begin
                        grant_matrix[op][cand_port] = 1'b1;
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------------------
    // 4. Egress Multiplexing & Skid Buffering
    // ------------------------------------------------------------------------
    logic [FLIT_W-1:0] pre_out_flit  [NUM_PORTS-1:0];
    logic              pre_out_valid [NUM_PORTS-1:0];
    logic              pre_out_vc    [NUM_PORTS-1:0];

    always_comb begin
        for (int op = 0; op < NUM_PORTS; op++) begin
            pre_out_flit[op]  = '0;
            pre_out_valid[op] = 1'b0;
            pre_out_vc[op]    = 1'b0;

            for (int ip = 0; ip < NUM_PORTS; ip++) begin
                if (grant_matrix[op][ip]) begin
                    pre_out_vc[op]    = locked[op] ? locked_vc[op] : selected_vc[op][ip];
                    pre_out_flit[op]  = hol_flit[ip][pre_out_vc[op]];
                    pre_out_valid[op] = hol_valid[ip][pre_out_vc[op]];
                end
            end
        end
    end

    // Connect Egress FIFOs to prevent combinational loops
    logic [NUM_PORTS-1:0] egress_push_ready;

    generate
        for (p = 0; p < NUM_PORTS; p++) begin : gen_egress_fifos
            ara_noc_fifo #(
                .DATA_W(FLIT_W),
                .DEPTH (FIFO_DEPTH)
            ) u_egress_fifo (
                .clk         (clk),
                .rst_n       (rst_n),
                .push_data_i (pre_out_flit[p]),
                .push_valid_i(pre_out_valid[p] && egress_push_ready[p]),
                .push_ready_o(egress_push_ready[p]),
                .pop_data_o  (out_flit_o[p]),
                .pop_valid_o (out_valid_o[p]),
                .pop_ready_i (out_ready_i[p][out_flit_o[p][526]])
            );

            for (v = 0; v < NUM_VCS; v++) begin : gen_hol_pop_vc
                logic [NUM_PORTS-1:0] op_pop_match;
                for (g_op = 0; g_op < NUM_PORTS; g_op++) begin : gen_op_pop
                    assign op_pop_match[g_op] = grant_matrix[g_op][p] && egress_push_ready[g_op] && (pre_out_vc[g_op] == v[0]);
                end
                assign hol_pop[p][v] = |op_pop_match;
            end
        end
    endgenerate

    // ------------------------------------------------------------------------
    // 5. Sequential State: Wormhole Lock, Pointers & Telemetry
    // ------------------------------------------------------------------------
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (int op = 0; op < NUM_PORTS; op++) begin
                prio_ptr[op]    <= '0;
                locked[op]      <= 1'b0;
                locked_port[op] <= '0;
                locked_vc[op]   <= 1'b0;
            end
            express_hops_cnt_o  <= '0;
            local_hops_cnt_o    <= '0;
        end else begin
            for (int op = 0; op < NUM_PORTS; op++) begin
                if (pre_out_valid[op] && egress_push_ready[op]) begin
                    logic [1:0] cur_type;
                    cur_type = pre_out_flit[op][543:542];

                    if (cur_type == FLIT_HEAD) begin
                        locked[op]      <= 1'b1;
                        for (int ip = 0; ip < NUM_PORTS; ip++) begin
                            if (grant_matrix[op][ip]) begin
                                locked_port[op] <= ip[3:0];
                                locked_vc[op]   <= pre_out_vc[op];
                            end
                        end
                    end else if (cur_type == FLIT_TAIL || cur_type == FLIT_SINGLE) begin
                        locked[op] <= 1'b0;
                        prio_ptr[op] <= (prio_ptr[op] + 1) % NUM_PORTS;
                    end

                    // Telemetry Counting
                    if (op >= PORT_EXP_N && op <= PORT_EXP_W)
                        express_hops_cnt_o <= express_hops_cnt_o + 1;
                    else if (op >= PORT_NORTH && op <= PORT_WEST)
                        local_hops_cnt_o <= local_hops_cnt_o + 1;
                end
            end
        end
    end

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

    // Safety Invariant 1: Mutual Exclusion of Egress Grants (At most 1 grant per output port)
    always_comb begin
        for (int op = 0; op < NUM_PORTS; op++) begin
            assert ($onehot0(grant_matrix[op]));
        end
    end

    // Safety Invariant 2: DOR-Express Skip Distance Invariant
    always_comb begin
        for (int p_idx = 0; p_idx < NUM_PORTS; p_idx++) begin
            for (int v_idx = 0; v_idx < NUM_VCS; v_idx++) begin
                if (hol_target_port[p_idx][v_idx] == PORT_EXP_E) begin
                    assert (hol_flit[p_idx][v_idx][541:536] >= (ROUTER_X[5:0] + EXPRESS_STEP[5:0]));
                end
                if (hol_target_port[p_idx][v_idx] == PORT_EXP_W) begin
                    assert (ROUTER_X[5:0] >= (hol_flit[p_idx][v_idx][541:536] + EXPRESS_STEP[5:0]));
                end
                if (hol_target_port[p_idx][v_idx] == PORT_EXP_S) begin
                    assert (hol_flit[p_idx][v_idx][535:530] >= (ROUTER_Y[5:0] + EXPRESS_STEP[5:0]));
                end
                if (hol_target_port[p_idx][v_idx] == PORT_EXP_N) begin
                    assert (ROUTER_Y[5:0] >= (hol_flit[p_idx][v_idx][535:530] + EXPRESS_STEP[5:0]));
                end
                if (hol_target_port[p_idx][v_idx] == PORT_LOCAL) begin
                    assert (hol_flit[p_idx][v_idx][541:536] == ROUTER_X[5:0] &&
                            hol_flit[p_idx][v_idx][535:530] == ROUTER_Y[5:0]);
                end
            end
        end
    end

    // Safety Invariant 3: Wormhole Lock Fidelity
    // When locked, grant must strictly be given to the locked port
    always_comb begin
        for (int op = 0; op < NUM_PORTS; op++) begin
            if (rst_n && locked[op]) begin
                assert (grant_matrix[op][locked_port[op]] == 1'b1);
            end
        end
    end
`endif

endmodule
