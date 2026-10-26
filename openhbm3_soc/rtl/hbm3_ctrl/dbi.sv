// ============================================================================
// File: dbi.sv
// Project: Open_HBM3_Controller
// Description:
//   Data Bus Inversion (DBIac) Encoder and Decoder.
//   Evaluates zero count per byte: if zeros > 4, inverts byte and asserts dbi.
// ============================================================================
`timescale 1ns/1ps

module dbi_enc #(
    parameter int BYTES = 4
)(
    input  logic [BYTES*8-1:0] din,
    output logic [BYTES*8-1:0] dout,
    output logic [BYTES-1:0]   dbi        // 1 = byte inverted
);
    for (genvar b = 0; b < BYTES; b++) begin : g_byte
        logic [7:0] raw;
        logic [3:0] zeros;   // At least 4 bits required to count range 0..8
        assign raw = din[b*8 +: 8];

        // Zero counter (popcount of ~raw)
        always_comb begin
            zeros = 4'd0;
            for (int i = 0; i < 8; i++)
                if (!raw[i]) zeros = zeros + 4'd1;
        end
        assign dbi[b]  = (zeros > 4'd4);
        assign dout[b*8 +: 8] = dbi[b] ? ~raw : raw;
    end
endmodule

module dbi_dec #(
    parameter int BYTES = 4
)(
    input  logic [BYTES*8-1:0] din,
    input  logic [BYTES-1:0]   dbi,
    output logic [BYTES*8-1:0] dout
);
    for (genvar b = 0; b < BYTES; b++) begin : g_byte
        assign dout[b*8 +: 8] = dbi[b] ? ~din[b*8 +: 8] : din[b*8 +: 8];
    end
endmodule
