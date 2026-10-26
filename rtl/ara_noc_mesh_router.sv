// ============================================================================
// File: ara_noc_mesh_router.sv
// Project: Ara_MultiCore_WSE_HBM3 (Phase 1: NoC Mesh Fabric - Step 1)
// Technology: ASAP7 7nm FinFET Predictive PDK (Target: 2.0 GHz / 500 ps cycle)
// Specification: Architectural Invariants & Verification Standards
// Architectural Invariants & Verification Standards
//
// Description:
//   High-Performance 5-Port 2D-Mesh NoC Router for Wafer-Scale Supercomputing:
//   - 5 Bidirectional Ports: 0=North, 1=East, 2=South, 3=West, 4=Local
//   - 544-bit Flit Width:
//       [543:542] : Flit Type (00=HEAD, 01=BODY, 10=TAIL, 11=SINGLE)
//       [541:536] : Destination X (6-bit, supports up to 64x64 mesh)
//       [535:530] : Destination Y (6-bit, supports up to 64x64 mesh)
//       [529:526] : Virtual Channel / QoS (4-bit: 0=VC0 Request, 1=VC1 Response)
//       [525:512] : Transaction ID / Tag (14-bit)
//       [511:0]   : 512-bit Pure Data Payload
//   - Dimension-Order X-Y Routing (DOR X-Y): Provably Deadlock-Free DAG
//   - Dual Virtual Channels (VC0=Req, VC1=Rsp): Protocol Deadlock Immunity
//   - Dedicated Modular Synchronous FIFOs for Ingress and Egress Stages
//   - Wormhole Packet Locking (Atomic multi-flit transfer without interleaving)
//   - Mathematically Pure Round-Robin Arbiter (Double-Request Shift Architecture)
// ============================================================================

