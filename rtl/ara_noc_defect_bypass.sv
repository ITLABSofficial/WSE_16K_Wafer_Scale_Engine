// ============================================================================
// File: ara_noc_defect_bypass.sv
// Project: Ara_MultiCore_WSE_HBM3 (Phase 1: NoC Mesh Fabric - Step 3)
// Technology: ASAP7 7nm FinFET Predictive PDK (Target: 2.0 GHz / 500 ps cycle)
// Architectural Invariants & Verification Standards
//
// Description:
//   Wafer-Scale Defect Tolerance & Deflection Bypass Module for 300mm WSE.
//   In a 300mm wafer with 8,192 cores, lithography dust and manufacturing
//   defects will inevitably disable some percentage of tiles.
//
//   Architecture (Cerebras / MIT Deflection Bypass Model):
//   1. Normal Mode (defect_en_i == 0):
//      - The 4 mesh links (North, South, East, West) connect directly to the
//        local 5-port ara_noc_mesh_router with 0 added latency.
//      - Local NI injection and ejection are fully operational.
//
//   2. Defect Bypass Mode (defect_en_i == 1):
//      - The local compute cluster and local router are completely ISOLATED.
//      - Local NI injection is rejected (local_ni_ready_o = 0).
//      - E-W transit traffic is deflected directly through a 1-cycle registered
//        pipeline slice (West_In -> East_Out, East_In -> West_Out).
//      - N-S transit traffic is deflected directly through a 1-cycle registered
//        pipeline slice (North_In -> South_Out, South_In -> North_Out).
//      - If a packet has Dest(X,Y) == this dead node, its destination is
//        dynamically retargeted to the spare column (spare_x_i, spare_y_i)
//        preventing packets from being dropped or trapped in dead silicon.
//      - 2D-Mesh topological continuity across the wafer is 100% preserved!
// ============================================================================

