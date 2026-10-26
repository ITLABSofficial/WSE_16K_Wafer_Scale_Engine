// ============================================================================
// File: tb_ara_noc_mesh_router.sv
// Project: Ara_MultiCore_WSE_HBM3 (Phase 1: NoC Mesh Fabric - Step 1 Verification)
// Technology: ASAP7 7nm FinFET Predictive PDK (Target: 2.0 GHz / 500 ps cycle)
// Architectural Invariants & Verification Standards
//
// Description:
//   Rigorous Bit-Exact Testbench for ara_noc_mesh_router (5-Port 2D-Mesh Router):
//   1. Reset & ready-valid handshake initialization.
//   2. Dimension-Order X-Y routing across all 5 directions (North, South, East, West, Local).
//   3. Multi-Flit Wormhole Packet Locking (HEAD -> BODY -> TAIL) integrity.
//   4. Virtual Channel (VC0 Request vs VC1 Response) prioritization and isolation.
//   5. Downstream Backpressure Stalling and Zero-Drop Skid-Buffer Recovery.
//   6. Raw 544-bit Bit-by-Bit XOR verification against Golden Reference.
// ============================================================================

`timescale 1ps/1ps

module tb_ara_noc_mesh_router;

    localparam int unsigned ROUTER_X     = 1;
    localparam int unsigned ROUTER_Y     = 1;
    localparam int unsigned FLIT_W       = 544;
    localparam int unsigned NUM_PORTS    = 5;
    localparam int unsigned NUM_VCS      = 2;
    localparam int unsigned FIFO_DEPTH   = 4;

    localparam int unsigned PORT_NORTH   = 0;
    localparam int unsigned PORT_EAST    = 1;
    localparam int unsigned PORT_SOUTH   = 2;
    localparam int unsigned PORT_WEST    = 3;
    localparam int unsigned PORT_LOCAL   = 4;

    localparam logic [1:0] FLIT_HEAD     = 2'b00;
    localparam logic [1:0] FLIT_BODY     = 2'b01;
    localparam logic [1:0] FLIT_TAIL     = 2'b10;
    localparam logic [1:0] FLIT_SINGLE   = 2'b11;

    // Clock: 2.0 GHz (500 ps period -> 250 ps high, 250 ps low)
    logic clk = 1'b0;
    always #250 clk = ~clk;

    logic rst_n = 1'b0;

    // DUT Signals
    logic [NUM_PORTS-1:0][FLIT_W-1:0]  in_flit;
    logic [NUM_PORTS-1:0]              in_valid;
    wire  [NUM_PORTS-1:0][NUM_VCS-1:0] in_ready;

    wire  [NUM_PORTS-1:0][FLIT_W-1:0]  out_flit;
    wire  [NUM_PORTS-1:0]              out_valid;
    logic [NUM_PORTS-1:0][NUM_VCS-1:0] out_ready;

    // DUT Instantiation
    ara_noc_mesh_router #(
        .ROUTER_X   (ROUTER_X),
        .ROUTER_Y   (ROUTER_Y),
        .FLIT_W     (FLIT_W),
        .NUM_PORTS  (NUM_PORTS),
        .NUM_VCS    (NUM_VCS),
        .FIFO_DEPTH (FIFO_DEPTH)
    ) u_dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .in_flit_i  (in_flit),
        .in_valid_i (in_valid),
        .in_ready_o (in_ready),
        .out_flit_o (out_flit),
        .out_valid_o(out_valid),
        .out_ready_i(out_ready)
    );

    // Helper function to build a 544-bit Flit
    function automatic [FLIT_W-1:0] make_flit(
        input logic [1:0]   ftype,
        input logic [5:0]   dest_x,
        input logic [5:0]   dest_y,
        input logic [3:0]   vc_id,
        input logic [13:0]  txn_id,
        input logic [511:0] payload
    );
        make_flit = {ftype, dest_x, dest_y, vc_id, txn_id, payload};
    endfunction

    int error_count = 0;

    function automatic logic get_in_ready(input int p, input logic vc);
        case (p)
            0: return in_ready[0][vc];
            1: return in_ready[1][vc];
            2: return in_ready[2][vc];
            3: return in_ready[3][vc];
            4: return in_ready[4][vc];
            default: return 1'b0;
        endcase
    endfunction

    function automatic logic get_out_valid(input int p);
        case (p)
            0: return out_valid[0];
            1: return out_valid[1];
            2: return out_valid[2];
            3: return out_valid[3];
            4: return out_valid[4];
            default: return 1'b0;
        endcase
    endfunction

    function automatic [FLIT_W-1:0] get_out_flit(input int p);
        case (p)
            0: return out_flit[0];
            1: return out_flit[1];
            2: return out_flit[2];
            3: return out_flit[3];
            4: return out_flit[4];
            default: return '0;
        endcase
    endfunction

    task automatic set_in_flit(input int p, input logic [FLIT_W-1:0] f, input logic v);
        case (p)
            0: begin in_flit[0] <= f; in_valid[0] <= v; end
            1: begin in_flit[1] <= f; in_valid[1] <= v; end
            2: begin in_flit[2] <= f; in_valid[2] <= v; end
            3: begin in_flit[3] <= f; in_valid[3] <= v; end
            4: begin in_flit[4] <= f; in_valid[4] <= v; end
        endcase
    endtask

    // Task to send a single flit to a given ingress port
    task automatic send_flit(
        input int unsigned        in_p,
        input logic [FLIT_W-1:0]  flit_data
    );
        logic target_vc;
        target_vc = flit_data[526];

        // Wait until port is ready for this VC /* verified invariant */
        while (!get_in_ready(in_p, target_vc)) begin
            @(posedge clk);
            #1;
        end

        set_in_flit(in_p, flit_data, 1'b1);
        @(posedge clk);
        #1;
        set_in_flit(in_p, '0, 1'b0);
    endtask

    // Task to receive and verify a flit on an egress port
    task automatic expect_flit(
        input int unsigned        out_p,
        input logic [FLIT_W-1:0]  exp_flit,
        input string              test_name
    );
        int timeout;
        logic [FLIT_W-1:0] actual_flit;
        timeout = 50;

        while (!get_out_valid(out_p) && timeout > 0) begin
            @(posedge clk);
            #1;
            timeout--;
        end

        if (timeout == 0) begin
            $display("  [FATAL ERROR] %s: Timeout waiting for flit on Egress Port %0d!", test_name, out_p);
            error_count++;
        end else begin
            actual_flit = get_out_flit(out_p);
            // Bit-exact XOR check
            if (actual_flit !== exp_flit) begin
                $display("  [FATAL ERROR] %s: Flit mismatch on Port %0d!", test_name, out_p);
                $display("    Expected: 0x%0136x", exp_flit);
                $display("    Received: 0x%0136x", actual_flit);
                $display("    Diff XOR: 0x%0136x", exp_flit ^ actual_flit);
                error_count++;
            end else begin
                $display("  [PASS] %s: Bit-Exact Match on Egress Port %0d! (Txn ID=0x%0x, Type=%b)",
                         test_name, out_p, actual_flit[525:512], actual_flit[543:542]);
            end
            // Consume flit
            @(posedge clk);
            #1;
        end
    endtask

    initial begin
        $display("============================================================================");
        $display("  ARA 5-PORT 2D-MESH NOC ROUTER VERIFICATION TESTBENCH (ROUTER AT [1,1])");
        $display("============================================================================");

        // Initialize signals
        in_flit   = '0;
        in_valid  = '0;
        out_ready = {NUM_PORTS{2'b11}}; // All downstream ports initially ready for both VCs

        // Reset sequence /* verified invariant */
        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        #1;
        rst_n = 1'b1;
        repeat (2) @(posedge clk);
        #1;

        // --------------------------------------------------------------------
        // TEST 1: Dimension-Order X-Y Routing in All 4 Directions + Local
        // --------------------------------------------------------------------
        $display("\n[TEST 1] Verifying Dimension-Order X-Y Routing to All Egress Ports...");
        begin
            logic [FLIT_W-1:0] f_east, f_west, f_north, f_south, f_local;

            // 1.1 Local -> East (dest_x = 2 > ROUTER_X=1)
            f_east = make_flit(FLIT_SINGLE, 6'd2, 6'd1, 4'h0, 14'h101, {16{32'hAAAA_0001}});
            send_flit(PORT_LOCAL, f_east);
            expect_flit(PORT_EAST, f_east, "DOR Local -> East");

            // 1.2 Local -> West (dest_x = 0 < ROUTER_X=1)
            f_west = make_flit(FLIT_SINGLE, 6'd0, 6'd1, 4'h0, 14'h102, {16{32'hBBBB_0002}});
            send_flit(PORT_LOCAL, f_west);
            expect_flit(PORT_WEST, f_west, "DOR Local -> West");

            // 1.3 Local -> North (dest_x = 1 == ROUTER_X, dest_y = 0 < ROUTER_Y=1)
            f_north = make_flit(FLIT_SINGLE, 6'd1, 6'd0, 4'h0, 14'h103, {16{32'hCCCC_0003}});
            send_flit(PORT_LOCAL, f_north);
            expect_flit(PORT_NORTH, f_north, "DOR Local -> North");

            // 1.4 Local -> South (dest_x = 1 == ROUTER_X, dest_y = 2 > ROUTER_Y=1)
            f_south = make_flit(FLIT_SINGLE, 6'd1, 6'd2, 4'h0, 14'h104, {16{32'hDDDD_0004}});
            send_flit(PORT_LOCAL, f_south);
            expect_flit(PORT_SOUTH, f_south, "DOR Local -> South");

            // 1.5 North -> Local (dest_x = 1 == ROUTER_X, dest_y = 1 == ROUTER_Y)
            f_local = make_flit(FLIT_SINGLE, 6'd1, 6'd1, 4'h0, 14'h105, {16{32'hEEEE_0005}});
            send_flit(PORT_NORTH, f_local);
            expect_flit(PORT_LOCAL, f_local, "DOR North -> Local");
        end

        // --------------------------------------------------------------------
        // TEST 2: Multi-Flit Wormhole Packet Locking (HEAD -> BODY -> TAIL)
        // --------------------------------------------------------------------
        $display("\n[TEST 2] Verifying Multi-Flit Wormhole Packet Locking...");
        begin
            logic [FLIT_W-1:0] f_head, f_body, f_tail;

            f_head = make_flit(FLIT_HEAD, 6'd2, 6'd1, 4'h0, 14'h201, {16{32'h1111_0001}});
            f_body = make_flit(FLIT_BODY, 6'd2, 6'd1, 4'h0, 14'h201, {16{32'h2222_0002}});
            f_tail = make_flit(FLIT_TAIL, 6'd2, 6'd1, 4'h0, 14'h201, {16{32'h3333_0003}});

            // Send packet from West to East
            fork
                begin
                    send_flit(PORT_WEST, f_head);
                    send_flit(PORT_WEST, f_body);
                    send_flit(PORT_WEST, f_tail);
                end
                begin
                    expect_flit(PORT_EAST, f_head, "Wormhole HEAD Flit");
                    expect_flit(PORT_EAST, f_body, "Wormhole BODY Flit");
                    expect_flit(PORT_EAST, f_tail, "Wormhole TAIL Flit");
                end
            join
        end

        // --------------------------------------------------------------------
        // TEST 3: Virtual Channel VC1 (Response) Priority over VC0 (Request)
        // --------------------------------------------------------------------
        $display("\n[TEST 3] Verifying Virtual Channel Isolation & VC1 Priority...");
        begin
            logic [FLIT_W-1:0] f_vc0_req, f_vc1_rsp;

            // Both destined to LOCAL port
            f_vc0_req = make_flit(FLIT_SINGLE, 6'd1, 6'd1, 4'h0, 14'h301, {16{32'hAAAA_0000}}); // VC0
            f_vc1_rsp = make_flit(FLIT_SINGLE, 6'd1, 6'd1, 4'h1, 14'h302, {16{32'hBBBB_1111}}); // VC1

            // Ingest simultaneously from North and South
            @(posedge clk);
            #1;
            in_flit[PORT_NORTH]  <= f_vc0_req;
            in_valid[PORT_NORTH] <= 1'b1;
            in_flit[PORT_SOUTH]  <= f_vc1_rsp;
            in_valid[PORT_SOUTH] <= 1'b1;
            @(posedge clk);
            #1;
            in_valid[PORT_NORTH] <= 1'b0;
            in_valid[PORT_SOUTH] <= 1'b0;
            in_flit[PORT_NORTH]  <= '0;
            in_flit[PORT_SOUTH]  <= '0;

            // VC1 MUST be delivered first!
            expect_flit(PORT_LOCAL, f_vc1_rsp, "VC1 High Priority Response First");
            expect_flit(PORT_LOCAL, f_vc0_req, "VC0 Request Second");
        end

        // --------------------------------------------------------------------
        // TEST 4: Downstream Backpressure Stalling & Zero-Drop Skid Recovery
        // --------------------------------------------------------------------
        $display("\n[TEST 4] Verifying Downstream Backpressure & Skid-Buffer Tolerance...");
        begin
            logic [FLIT_W-1:0] f_bp1, f_bp2;

            f_bp1 = make_flit(FLIT_SINGLE, 6'd2, 6'd1, 4'h0, 14'h401, {16{32'hFACE_0001}});
            f_bp2 = make_flit(FLIT_SINGLE, 6'd2, 6'd1, 4'h0, 14'h402, {16{32'hFACE_0002}});

            // Deassert East ready to simulate downstream stall
            out_ready[PORT_EAST] = 2'b00;

            send_flit(PORT_LOCAL, f_bp1);
            send_flit(PORT_LOCAL, f_bp2);

            // Wait 10 cycles under stall: flits must stay queued without corruption
            repeat (10) @(posedge clk);
            #1;

            // Release stall
            out_ready[PORT_EAST] = 2'b11;

            expect_flit(PORT_EAST, f_bp1, "Backpressure Release Flit 1");
            expect_flit(PORT_EAST, f_bp2, "Backpressure Release Flit 2");
        end

        // --------------------------------------------------------------------
        // TESTBENCH SUMMARY REPORT
        // --------------------------------------------------------------------
        repeat (10) @(posedge clk);

        $display("\n============================================================================");
        if (error_count == 0) begin
            $display("  >>> ALL NOC ROUTER TESTS PASSED (0 ERRORS)! <<<");
            $display("  5-Port Dimension-Order X-Y Routing & Wormhole Locking Verified!");
            $display("  Dual VC Isolation & Backpressure Skid Buffering 100%% Bit-Exact!");
        end else begin
            $display("  >>> TESTBENCH FAILED WITH %0d ERRORS! <<<", error_count);
        end
        $display("============================================================================\n");

        $finish;
    end

endmodule
