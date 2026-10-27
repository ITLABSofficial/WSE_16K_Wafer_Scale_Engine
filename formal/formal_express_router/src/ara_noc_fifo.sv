// ============================================================================
// File: ara_noc_fifo.sv
// Project: Ara_MultiCore_WSE_HBM3 (NoC Infrastructure)
// Technology: ASAP7 7nm FinFET Predictive PDK (Target: 2.0 GHz / 500 ps cycle)
// Defensive Rules: HATALAR.md (HATA 1, 2, 39, 46 compliant)
//
// Description:
//   Synchronous Multi-Entry FIFO for NoC Virtual Channels and Buffer Stages.
//   Guarantees 100% throughput (0-bubble on continuous push/pop).
//   Push ready depends strictly on internal count (HATA 46 Skid Invariant).
// ============================================================================

`timescale 1ps/1fs

module ara_noc_fifo #(
    parameter int unsigned DATA_W = 544,
    parameter int unsigned DEPTH  = 4
)(
    input  logic              clk,
    input  logic              rst_n,

    // Write / Push Interface
    input  logic [DATA_W-1:0] push_data_i,
    input  logic              push_valid_i,
    output logic              push_ready_o,

    // Read / Pop Interface
    output logic [DATA_W-1:0] pop_data_o,
    output logic              pop_valid_o,
    input  logic              pop_ready_i
);

    localparam int unsigned PTR_W = $clog2(DEPTH);

    logic [DATA_W-1:0] mem [DEPTH-1:0];
    logic [PTR_W-1:0]  wr_ptr_q;
    logic [PTR_W-1:0]  rd_ptr_q;
    logic [PTR_W:0]    count_q;

    // Ready/Valid status
    assign push_ready_o = (count_q < DEPTH);
    assign pop_valid_o  = (count_q > '0);
    assign pop_data_o   = mem[rd_ptr_q];

    wire push_fire = push_valid_i && push_ready_o;
    wire pop_fire  = pop_valid_o  && pop_ready_i;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr_q <= '0;
            rd_ptr_q <= '0;
            count_q  <= '0;
        end else begin
            if (push_fire) begin
                mem[wr_ptr_q] <= push_data_i;
                wr_ptr_q <= (wr_ptr_q == DEPTH - 1) ? '0 : (wr_ptr_q + 1'b1);
            end

            if (pop_fire) begin
                rd_ptr_q <= (rd_ptr_q == DEPTH - 1) ? '0 : (rd_ptr_q + 1'b1);
            end

            case ({push_fire, pop_fire})
                2'b10: count_q <= count_q + 1'b1;
                2'b01: count_q <= count_q - 1'b1;
                default: count_q <= count_q; // 2'b00 or 2'b11
            endcase
        end
    end

`ifdef FORMAL
    // Formal Reset Setup (Reset low initially, then high)
    reg [2:0] f_rst_cnt = 0;
    always @(posedge clk) begin
        if (f_rst_cnt < 3'd3)
            f_rst_cnt <= f_rst_cnt + 1'b1;
    end

    always_comb begin
        if (f_rst_cnt < 3'd2)
            assume (!rst_n);
        else
            assume (rst_n);
    end

    // Safety Invariant 1: Occupancy never exceeds DEPTH
    always @(posedge clk) begin
        if (rst_n) begin
            assert (count_q <= DEPTH);
        end
    end

    // Safety Invariant 2: Ready and Valid flags strictly match counter
    always @(posedge clk) begin
        if (rst_n) begin
            assert (push_ready_o == (count_q < DEPTH));
            assert (pop_valid_o  == (count_q > 0));
        end
    end

    // Safety Invariant 3: Pointers stay within bounds
    always @(posedge clk) begin
        if (rst_n) begin
            assert (wr_ptr_q < DEPTH);
            assert (rd_ptr_q < DEPTH);
        end
    end

    // Safety Invariant 4: No pop fire when count is 0 (Underflow Immunity)
    always @(posedge clk) begin
        if (rst_n && count_q == 0) begin
            assert (!pop_valid_o);
            assert (!pop_fire);
        end
    end

    // Safety Invariant 5: No push fire when count is DEPTH (Overflow Immunity)
    always @(posedge clk) begin
        if (rst_n && count_q == DEPTH) begin
            assert (!push_ready_o);
            assert (!push_fire);
        end
    end

    // Safety Invariant 6: Single-step Counter Delta Conservation
    logic [PTR_W:0] f_past_count;
    logic f_past_push_fire, f_past_pop_fire, f_past_rst_n;
    always @(posedge clk) begin
        f_past_count     <= count_q;
        f_past_push_fire <= push_fire;
        f_past_pop_fire  <= pop_fire;
        f_past_rst_n     <= rst_n;

        if (rst_n && f_past_rst_n) begin
            case ({f_past_push_fire, f_past_pop_fire})
                2'b10: assert (count_q == f_past_count + 1'b1);
                2'b01: assert (count_q == f_past_count - 1'b1);
                2'b11: assert (count_q == f_past_count);
                2'b00: assert (count_q == f_past_count);
            endcase
        end
    end
`endif

endmodule