`timescale 1ps/1ps

module ara_noc_defect_bypass #(
    parameter int unsigned FLIT_W = 544,
    parameter int unsigned NODE_X = 0,
    parameter int unsigned NODE_Y = 0
)(
    input  logic              clk,
    input  logic              rst_n,

    // e-Fuse / JTAG Defect Configuration
    input  logic              defect_en_i,      // 1 = Node is hardware-defective
    input  logic [5:0]        spare_x_i,        // Designated spare cluster X coordinate
    input  logic [5:0]        spare_y_i,        // Designated spare cluster Y coordinate
    output logic              node_bypassed_o,  // Status flag: 1 if in bypass mode
    output logic [31:0]       bypass_flit_cnt_o,// Telemetry counter: bypassed flits

    // ------------------------------------------------------------------------
    // External Mesh Ports (Connected to Neighbor Tiles / Physical Wires)
    // ------------------------------------------------------------------------
    // Ingress from neighbors
    input  logic [FLIT_W-1:0] north_in_flit_i,
    input  logic              north_in_valid_i,
    output logic [1:0]        north_in_ready_o,

    input  logic [FLIT_W-1:0] south_in_flit_i,
    input  logic              south_in_valid_i,
    output logic [1:0]        south_in_ready_o,

    input  logic [FLIT_W-1:0] east_in_flit_i,
    input  logic              east_in_valid_i,
    output logic [1:0]        east_in_ready_o,

    input  logic [FLIT_W-1:0] west_in_flit_i,
    input  logic              west_in_valid_i,
    output logic [1:0]        west_in_ready_o,

    // Egress to neighbors
    output logic [FLIT_W-1:0] north_out_flit_o,
    output logic              north_out_valid_o,
    input  logic [1:0]        north_out_ready_i,

    output logic [FLIT_W-1:0] south_out_flit_o,
    output logic              south_out_valid_o,
    input  logic [1:0]        south_out_ready_i,

    output logic [FLIT_W-1:0] east_out_flit_o,
    output logic              east_out_valid_o,
    input  logic [1:0]        east_out_ready_i,

    output logic [FLIT_W-1:0] west_out_flit_o,
    output logic              west_out_valid_o,
    input  logic [1:0]        west_out_ready_i,

    // ------------------------------------------------------------------------
    // Internal Ports to Local ara_noc_mesh_router
    // ------------------------------------------------------------------------
    output logic [FLIT_W-1:0] r_north_in_flit_o,
    output logic              r_north_in_valid_o,
    input  logic [1:0]        r_north_in_ready_i,

    output logic [FLIT_W-1:0] r_south_in_flit_o,
    output logic              r_south_in_valid_o,
    input  logic [1:0]        r_south_in_ready_i,

    output logic [FLIT_W-1:0] r_east_in_flit_o,
    output logic              r_east_in_valid_o,
    input  logic [1:0]        r_east_in_ready_i,

    output logic [FLIT_W-1:0] r_west_in_flit_o,
    output logic              r_west_in_valid_o,
    input  logic [1:0]        r_west_in_ready_i,

    input  logic [FLIT_W-1:0] r_north_out_flit_i,
    input  logic              r_north_out_valid_i,
    output logic [1:0]        r_north_out_ready_o,

    input  logic [FLIT_W-1:0] r_south_out_flit_i,
    input  logic              r_south_out_valid_i,
    output logic [1:0]        r_south_out_ready_o,

    input  logic [FLIT_W-1:0] r_east_out_flit_i,
    input  logic              r_east_out_valid_i,
    output logic [1:0]        r_east_out_ready_o,

    input  logic [FLIT_W-1:0] r_west_out_flit_i,
    input  logic              r_west_out_valid_i,
    output logic [1:0]        r_west_out_ready_o,

    // ------------------------------------------------------------------------
    // Local NI Port Interception
    // ------------------------------------------------------------------------
    input  logic              local_ni_valid_i,
    output logic              local_ni_ready_o
);

    assign node_bypassed_o = defect_en_i;

    // Reject local injection if defective
    assign local_ni_ready_o = defect_en_i ? 1'b0 : 1'b1;

    // ------------------------------------------------------------------------
    // Helper function to retarget dead destination to spare column
    // ------------------------------------------------------------------------
    function automatic logic [FLIT_W-1:0] retarget_if_dead(input logic [FLIT_W-1:0] f_in);
        logic [5:0] dest_x;
        logic [5:0] dest_y;
        dest_x = f_in[541:536];
        dest_y = f_in[535:530];
        if (dest_x == NODE_X[5:0] && dest_y == NODE_Y[5:0]) begin
            // Destination was this dead tile: rewrite header Dest to designated spare!
            retarget_if_dead = f_in;
            retarget_if_dead[541:536] = spare_x_i;
            retarget_if_dead[535:530] = spare_y_i;
        end else begin
            retarget_if_dead = f_in;
        end
    endfunction

    // ------------------------------------------------------------------------
    // 1-Cycle Registered Bypass Buffers for Deflection Mode (VC0 & VC1 Aware)
    // ------------------------------------------------------------------------
    // E-W: West_In -> East_Out
    logic [FLIT_W-1:0] bp_we_flit_q;
    logic              bp_we_valid_q;
    wire  [1:0]        bp_we_ready_vec = bp_we_valid_q ? {2{east_out_ready_i[bp_we_flit_q[526]]}} : east_out_ready_i;
    wire               bp_we_ready     = bp_we_ready_vec[west_in_flit_i[526]];

    // E-W: East_In -> West_Out
    logic [FLIT_W-1:0] bp_ew_flit_q;
    logic              bp_ew_valid_q;
    wire  [1:0]        bp_ew_ready_vec = bp_ew_valid_q ? {2{west_out_ready_i[bp_ew_flit_q[526]]}} : west_out_ready_i;
    wire               bp_ew_ready     = bp_ew_ready_vec[east_in_flit_i[526]];

    // N-S: North_In -> South_Out
    logic [FLIT_W-1:0] bp_ns_flit_q;
    logic              bp_ns_valid_q;
    wire  [1:0]        bp_ns_ready_vec = bp_ns_valid_q ? {2{south_out_ready_i[bp_ns_flit_q[526]]}} : south_out_ready_i;
    wire               bp_ns_ready     = bp_ns_ready_vec[north_in_flit_i[526]];

    // N-S: South_In -> North_Out
    logic [FLIT_W-1:0] bp_sn_flit_q;
    logic              bp_sn_valid_q;
    wire  [1:0]        bp_sn_ready_vec = bp_sn_valid_q ? {2{north_out_ready_i[bp_sn_flit_q[526]]}} : north_out_ready_i;
    wire               bp_sn_ready     = bp_sn_ready_vec[south_in_flit_i[526]];

    // Flit count telemetry
    logic [31:0] flit_cnt_q;
    assign bypass_flit_cnt_o = flit_cnt_q;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bp_we_valid_q <= 1'b0;
            bp_we_flit_q  <= '0;
            bp_ew_valid_q <= 1'b0;
            bp_ew_flit_q  <= '0;
            bp_ns_valid_q <= 1'b0;
            bp_ns_flit_q  <= '0;
            bp_sn_valid_q <= 1'b0;
            bp_sn_flit_q  <= '0;
            flit_cnt_q    <= 32'd0;
        end else if (defect_en_i) begin
            // West to East
            if (bp_we_ready) begin
                bp_we_valid_q <= west_in_valid_i;
                bp_we_flit_q  <= retarget_if_dead(west_in_flit_i);
                if (west_in_valid_i) flit_cnt_q <= flit_cnt_q + 1'b1;
            end

            // East to West
            if (bp_ew_ready) begin
                bp_ew_valid_q <= east_in_valid_i;
                bp_ew_flit_q  <= retarget_if_dead(east_in_flit_i);
                if (east_in_valid_i) flit_cnt_q <= flit_cnt_q + 1'b1;
            end

            // North to South
            if (bp_ns_ready) begin
                bp_ns_valid_q <= north_in_valid_i;
                bp_ns_flit_q  <= retarget_if_dead(north_in_flit_i);
                if (north_in_valid_i) flit_cnt_q <= flit_cnt_q + 1'b1;
            end

            // South to North
            if (bp_sn_ready) begin
                bp_sn_valid_q <= south_in_valid_i;
                bp_sn_flit_q  <= retarget_if_dead(south_in_flit_i);
                if (south_in_valid_i) flit_cnt_q <= flit_cnt_q + 1'b1;
            end
        end else begin
            bp_we_valid_q <= 1'b0;
            bp_ew_valid_q <= 1'b0;
            bp_ns_valid_q <= 1'b0;
            bp_sn_valid_q <= 1'b0;
        end
    end

    // ------------------------------------------------------------------------
    // Multiplexing between Normal Router and Deflection Bypass Mode
    // ------------------------------------------------------------------------

    // Ingress to Router (Muted when defective)
    assign r_north_in_flit_o  = defect_en_i ? '0   : north_in_flit_i;
    assign r_north_in_valid_o = defect_en_i ? 1'b0 : north_in_valid_i;

    assign r_south_in_flit_o  = defect_en_i ? '0   : south_in_flit_i;
    assign r_south_in_valid_o = defect_en_i ? 1'b0 : south_in_valid_i;

    assign r_east_in_flit_o   = defect_en_i ? '0   : east_in_flit_i;
    assign r_east_in_valid_o  = defect_en_i ? 1'b0 : east_in_valid_i;

    assign r_west_in_flit_o   = defect_en_i ? '0   : west_in_flit_i;
    assign r_west_in_valid_o  = defect_en_i ? 1'b0 : west_in_valid_i;

    // Ingress Ready to Neighbors (Full 2-Bit VC0/VC1 Ready Vector)
    assign north_in_ready_o   = defect_en_i ? bp_ns_ready_vec : r_north_in_ready_i;
    assign south_in_ready_o   = defect_en_i ? bp_sn_ready_vec : r_south_in_ready_i;
    assign east_in_ready_o    = defect_en_i ? bp_ew_ready_vec : r_east_in_ready_i;
    assign west_in_ready_o    = defect_en_i ? bp_we_ready_vec : r_west_in_ready_i;

    // Egress from Node to Neighbors
    assign north_out_flit_o   = defect_en_i ? bp_sn_flit_q  : r_north_out_flit_i;
    assign north_out_valid_o  = defect_en_i ? bp_sn_valid_q : r_north_out_valid_i;

    assign south_out_flit_o   = defect_en_i ? bp_ns_flit_q  : r_south_out_flit_i;
    assign south_out_valid_o  = defect_en_i ? bp_ns_valid_q : r_south_out_valid_i;

    assign east_out_flit_o    = defect_en_i ? bp_we_flit_q  : r_east_out_flit_i;
    assign east_out_valid_o   = defect_en_i ? bp_we_valid_q : r_east_out_valid_i;

    assign west_out_flit_o    = defect_en_i ? bp_ew_flit_q  : r_west_out_flit_i;
    assign west_out_valid_o   = defect_en_i ? bp_ew_valid_q : r_west_out_valid_i;

    // Router Egress Ready (Suppressed when defective)
    assign r_north_out_ready_o = defect_en_i ? 2'b00 : north_out_ready_i;
    assign r_south_out_ready_o = defect_en_i ? 2'b00 : south_out_ready_i;
    assign r_east_out_ready_o  = defect_en_i ? 2'b00 : east_out_ready_i;
    assign r_west_out_ready_o  = defect_en_i ? 2'b00 : west_out_ready_i;

`ifdef FORMAL
    // ========================================================================
    // FORMAL SVA PROPERTIES (SymbiYosys / Z3 SMT)
    // ========================================================================

    // Reset assumption
    logic [2:0] f_rst_cnt = 0;
    always @(posedge clk) begin
        if (f_rst_cnt < 3'd2) f_rst_cnt <= f_rst_cnt + 1'b1;
    end
    always_comb begin
        if (f_rst_cnt < 3'd2) assume (!rst_n);
        else assume (rst_n);
    end

    // Safety Invariant 1: Local NI isolation during defect mode
    always @(posedge clk) begin
        if (rst_n && f_rst_cnt >= 3'd2) begin
            if (defect_en_i) begin
                assert (!local_ni_ready_o);
                assert (!r_north_in_valid_o);
                assert (!r_south_in_valid_o);
                assert (!r_east_in_valid_o);
                assert (!r_west_in_valid_o);
                assert (!r_north_out_ready_o);
                assert (!r_south_out_ready_o);
                assert (!r_east_out_ready_o);
                assert (!r_west_out_ready_o);
            end else begin
                assert (local_ni_ready_o);
                assert (r_north_in_valid_o == north_in_valid_i);
                assert (r_south_in_valid_o == south_in_valid_i);
                assert (r_east_in_valid_o  == east_in_valid_i);
                assert (r_west_in_valid_o  == west_in_valid_i);
            end
        end
    end

    // Safety Invariant 2: Zero Reflection Loop (Flits never loop back to origin port in bypass mode)
    always @(posedge clk) begin
        if (rst_n && defect_en_i) begin
            // West ingress flows strictly to East output, never reflecting back to West output
            assert (east_out_valid_o == bp_we_valid_q);
            assert (west_out_valid_o == bp_ew_valid_q);
            assert (south_out_valid_o == bp_ns_valid_q);
            assert (north_out_valid_o == bp_sn_valid_q);
        end
    end

    // Configuration assumptions: e-Fuse configuration is static and spare != dead tile
    always @(posedge clk) begin
        if (rst_n) begin
            assume ($stable(defect_en_i));
            assume ($stable(spare_x_i));
            assume ($stable(spare_y_i));
            assume ({spare_x_i, spare_y_i} != {NODE_X[5:0], NODE_Y[5:0]});
        end
    end

    // Safety Invariant 3: Dead Destination Retargeting
    logic [FLIT_W-1:0] f_past_west_flit;
    logic              f_past_west_valid;
    logic              f_past_rst_n;
    always @(posedge clk) begin
        f_past_west_flit  <= west_in_flit_i;
        f_past_west_valid <= west_in_valid_i && bp_we_ready;
        f_past_rst_n      <= rst_n;

        if (rst_n && f_past_rst_n && defect_en_i && f_past_west_valid) begin
            if (f_past_west_flit[541:530] == {NODE_X[5:0], NODE_Y[5:0]}) begin
                // Ingress targeting dead tile must be retargeted to spare
                assert (bp_we_flit_q[541:536] == spare_x_i);
                assert (bp_we_flit_q[535:530] == spare_y_i);
            end else begin
                // Other flits pass through unaltered
                assert (bp_we_flit_q == f_past_west_flit);
            end
        end
    end

    // Cover: Defect bypass transit occurs successfully
    always @(posedge clk) begin
        if (rst_n && defect_en_i) begin
            cover (east_out_valid_o && west_out_valid_o && north_out_valid_o && south_out_valid_o);
        end
    end
`endif

endmodule

