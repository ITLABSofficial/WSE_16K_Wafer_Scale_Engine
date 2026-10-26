`timescale 1ns/1ps
// ECC unit verification: random data + intentional 0, 1, and 2-bit error injection
// to verify Hamming(39,32) SECDED functionality.
module tb_ecc;
    logic [31:0] din, dout;
    logic [6:0]  ecc;
    logic        corrected, uncorrectable;
    logic [38:0] corrupt;  // error injection bit mask across {ecc, din}

    ecc_encode u_enc(.din(din), .ecc(ecc));

    logic [31:0] rx_din;
    logic [6:0]  rx_ecc;
    ecc_decode u_dec(.din(rx_din), .ecc(rx_ecc), .dout(dout),
                      .err_corrected(corrected), .err_uncorrectable(uncorrectable));

    int errors = 0, n = 0;

    task automatic check(input logic [31:0] d, input int flip_a, input int flip_b);
        logic [38:0] combo, combo_rx;
        n++;
        din = d;
        #1;
        combo = {ecc, din};              // [38:32]=ecc, [31:0]=din
        combo_rx = combo;
        if (flip_a >= 0) combo_rx[flip_a] = ~combo_rx[flip_a];
        if (flip_b >= 0) combo_rx[flip_b] = ~combo_rx[flip_b];
        rx_ecc = combo_rx[38:32];
        rx_din = combo_rx[31:0];
        #1;
        if (flip_b >= 0) begin
            // Double-bit error: MUST be DETECTED (uncorrectable).
            // Data is not required to be corrected under SECDED specification.
            if (!uncorrectable) begin
                $display("[ECC-ERROR] %0d: Double-bit error (a=%0d b=%0d) NOT DETECTED! din=%h",
                          n, flip_a, flip_b, d);
                errors++;
            end
        end else if (flip_a == 38) begin
            // Special case: bit 38 = overall parity bit (P).
            // P does not participate in Hamming syndrome (only bits 0..37 compute syndrome).
            // When P alone is flipped, syndrome remains 0, meaning 'corrected' does not assert
            // (no data bits corrupted). This is expected standard SECDED behavior.
            if (dout !== d) begin
                $display("[ECC-ERROR] %0d: Parity bit alone flipped corrupted data! din=%h dout=%h",
                          n, d, dout);
                errors++;
            end
            if (corrected || uncorrectable) begin
                $display("[ECC-ERROR] %0d: Parity-bit alone flipped caused false flag assertion! c=%b u=%b",
                          n, corrected, uncorrectable);
                errors++;
            end
        end else if (flip_a >= 0) begin
            // Single-bit error: MUST be CORRECTED, output data matches original
            if (!corrected || dout !== d) begin
                $display("[ECC-ERROR] %0d: Single-bit (pos=%0d) not corrected! din=%h dout=%h corrected=%b",
                          n, flip_a, d, dout, corrected);
                errors++;
            end
            if (uncorrectable) begin
                $display("[ECC-ERROR] %0d: Single-bit error mistakenly flagged uncorrectable!", n);
                errors++;
            end
        end else begin
            // Fault-free: both flags deasserted, data identical
            if (corrected || uncorrectable || dout !== d) begin
                $display("[ECC-ERROR] %0d: Fault-free data wrong flag/data! din=%h dout=%h c=%b u=%b",
                          n, d, dout, corrected, uncorrectable);
                errors++;
            end
        end
    endtask

    initial begin
        // Fault-free baseline
        check(32'h0000_0000, -1, -1);
        check(32'hFFFF_FFFF, -1, -1);
        check(32'hDEAD_BEEF, -1, -1);
        check(32'hA5A5_5A5A, -1, -1);

        // Every single-bit position (0..38: 32 data + 7 ecc)
        for (int p = 0; p < 39; p++)
            check(32'h1234_5678 ^ (32'h9ABC_DEF0 * p), p, -1);

        // Random double-bit error combinations across bit positions
        for (int a = 0; a < 39; a += 3)
            for (int b = a+1; b < 39; b += 5)
                check(32'hC0FF_EE00 + a*7 + b, a, b);

        $display("TB_ECC: n=%0d error=%0d", n, errors);
        if (errors == 0) $display("TB_ECC: PASS");
        else              $display("TB_ECC: FAIL");
        $finish;
    end
endmodule
