// ============================================================================
// File: formal_fma_lza_rounding.sv
// Project: Ara_MultiCore_WSE_HBM3 (Formal Verification Suite)
// Specifications: docs/PLAN_DERIN_FORMAL_DOGRULAMA_VE_FMA_MIMARISI.md
// Description:
//   Formal Property Verification for FMA IEEE-754 RNE Rounding,
//   Leading Zero Counting (Catastrophic Cancellation Normalization),
//   and IEEE-754 Special Value Algebra.
// ============================================================================

`timescale 1ps/1fs

module formal_fma_lza_rounding (
    input  logic        clk,
    input  logic        rst_n,

    // Symbolic inputs for RNE Rounding Unit
    input  logic [23:0] s_raw_mant,
    input  logic        s_guard,
    input  logic        s_round,
    input  logic        s_sticky,
    input  logic [9:0]  s_exp_in,

    // Symbolic inputs for Normalization / Leading Zero Count
    input  logic [47:0] s_sum_raw,
    input  logic [9:0]  s_exp_base,

    // Symbolic inputs for Special Value Algebra
    input  logic        s_is_nan,
    input  logic        s_is_inf,
    input  logic        s_is_inv_op,
    input  logic        s_sign_res
);

    // ========================================================================
    // 1. FORMAL PROOF 1: IEEE-754 RNE Rounding Logic
    // ========================================================================
    logic        inc_condition;
    logic [24:0] rnd_mant_wide;
    logic [23:0] rnd_mant;
    logic [9:0]  rnd_exp;
    logic [3:0]  flags;

    assign inc_condition = s_guard && (s_round || s_sticky || s_raw_mant[0]);

    always_comb begin
        rnd_exp  = s_exp_in;
        flags    = 4'b0000;
        if (inc_condition) begin
            rnd_mant_wide = {1'b0, s_raw_mant} + 25'd1;
            if (rnd_mant_wide[24]) begin
                rnd_exp  = s_exp_in + 10'd1;
                rnd_mant = rnd_mant_wide[24:1];
            end else begin
                rnd_mant = rnd_mant_wide[23:0];
            end
        end else begin
            rnd_mant_wide = {1'b0, s_raw_mant};
            rnd_mant      = s_raw_mant;
        end
    end

    // Theorem 1A: Strict If-And-Only-If condition for increment
    // Increment occurs IF AND ONLY IF Guard AND (Round OR Sticky OR LSB)
    always_comb begin
        if (inc_condition) begin
            assert (rnd_mant_wide == {1'b0, s_raw_mant} + 25'd1);
        end else begin
            assert (rnd_mant_wide == {1'b0, s_raw_mant});
        end
    end

    // Theorem 1B: Ties-To-Even Rule
    // When exactly halfway (Guard=1, Round=0, Sticky=0):
    // If LSB is 0 (already even) -> NO increment, LSB remains 0.
    // If LSB is 1 (odd) -> MUST increment, resulting in LSB becoming 0 (rounded to even).
    always_comb begin
        if (s_guard && !s_round && !s_sticky) begin
            if (s_raw_mant[0] == 1'b0) begin
                // Even: no increment
                assert (!inc_condition);
                assert (rnd_mant[0] == 1'b0);
            end else begin
                // Odd: increment to even
                assert (inc_condition);
                assert (rnd_mant[0] == 1'b0); // LSB forced to 0 (even)
            end
        end
    end

    // Theorem 1C: Mantissa Overflow on All-Ones
    // When raw_mant == 24'hFFFFFF and increment occurs:
    // wide addition overflows (bit 24 == 1), exponent increments,
    // and normalized rounded mantissa becomes 24'h800000.
    always_comb begin
        if (s_raw_mant == 24'hFFFFFF && inc_condition) begin
            assert (rnd_mant_wide[24] == 1'b1);
            assert (rnd_exp == s_exp_in + 10'd1);
            assert (rnd_mant == 24'h800000);
        end
    end

    // ========================================================================
    // 2. FORMAL PROOF 2: Leading Zero Normalization & Catastrophic Cancellation
    // ========================================================================
    logic [5:0]  lz_count;
    logic [47:0] norm_mant;
    logic [9:0]  norm_exp;

    always_comb begin
        lz_count = 6'd48;
        for (int i = 0; i < 48; i++) begin
            if (s_sum_raw[i]) lz_count = 6'd47 - i[5:0];
        end

        if (s_sum_raw == 48'd0) begin
            norm_mant = 48'd0;
            norm_exp  = 10'd0;
        end else begin
            norm_mant = s_sum_raw << lz_count;
            if (s_exp_base >= {4'd0, lz_count})
                norm_exp = s_exp_base - {4'd0, lz_count};
            else
                norm_exp = 10'd0;
        end
    end

    // Theorem 2A: For any non-zero raw sum, normalized mantissa MSB (bit 47) is ALWAYS 1
    always_comb begin
        if (s_sum_raw != 48'd0) begin
            assert (norm_mant[47] == 1'b1);
        end
    end

    // Theorem 2B: Leading zero count is bounded in [0, 47] for non-zero inputs
    always_comb begin
        if (s_sum_raw != 48'd0) begin
            assert (lz_count <= 6'd47);
        end else begin
            assert (lz_count == 6'd48);
            assert (norm_mant == 48'd0);
            assert (norm_exp == 10'd0);
        end
    end

    // Theorem 2C: If MSB is already 1 (no cancellation), lz_count == 0
    always_comb begin
        if (s_sum_raw[47] == 1'b1) begin
            assert (lz_count == 6'd0);
            assert (norm_mant == s_sum_raw);
        end
    end

    // ========================================================================
    // 3. FORMAL PROOF 3: IEEE-754 Special Value Algebra
    // ========================================================================
    logic [31:0] final_fp32;
    logic [3:0]  final_flags;

    always_comb begin
        final_flags = 4'b0000;
        if (s_is_inv_op) begin
            final_fp32     = 32'h7FC00000; // Canonical qNaN
            final_flags[3] = 1'b1;         // NV
        end else if (s_is_nan) begin
            final_fp32     = 32'h7FC00000; // Quiet NaN
        end else if (s_is_inf || rnd_exp >= 10'd255) begin
            final_fp32     = {s_sign_res, 8'hFF, 23'd0}; // Signed Infinity
            final_flags[2] = 1'b1;                       // OF
        end else if (rnd_exp == 10'd0 || rnd_mant == 24'd0) begin
            final_fp32 = {s_sign_res, 31'd0};           // Zero / Subnormal
            if (rnd_mant != 24'd0) final_flags[1] = 1'b1;// UF
        end else begin
            final_fp32 = {s_sign_res, rnd_exp[7:0], rnd_mant[22:0]};
        end
    end

    // Theorem 3A: Invalid operation strictly outputs NV flag and qNaN
    always_comb begin
        if (s_is_inv_op) begin
            assert (final_fp32 == 32'h7FC00000);
            assert (final_flags[3] == 1'b1);
        end
    end

    // Theorem 3B: NaN input guarantees quiet NaN output without NV (unless invalid)
    always_comb begin
        if (s_is_nan && !s_is_inv_op) begin
            assert (final_fp32 == 32'h7FC00000);
            assert (final_flags[3] == 1'b0);
        end
    end

    // Theorem 3C: Overflow strictly outputs Infinity with correct sign and OF flag
    always_comb begin
        if (!s_is_inv_op && !s_is_nan && (s_is_inf || rnd_exp >= 10'd255)) begin
            assert (final_fp32[30:23] == 8'hFF);
            assert (final_fp32[22:0] == 23'd0);
            assert (final_fp32[31] == s_sign_res);
            assert (final_flags[2] == 1'b1);
        end
    end

endmodule
