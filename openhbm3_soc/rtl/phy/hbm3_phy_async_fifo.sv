// ============================================================================
// File: hbm3_phy_async_fifo.sv
// Project: Open_HBM3_PHY
// Technology: ASAP7 7nm FinFET Predictive PDK
// Description:
//   Dual-clock asynchronous FIFO using Cummings-style Gray code pointers and
//   double-flop synchronizers marked with (* ASYNC_REG = "TRUE" *).
// ============================================================================

module hbm3_phy_async_fifo #(
    parameter int DATA_BITS = 64,
    parameter int ADDR_BITS = 3
)(
    input  logic                 wr_clk,
    input  logic                 wr_rst_n,
    input  logic                 wr_valid,
    output logic                 wr_ready,
    input  logic [DATA_BITS-1:0] wr_data,

    input  logic                 rd_clk,
    input  logic                 rd_rst_n,
    output logic                 rd_valid,
    input  logic                 rd_ready,
    output logic [DATA_BITS-1:0] rd_data
);
    localparam int PTR_BITS = ADDR_BITS + 1;
    localparam int DEPTH    = 1 << ADDR_BITS;

    logic [DATA_BITS-1:0] mem_q [0:DEPTH-1];
    logic [PTR_BITS-1:0]  wr_bin_q, wr_gray_q, rd_bin_q, rd_gray_q;

    (* ASYNC_REG = "TRUE" *) logic [PTR_BITS-1:0] rd_gray_wr1_q, rd_gray_wr2_q;
    (* ASYNC_REG = "TRUE" *) logic [PTR_BITS-1:0] wr_gray_rd1_q, wr_gray_rd2_q;

    logic wr_full_q, rd_empty_q;
    logic wr_full_nxt, rd_empty_nxt;
    logic [PTR_BITS-1:0] wr_bin_nxt, wr_gray_nxt, rd_bin_nxt, rd_gray_nxt;

    function automatic [PTR_BITS-1:0] bin_to_gray(input [PTR_BITS-1:0] val);
        bin_to_gray = (val >> 1) ^ val;
    endfunction

    always_comb begin
        wr_bin_nxt  = wr_bin_q + (wr_valid && !wr_full_q);
        wr_gray_nxt = bin_to_gray(wr_bin_nxt);
        wr_full_nxt = (wr_gray_nxt == {~rd_gray_wr2_q[PTR_BITS-1:PTR_BITS-2], rd_gray_wr2_q[PTR_BITS-3:0]});

        rd_bin_nxt  = rd_bin_q + (!rd_empty_q && rd_ready);
        rd_gray_nxt = bin_to_gray(rd_bin_nxt);
        rd_empty_nxt= (rd_gray_nxt == wr_gray_rd2_q);
    end

    assign wr_ready = !wr_full_q;
    assign rd_valid = !rd_empty_q;
    assign rd_data  = mem_q[rd_bin_q[ADDR_BITS-1:0]];

    always_ff @(posedge wr_clk or negedge wr_rst_n) begin
        if (!wr_rst_n) begin
            wr_bin_q        <= '0;
            wr_gray_q       <= '0;
            rd_gray_wr1_q   <= '0;
            rd_gray_wr2_q   <= '0;
            wr_full_q       <= 1'b0;
        end else begin
            rd_gray_wr1_q   <= rd_gray_q;
            rd_gray_wr2_q   <= rd_gray_wr1_q;
            if (wr_valid && wr_ready) begin
                mem_q[wr_bin_q[ADDR_BITS-1:0]] <= wr_data;
            end
            wr_bin_q        <= wr_bin_nxt;
            wr_gray_q       <= wr_gray_nxt;
            wr_full_q       <= wr_full_nxt;
        end
    end

    always_ff @(posedge rd_clk or negedge rd_rst_n) begin
        if (!rd_rst_n) begin
            rd_bin_q        <= '0;
            rd_gray_q       <= '0;
            wr_gray_rd1_q   <= '0;
            wr_gray_rd2_q   <= '0;
            rd_empty_q      <= 1'b1;
        end else begin
            wr_gray_rd1_q   <= wr_gray_q;
            wr_gray_rd2_q   <= wr_gray_rd1_q;
            rd_bin_q        <= rd_bin_nxt;
            rd_gray_q       <= rd_gray_nxt;
            rd_empty_q      <= rd_empty_nxt;
        end
    end

endmodule
