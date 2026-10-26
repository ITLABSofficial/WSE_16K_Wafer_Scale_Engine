#!/usr/bin/env python3
"""
Deep Bit-Exact Verifier & Analytical Audit Reporter
Project: Ara_MultiCore_WSE_HBM3
Tier: /derint3 (Super-Intelligence Kernel & Formal Arithmetic)

Performs deep analytical inspection of all 6,144 matrix accumulator words
produced by the Ara 16x16 Systolic Matrix Engine and True-FMA hardware:
- Verifies raw bit patterns (RTL vs Golden XOR)
- Decodes IEEE-754 bitfields: Sign [31], Exponent [30:23], Mantissa [22:0]
- Computes ULP (Units in Last Place) error and relative numerical error
- Formats a comprehensive audit report across all 24 test suites
"""

import struct
import math
import numpy as np

def hex_to_float(h):
    u = int(h, 16)
    return struct.unpack('>f', struct.pack('>I', u))[0]

def hex_to_uint32(h):
    return int(h, 16)

def decode_fp32(u32):
    sign = (u32 >> 31) & 1
    exp  = (u32 >> 23) & 0xFF
    mant = u32 & 0x7FFFFF
    if exp == 255:
        kind = "NaN" if mant != 0 else ("+Inf" if sign == 0 else "-Inf")
    elif exp == 0:
        kind = "Zero" if mant == 0 else "Subnormal"
    else:
        kind = "Normal"
    return sign, exp, mant, kind

def main():
    print("=" * 80)
    print("   ARA WSE 16x16 SYSTOLIC ENGINE & TRUE-FMA: DEEP BITWISE AUDIT REPORT")
    print("=" * 80)

    # Load manifests
    manifest_lines = []
    with open("tb/deep_matrix_manifest.txt", "r") as f:
        for line in f:
            if line.startswith("TEST"):
                manifest_lines.append(line.strip())

    # Load golden and rtl output
    with open("tb/deep_matrix_golden.hex", "r") as f:
        gold_lines = [l.strip() for l in f if l.strip()]
    with open("tb/deep_matrix_rtl_output.hex", "r") as f:
        rtl_lines = [l.strip() for l in f if l.strip()]

    assert len(gold_lines) == len(rtl_lines), f"Line mismatch: {len(gold_lines)} vs {len(rtl_lines)}"
    assert len(gold_lines) == 24 * 16, f"Expected 384 lines, got {len(gold_lines)}"

    total_words = 0
    exact_matches = 0
    ulp_mismatches = 0
    sign_flips = 0
    exp_mismatches = 0
    max_abs_err = 0.0
    max_ulp_diff = 0

    print(f"Total Test Suites: {len(manifest_lines)}")
    print(f"Total Matrix Rows: {len(gold_lines)}")
    print(f"Total Accumulator Cells (FP32 words): {len(gold_lines) * 16}\n")

    for t_idx, manifest in enumerate(manifest_lines):
        # Extract metadata
        parts = manifest.split()
        test_name = parts[3]
        desc = " ".join(parts[7:])

        t_words = 0
        t_matches = 0
        t_max_ulp = 0

        for r in range(16):
            row_idx = t_idx * 16 + r
            gold_hex_row = gold_lines[row_idx]
            rtl_hex_row = rtl_lines[row_idx]

            # Parse 16 FP32 words (each 8 hex chars, reversed because lane 15 downto 0)
            gold_words = [gold_hex_row[i:i+8] for i in range(0, 128, 8)]
            rtl_words = [rtl_hex_row[i:i+8] for i in range(0, 128, 8)]

            # Convert to lane 0..15 order
            gold_words = list(reversed(gold_words))
            rtl_words = list(reversed(rtl_words))

            for c in range(16):
                total_words += 1
                t_words += 1

                g_u32 = hex_to_uint32(gold_words[c])
                r_u32 = hex_to_uint32(rtl_words[c])

                if g_u32 == r_u32:
                    exact_matches += 1
                    t_matches += 1
                else:
                    g_s, g_e, g_m, _ = decode_fp32(g_u32)
                    r_s, r_e, r_m, _ = decode_fp32(r_u32)

                    if g_s != r_s: sign_flips += 1
                    if g_e != r_e: exp_mismatches += 1

                    ulp_diff = abs(int(r_u32) - int(g_u32))
                    max_ulp_diff = max(max_ulp_diff, ulp_diff)
                    t_max_ulp = max(t_max_ulp, ulp_diff)
                    ulp_mismatches += 1

                    g_f = hex_to_float(gold_words[c])
                    r_f = hex_to_float(rtl_words[c])
                    abs_err = abs(r_f - g_f)
                    max_abs_err = max(max_abs_err, abs_err)

        status_str = "PASS (100.0% Bit-Exact)" if t_matches == t_words else f"FAIL ({t_words - t_matches} diffs)"
        print(f"[{t_idx+1:02d}/24] {test_name:<30} | Cells: {t_matches}/{t_words} | Max ULP: {t_max_ulp} | {status_str}")

    print("\n" + "=" * 80)
    print("   COMPREHENSIVE NUMERICAL & HARDWARE PRECISION METRICS")
    print("=" * 80)
    print(f"   Total FP32 Accumulator Cells Tested:   {total_words:,}")
    print(f"   Bit-Exact Identical Matches (XOR == 0): {exact_matches:,} ({exact_matches/total_words*100.0:.4f}%)")
    print(f"   ULP Mismatches:                         {ulp_mismatches}")
    print(f"   Sign Bit Inversions:                    {sign_flips}")
    print(f"   Exponent Discrepancies:                 {exp_mismatches}")
    print(f"   Maximum ULP Discrepancy:                {max_ulp_diff} ULP")
    print(f"   Maximum Absolute Numerical Error:       {max_abs_err:.2e}")
    print("=" * 80)

    if exact_matches == total_words:
        print("   >>> MATHEMATICAL & HARDWARE BIT-EXACT CONGRUENCE CERTIFIED (0 ERRORS)! <<<")
    else:
        print("   >>> AUDIT FAILED WITH DISCREPANCIES <<<")
    print("=" * 80)

if __name__ == "__main__":
    main()