`timescale 1ps/1ps

module ara_noc_mesh_router #(
    parameter int unsigned ROUTER_X     = 0,
    parameter int unsigned ROUTER_Y     = 0,
    parameter int unsigned FLIT_W       = 544,
    parameter int unsigned NUM_PORTS    = 5,
    parameter int unsigned NUM_VCS      = 2,
    parameter int unsigned FIFO_DEPTH   = 4
)(
    input  logic                                 clk,
    input  logic                                 rst_n,

    // Ingress Ports (5 Ports x 544b Flit, 1-bit Valid, 2-bit Ready [VC1, VC0])
    input  logic [NUM_PORTS-1:0][FLIT_W-1:0]     in_flit_i,
    input  logic [NUM_PORTS-1:0]                 in_valid_i,
    output logic [NUM_PORTS-1:0][NUM_VCS-1:0]    in_ready_o,

    // Egress Ports (5 Ports x 544b Flit, 1-bit Valid, 2-bit Ready [VC1, VC0])
    output logic [NUM_PORTS-1:0][FLIT_W-1:0]     out_flit_o,
    output logic [NUM_PORTS-1:0]                 out_valid_o,
    input  logic [NUM_PORTS-1:0][NUM_VCS-1:0]    out_ready_i
);

    // Port Index Constants
    localparam int unsigned PORT_NORTH = 0;
    localparam int unsigned PORT_EAST  = 1;
    localparam int unsigned PORT_SOUTH = 2;
    localparam int unsigned PORT_WEST  = 3;
    localparam int unsigned PORT_LOCAL = 4;

    // Flit Type Constants
    localparam logic [1:0] FLIT_HEAD   = 2'b00;
    localparam logic [1:0] FLIT_BODY   = 2'b01;
    localparam logic [1:0] FLIT_TAIL   = 2'b10;
    localparam logic [1:0] FLIT_SINGLE = 2'b11;

    // ------------------------------------------------------------------------
    // 1. Ingress Synchronous FIFOs (Modular Instantiation)
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
    // 2. Routing Computation (Dimension-Order X-Y)
    // ------------------------------------------------------------------------
    logic [2:0] hol_target_port [NUM_PORTS-1:0][NUM_VCS-1:0];

    generate
        for (p = 0; p < NUM_PORTS; p++) begin : gen_routing_p
            for (v = 0; v < NUM_VCS; v++) begin : gen_routing_v
                wire [5:0] dest_x = hol_flit[p][v][541:536];
                wire [5:0] dest_y = hol_flit[p][v][535:530];

                always_comb begin
                    if (dest_x > ROUTER_X[5:0]) begin
                        hol_target_port[p][v] = PORT_EAST[2:0];
                    end else if (dest_x < ROUTER_X[5:0]) begin
                        hol_target_port[p][v] = PORT_WEST[2:0];
                    end else begin
                        if (dest_y < ROUTER_Y[5:0]) begin
                            hol_target_port[p][v] = PORT_NORTH[2:0];
                        end else if (dest_y > ROUTER_Y[5:0]) begin
                            hol_target_port[p][v] = PORT_SOUTH[2:0];
                        end else begin
                            hol_target_port[p][v] = PORT_LOCAL[2:0];
                        end
                    end
                end
            end
        end
    endgenerate

    // ------------------------------------------------------------------------
    // 3. Switch Allocation, Wormhole Locking & Arbitration
    // ------------------------------------------------------------------------
    logic [NUM_PORTS-1:0] out_locked_q;
    logic [2:0]           out_lock_port_q[NUM_PORTS-1:0];
    logic                 out_lock_vc_q  [NUM_PORTS-1:0];
    logic [2:0]           rr_ptr_q       [NUM_PORTS-1:0];

    logic [2:0]           grant_port     [NUM_PORTS-1:0];
    logic                 grant_vc       [NUM_PORTS-1:0];
    logic                 grant_valid    [NUM_PORTS-1:0];

    logic [FLIT_W-1:0]    xbar_flit      [NUM_PORTS-1:0];
    logic                 xbar_valid     [NUM_PORTS-1:0];
    logic                 xbar_ready     [NUM_PORTS-1:0];

    genvar op;
    generate
        for (op = 0; op < NUM_PORTS; op++) begin : gen_output_arbiters
            wire [NUM_PORTS-1:0] req_vc1;
            wire [NUM_PORTS-1:0] req_vc0;

            for (p = 0; p < NUM_PORTS; p++) begin : gen_req_coll
                assign req_vc1[p] = hol_valid[p][1] && (hol_target_port[p][1] == op[2:0]);
                assign req_vc0[p] = hol_valid[p][0] && (hol_target_port[p][0] == op[2:0]);
            end

            // Pure Double-Shift Combinational Round-Robin Priority Logic
            // VC1 (Responses) has strict priority over VC0 (Requests) to prevent deadlocks
            wire [9:0] double_req_vc1 = {req_vc1, req_vc1};
            wire [9:0] double_req_vc0 = {req_vc0, req_vc0};

            wire [4:0] shifted_vc1 = double_req_vc1[rr_ptr_q[op] +: 5];
            wire [4:0] shifted_vc0 = double_req_vc0[rr_ptr_q[op] +: 5];

            logic [2:0] offset_vc1;
            logic       any_vc1;
            always_comb begin
                any_vc1 = |shifted_vc1;
                casez (shifted_vc1)
                    5'b????1: offset_vc1 = 3'd0;
                    5'b???10: offset_vc1 = 3'd1;
                    5'b??100: offset_vc1 = 3'd2;
                    5'b?1000: offset_vc1 = 3'd3;
                    5'b10000: offset_vc1 = 3'd4;
                    default:  offset_vc1 = 3'd0;
                endcase
            end

            logic [2:0] offset_vc0;
            logic       any_vc0;
            always_comb begin
                any_vc0 = |shifted_vc0;
                casez (shifted_vc0)
                    5'b????1: offset_vc0 = 3'd0;
                    5'b???10: offset_vc0 = 3'd1;
                    5'b??100: offset_vc0 = 3'd2;
                    5'b?1000: offset_vc0 = 3'd3;
                    5'b10000: offset_vc0 = 3'd4;
                    default:  offset_vc0 = 3'd0;
                endcase
            end

            wire [3:0] sum_vc1 = {1'b0, rr_ptr_q[op]} + {1'b0, offset_vc1};
            wire [3:0] sum_vc0 = {1'b0, rr_ptr_q[op]} + {1'b0, offset_vc0};

            wire [2:0] rr_grant_vc1 = (sum_vc1 < 4'(NUM_PORTS)) ?
                                      sum_vc1[2:0] :
                                      (sum_vc1[2:0] - NUM_PORTS[2:0]);

            wire [2:0] rr_grant_vc0 = (sum_vc0 < 4'(NUM_PORTS)) ?
                                      sum_vc0[2:0] :
                                      (sum_vc0[2:0] - NUM_PORTS[2:0]);

            wire       out_locked_local    = out_locked_q[op];
            wire [2:0] out_lock_port_local = out_lock_port_q[op];
            wire       out_lock_vc_local   = out_lock_vc_q[op];

            logic [2:0] grant_port_local;
            logic       grant_vc_local;
            logic       grant_valid_local;

            always_comb begin
                grant_port_local  = 3'd0;
                grant_vc_local    = 1'b0;
                grant_valid_local = 1'b0;

                if (out_locked_local) begin
                    grant_port_local  = out_lock_port_local;
                    grant_vc_local    = out_lock_vc_local;
                    grant_valid_local = hol_valid[out_lock_port_local][out_lock_vc_local];
                end else if (any_vc1) begin
                    grant_port_local  = rr_grant_vc1;
                    grant_vc_local    = 1'b1;
                    grant_valid_local = 1'b1;
                end else if (any_vc0) begin
                    grant_port_local  = rr_grant_vc0;
                    grant_vc_local    = 1'b0;
                    grant_valid_local = 1'b1;
                end
            end

            assign grant_port[op]  = grant_port_local;
            assign grant_vc[op]    = grant_vc_local;
            assign grant_valid[op] = grant_valid_local;

            assign xbar_flit[op]  = grant_valid[op] ? hol_flit[grant_port[op]][grant_vc[op]] : '0;
            assign xbar_valid[op] = grant_valid[op];

            wire out_tx_fire = grant_valid[op] && xbar_ready[op];
            wire [1:0] out_ftype = hol_flit[grant_port[op]][grant_vc[op]][543:542];

            always_ff @(posedge clk or negedge rst_n) begin
                if (!rst_n) begin
                    out_locked_q[op]    <= 1'b0;
                    out_lock_port_q[op] <= 3'd0;
                    out_lock_vc_q[op]   <= 1'b0;
                    rr_ptr_q[op]        <= 3'd0;
                end else begin
                    if (out_tx_fire) begin
                        if (!out_locked_q[op]) begin
                            if (out_ftype == FLIT_HEAD) begin
                                out_locked_q[op]    <= 1'b1;
                                out_lock_port_q[op] <= grant_port[op];
                                out_lock_vc_q[op]   <= grant_vc[op];
                            end
                            // Advance round-robin pointer
                            rr_ptr_q[op] <= (grant_port[op] == NUM_PORTS[2:0] - 1'b1) ?
                                            3'd0 : (grant_port[op] + 1'b1);
                        end else begin
                            if (out_ftype == FLIT_TAIL) begin
                                out_locked_q[op] <= 1'b0;
                            end
                        end
                    end
                end
            end
        end
    endgenerate

    // Connect FIFO Pop handshake:
    // A HOL flit pops when it is granted by its target output port and accepted
    generate
        for (p = 0; p < NUM_PORTS; p++) begin : gen_pop_p
            for (v = 0; v < NUM_VCS; v++) begin : gen_pop_v
                logic pop_req;
                always_comb begin
                    pop_req = 1'b0;
                    for (int unsigned op_idx = 0; op_idx < NUM_PORTS; op_idx++) begin
                        if (xbar_valid[op_idx] && xbar_ready[op_idx]) begin
                            if (grant_valid[op_idx] && (grant_port[op_idx] == p[2:0]) && (grant_vc[op_idx] == v[0])) begin
                                pop_req = 1'b1;
                            end
                        end
                    end
                end
                assign hol_pop[p][v] = pop_req;
            end
        end
    endgenerate

    // ------------------------------------------------------------------------
    // 4. Egress Skid Buffers (Modular 2-Entry FIFO per Output Port)
    // ------------------------------------------------------------------------
    generate
        for (op = 0; op < NUM_PORTS; op++) begin : gen_egress_buffers
            wire [FLIT_W-1:0] egress_flit;
            wire              egress_valid;
            wire              active_vc = egress_flit[526];
            wire              egress_ready = out_ready_i[op][active_vc];

            ara_noc_fifo #(
                .DATA_W(FLIT_W),
                .DEPTH (2)
            ) u_egress_skid (
                .clk         (clk),
                .rst_n       (rst_n),
                .push_data_i (xbar_flit[op]),
                .push_valid_i(xbar_valid[op]),
                .push_ready_o(xbar_ready[op]),
                .pop_data_o  (egress_flit),
                .pop_valid_o (egress_valid),
                .pop_ready_i (egress_ready)
            );

            assign out_flit_o[op]  = egress_flit;
            assign out_valid_o[op] = egress_valid;
        end
    endgenerate

`ifdef FORMAL
    // Formal Reset Assumption
    reg [2:0] f_router_rst = 0;
    always @(posedge clk) begin
        if (f_router_rst < 3'd3)
            f_router_rst <= f_router_rst + 1'b1;
    end

    always_comb begin
        if (f_router_rst < 3'd2)
            assume (!rst_n);
        else
            assume (rst_n);
    end

    // Property 1: X-Y Dimension Order Routing Invariant
    genvar fp, fv;
    generate
        for (fp = 0; fp < NUM_PORTS; fp++) begin : gen_f_routing_p
            for (fv = 0; fv < NUM_VCS; fv++) begin : gen_f_routing_v
                wire [5:0] f_dest_x = hol_flit[fp][fv][541:536];
                wire [5:0] f_dest_y = hol_flit[fp][fv][535:530];

                always @(posedge clk) begin
                    if (rst_n && hol_valid[fp][fv]) begin
                        if (f_dest_x > ROUTER_X[5:0])
                            assert (hol_target_port[fp][fv] == PORT_EAST[2:0]);
                        else if (f_dest_x < ROUTER_X[5:0])
                            assert (hol_target_port[fp][fv] == PORT_WEST[2:0]);
                        else begin
                            if (f_dest_y > ROUTER_Y[5:0])
                                assert (hol_target_port[fp][fv] == PORT_SOUTH[2:0]);
                            else if (f_dest_y < ROUTER_Y[5:0])
                                assert (hol_target_port[fp][fv] == PORT_NORTH[2:0]);
                            else
                                assert (hol_target_port[fp][fv] == PORT_LOCAL[2:0]);
                        end
                    end
                end
            end
        end
    endgenerate

    // Property 2: Mutual Exclusion & Valid Target Grant per Egress Port
    genvar fop;
    generate
        for (fop = 0; fop < NUM_PORTS; fop++) begin : gen_f_egress
            always @(posedge clk) begin
                if (rst_n && grant_valid[fop]) begin
                    assert (grant_port[fop] < NUM_PORTS[2:0]);
                    assert (hol_valid[grant_port[fop]][grant_vc[fop]]);
                    if (!out_locked_q[fop]) begin
                        assert (hol_target_port[grant_port[fop]][grant_vc[fop]] == fop[2:0]);
                    end else begin
                        assert (grant_port[fop] == out_lock_port_q[fop]);
                        assert (grant_vc[fop] == out_lock_vc_q[fop]);
                    end
                end
            end
        end
    endgenerate
`endif

endmodule

