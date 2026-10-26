// ============================================================================
// File: hbm3_phy_elastic_buffer.sv
// Project: Open_HBM3_PHY
// Technology: ASAP7 7nm FinFET Predictive PDK (WCK Target: 4.6 GHz)
// Description:
//   Single-lane Elastic Deskew Buffer (Circular FIFO) with Frame Delimiter sync.
//   Synchronizes across all 64 DQ lanes. Detects the frame delimiter (8'h7E)
//   as the boundary marker, filters out framing delimiters, and buffers
//   post-framing payload for simultaneous cycle-aligned readout.
// ============================================================================

`include "hbm3_phy_defs.svh"

module hbm3_phy_elastic_buffer #(
    parameter int SER_RATIO = HBM3_SER_RATIO,       // 8 bits
    parameter int DEPTH     = HBM3_ELASTIC_BUF_DEPTH // 4 entries
)(
    input  logic                 wck,
    input  logic                 rst_n,
    input  logic                 clr_deskew,       // Soft reset / re-arm for training
    input  logic                 arm_deskew,       // Enable frame marker hunt
    input  logic [SER_RATIO-1:0] frame_marker_i,   // Known delimiter pattern (8'h7E)

    // Write side (from local deserializer)
    input  logic                 wr_en,
    input  logic [SER_RATIO-1:0] wr_data,

    // Read side (from global deskew controller)
    input  logic                 rd_en,
    output logic [SER_RATIO-1:0] rd_data,

    // Status flags
    output logic                 marker_seen_o,    // Sticky: marker was detected
    output logic                 has_payload_o,    // Has active buffered payload ready to pop
    output logic [2:0]           occupancy_o,      // Current buffer fill level
    output logic                 overflow_err_o,
    output logic                 underflow_err_o
);
    localparam int PTR_BITS = $clog2(DEPTH);

    logic [SER_RATIO-1:0] mem_q [0:DEPTH-1];
    logic [PTR_BITS-1:0]  wr_ptr_q;
    logic [PTR_BITS-1:0]  rd_ptr_q;
    logic [2:0]           count_q;
    logic                 marker_seen_q;
    logic                 buffering_active_q;

    assign marker_seen_o = marker_seen_q;
    assign has_payload_o = buffering_active_q && (count_q > 3'd0);
    assign occupancy_o   = count_q;
    assign rd_data       = mem_q[rd_ptr_q];

    always_ff @(posedge wck or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr_q           <= '0;
            rd_ptr_q           <= '0;
            count_q            <= '0;
            marker_seen_q      <= 1'b0;
            buffering_active_q <= 1'b0;
            overflow_err_o     <= 1'b0;
            underflow_err_o    <= 1'b0;
            for (int i = 0; i < DEPTH; i++) begin
                mem_q[i] <= '0;
            end
        end else if (clr_deskew) begin
            wr_ptr_q           <= '0;
            rd_ptr_q           <= '0;
            count_q            <= '0;
            marker_seen_q      <= 1'b0;
            buffering_active_q <= 1'b0;
            overflow_err_o     <= 1'b0;
            underflow_err_o    <= 1'b0;
        end else begin
            // ----------------------------------------------------------------
            // Write Path: Marker Detection and Clean Payload Buffering
            // ----------------------------------------------------------------
            if (wr_en) begin
                if (arm_deskew && !buffering_active_q) begin
                    if (wr_data == frame_marker_i) begin
                        // Frame delimiter seen on this lane
                        marker_seen_q <= 1'b1;
                    end else if (marker_seen_q) begin
                        // First post-delimiter user payload word arrives!
                        buffering_active_q <= 1'b1;
                        mem_q[wr_ptr_q]    <= wr_data;
                        wr_ptr_q           <= (wr_ptr_q == PTR_BITS'(DEPTH - 1)) ? '0 : wr_ptr_q + 1'b1;
                        if (!rd_en) begin
                            count_q <= count_q + 1'b1;
                        end
                    end
                end else if (buffering_active_q) begin
                    // Normal user payload streaming
                    if (count_q == 3'(DEPTH) && !rd_en) begin
                        overflow_err_o <= 1'b1;
                    end else begin
                        mem_q[wr_ptr_q] <= wr_data;
                        wr_ptr_q        <= (wr_ptr_q == PTR_BITS'(DEPTH - 1)) ? '0 : wr_ptr_q + 1'b1;
                        if (!rd_en) begin
                            count_q <= count_q + 1'b1;
                        end
                    end
                end
            end

            // ----------------------------------------------------------------
            // Read Path
            // ----------------------------------------------------------------
            if (rd_en) begin
                if (count_q == 3'd0) begin
                    underflow_err_o <= 1'b1;
                end else begin
                    rd_ptr_q <= (rd_ptr_q == PTR_BITS'(DEPTH - 1)) ? '0 : rd_ptr_q + 1'b1;
                    if (!wr_en || (!buffering_active_q)) begin
                        count_q <= count_q - 1'b1;
                    end
                end
            end
        end
    end

endmodule
