// ============================================================================
// File: ecc.sv
// Project: Open_HBM3_Controller
// Description:
//   Hamming SECDED (39, 32) Encoder and Decoder.
//   Single Error Correct, Double Error Detect for 32-bit data payloads.
//   Optimized with parallel XOR trees to avoid synthesis overhead and
//   maximize simulation throughput.
// ============================================================================
`timescale 1ns/1ps

module ecc_encode (
    input  logic [31:0] din,
    output logic [6:0]  ecc      // [5:0] = Hamming parity check, [6] = overall parity
);
    // Hamming(39,32) concurrent XOR parity masks (SECDED Parity Matrix):
    // Directly synthesizes to parallel XOR trees without runtime loops or constant selects.
    wire [5:0] p;
    assign p[0] = ^(din & 32'h56AA_AD5B);
    assign p[1] = ^(din & 32'h9B33_366D);
    assign p[2] = ^(din & 32'hE3C3_C78E);
    assign p[3] = ^(din & 32'h03FC_07F0);
    assign p[4] = ^(din & 32'h03FF_F800);
    assign p[5] = ^(din & 32'hFC00_0000);

    assign ecc  = {^din ^ ^p, p};
endmodule

module ecc_decode (
    input  logic [31:0] din,
    input  logic [6:0]  ecc,
    output logic [31:0] dout,
    output logic        err_corrected,     // Single-bit error: corrected successfully
    output logic        err_uncorrectable  // Double-bit error: detected, uncorrectable
);
    wire [5:0] syndrome;
    assign syndrome[0] = ecc[0] ^ ^(din & 32'h56AA_AD5B);
    assign syndrome[1] = ecc[1] ^ ^(din & 32'h9B33_366D);
    assign syndrome[2] = ecc[2] ^ ^(din & 32'hE3C3_C78E);
    assign syndrome[3] = ecc[3] ^ ^(din & 32'h03FC_07F0);
    assign syndrome[4] = ecc[4] ^ ^(din & 32'h03FF_F800);
    assign syndrome[5] = ecc[5] ^ ^(din & 32'hFC00_0000);

    wire overall_parity_err = (^din) ^ (^ecc);

    // 1-based positions of 32 data bits within Hamming(39,32) excluding power-of-two check bit positions:
    localparam logic [32*6-1:0] POS_TABLE = {
        6'd38, 6'd37, 6'd36, 6'd35, 6'd34, 6'd33, 6'd31, 6'd30,
        6'd29, 6'd28, 6'd27, 6'd26, 6'd25, 6'd24, 6'd23, 6'd22,
        6'd21, 6'd20, 6'd19, 6'd18, 6'd17, 6'd15, 6'd14, 6'd13,
        6'd12, 6'd11, 6'd10, 6'd9,  6'd7,  6'd6,  6'd5,  6'd3
    };

    genvar i;
    generate
        for (i = 0; i < 32; i++) begin : gen_corr
            localparam logic [5:0] BIT_POS = POS_TABLE[i*6 +: 6];
            assign dout[i] = (syndrome == BIT_POS) ? ~din[i] : din[i];
        end
    endgenerate

    // SECDED: overall parity error and non-zero syndrome indicates single-bit correctable error.
    // Non-zero syndrome with matching overall parity indicates double-bit uncorrectable error.
    assign err_corrected     = (syndrome != 6'd0) && overall_parity_err;
    assign err_uncorrectable = (syndrome != 6'd0) && !overall_parity_err;
endmodule
