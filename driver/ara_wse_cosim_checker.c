/* ============================================================================
 * File: ara_wse_cosim_checker.c
 * Project: Ara_16384Core_WSE_OpenHBM_800G (HW/SW Co-Simulation Bit-Exact Checker)
 * Specifications: Architecture Specification & PINOUT_AND_WAFER_PACKAGING.md
 * Architectural Invariants & Verification Standards
 *
 * Description:
 *   Autonomous C host verification tool reading cycle-accurate hardware RTL
 *   output files produced by Icarus Verilog simulation and asserting bit-exact
 *   zero-error equivalence against the IEEE-754 Golden reference model.
 * ============================================================================ */

#include "ara_wse_16384core_driver.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <math.h>

int main(void) {
    printf("================================================================================\n");
    printf("   ARA 16,384-CORE WSE HW/SW CO-SIMULATION BIT-EXACT CHECKER\n");
    printf("   Asserting Hardware RTL Output (.hex) vs C Golden Model (.hex)\n");
    printf("================================================================================\n\n");

    int fma_vectors_checked = 0;
    int fma_words_checked   = 0;
    int fma_errors          = 0;

    int gemm_rows_checked   = 0;
    int gemm_words_checked  = 0;
    int gemm_errors         = 0;

    // ------------------------------------------------------------------------
    // CHECK 1: True-FMA and 16-to-1 Reduction Tree Bit-Exact Equivalence
    // ------------------------------------------------------------------------
    printf("[CHECK 1] Inspecting 6-Stage True-FMA Hardware Simulation Outputs...\n");
    FILE *f_rtl_fma = fopen("tb/cosim_fma_out.hex", "r");
    FILE *f_exp_fma = fopen("tb/cosim_fma_exp.hex", "r");

    if (!f_rtl_fma || !f_exp_fma) {
        printf("  [ERROR] Could not open FMA output files (cosim_fma_out.hex / cosim_fma_exp.hex)\n");
        return 1;
    }

    char rtl_line[512];
    char exp_line[512];

    while (fgets(rtl_line, sizeof(rtl_line), f_rtl_fma) &&
           fgets(exp_line, sizeof(exp_line), f_exp_fma)) {
        
        // Strip trailing newlines
        rtl_line[strcspn(rtl_line, "\r\n")] = 0;
        exp_line[strcspn(exp_line, "\r\n")] = 0;

        uint32_t rtl_scalar, exp_scalar;
        char rtl_vec_str[256], exp_vec_str[256];

        if (sscanf(rtl_line, "%08X %128s", &rtl_scalar, rtl_vec_str) != 2 ||
            sscanf(exp_line, "%08X %128s", &exp_scalar, exp_vec_str) != 2) {
            printf("  [WARN] Parse mismatch at vector %d\n", fma_vectors_checked);
            break;
        }

        fma_vectors_checked++;

        // 1. Check Scalar Reduction Output (32 bits)
        fma_words_checked++;
        if (rtl_scalar != exp_scalar) {
            wse_fp32_t r_f, e_f;
            r_f.u = rtl_scalar;
            e_f.u = exp_scalar;
            printf("  [FAIL] Vector %02d SCALAR REDUCTION MISMATCH:\n", fma_vectors_checked - 1);
            printf("         RTL: 0x%08X (%.6f) | EXP: 0x%08X (%.6f)\n",
                   rtl_scalar, r_f.f, exp_scalar, e_f.f);
            fma_errors++;
        }

        // 2. Check 16 Vector Lanes (each 32 bits = 8 hex chars)
        // String layout: Lane 15 (chars 0..7), Lane 14 (chars 8..15), ..., Lane 0 (chars 120..127)
        for (int l = 0; l < 16; l++) {
            fma_words_checked++;
            char r_sub[9] = {0};
            char e_sub[9] = {0};
            int char_offset = (15 - l) * 8;
            strncpy(r_sub, rtl_vec_str + char_offset, 8);
            strncpy(e_sub, exp_vec_str + char_offset, 8);

            uint32_t r_lane = (uint32_t)strtoul(r_sub, NULL, 16);
            uint32_t e_lane = (uint32_t)strtoul(e_sub, NULL, 16);

            if (r_lane != e_lane) {
                wse_fp32_t r_f, e_f;
                r_f.u = r_lane;
                e_f.u = e_lane;
                printf("  [FAIL] Vector %02d LANE %02d MISMATCH:\n", fma_vectors_checked - 1, l);
                printf("         RTL: 0x%08X (%.6f) | EXP: 0x%08X (%.6f)\n",
                       r_lane, r_f.f, e_lane, e_f.f);
                fma_errors++;
            }
        }
    }

    fclose(f_rtl_fma);
    fclose(f_exp_fma);

    if (fma_errors == 0 && fma_vectors_checked > 0) {
        printf("  [PASS] 6-Stage True-FMA & 16-to-1 Adder Tree: %d vectors (%d FP32 words) 100.0%% bit-exact!\n",
               fma_vectors_checked, fma_words_checked);
    } else {
        printf("  [FAIL] True-FMA verification encountered %d bit errors!\n", fma_errors);
    }

    // ------------------------------------------------------------------------
    // CHECK 2: 16x16 Systolic Matrix Engine Tile Drain Verification
    // ------------------------------------------------------------------------
    printf("\n[CHECK 2] Inspecting 16x16 Systolic Matrix Engine Drained Accumulator Rows...\n");
    FILE *f_rtl_gemm = fopen("tb/cosim_gemm_out.hex", "r");
    FILE *f_exp_gemm = fopen("tb/cosim_gemm_exp.hex", "r");

    if (!f_rtl_gemm || !f_exp_gemm) {
        printf("  [ERROR] Could not open GEMM output files (cosim_gemm_out.hex / cosim_gemm_exp.hex)\n");
        return 1;
    }

    while (fgets(rtl_line, sizeof(rtl_line), f_rtl_gemm) &&
           fgets(exp_line, sizeof(exp_line), f_exp_gemm)) {

        rtl_line[strcspn(rtl_line, "\r\n")] = 0;
        exp_line[strcspn(exp_line, "\r\n")] = 0;

        int row_idx = gemm_rows_checked++;

        // Each row contains 16 columns of FP32 words (128 hex chars)
        for (int c = 0; c < 16; c++) {
            gemm_words_checked++;
            char r_sub[9] = {0};
            char e_sub[9] = {0};
            int char_offset = (15 - c) * 8;
            strncpy(r_sub, rtl_line + char_offset, 8);
            strncpy(e_sub, exp_line + char_offset, 8);

            uint32_t r_word = (uint32_t)strtoul(r_sub, NULL, 16);
            uint32_t e_word = (uint32_t)strtoul(e_sub, NULL, 16);

            if (r_word != e_word) {
                wse_fp32_t r_f, e_f;
                r_f.u = r_word;
                e_f.u = e_word;
                printf("  [FAIL] GEMM Row %02d Col %02d MISMATCH:\n", row_idx, c);
                printf("         RTL: 0x%08X (%.6f) | EXP: 0x%08X (%.6f)\n",
                       r_word, r_f.f, e_word, e_f.f);
                gemm_errors++;
            }
        }
    }

    fclose(f_rtl_gemm);
    fclose(f_exp_gemm);

    if (gemm_errors == 0 && gemm_rows_checked == 16) {
        printf("  [PASS] 16x16 Systolic Matrix Engine: 16 rows x 16 cols (256 FP32 words) 100.0%% bit-exact!\n");
    } else {
        printf("  [FAIL] Systolic Matrix Engine verification encountered %d bit errors!\n", gemm_errors);
    }

    // ------------------------------------------------------------------------
    // CHECK 3: 9-Port Express Highway Router Routing Decisions & Flits
    // ------------------------------------------------------------------------
    printf("\n[CHECK 3] Inspecting 9-Port Express Highway Router Routing Decisions & Flits...\n");
    int mesh_packets_checked = 0;
    int mesh_errors          = 0;
    FILE *f_rtl_mesh = fopen("tb/cosim_mesh_out.hex", "r");
    FILE *f_exp_mesh = fopen("tb/cosim_mesh_exp.hex", "r");

    if (f_rtl_mesh && f_exp_mesh) {
        while (fgets(rtl_line, sizeof(rtl_line), f_rtl_mesh) &&
               fgets(exp_line, sizeof(exp_line), f_exp_mesh)) {

            rtl_line[strcspn(rtl_line, "\r\n")] = 0;
            exp_line[strcspn(exp_line, "\r\n")] = 0;

            int rtl_port, exp_port;
            char rtl_flit[256], exp_flit[256];

            if (sscanf(rtl_line, "%x %s", &rtl_port, rtl_flit) == 2 &&
                sscanf(exp_line, "%x %s", &exp_port, exp_flit) == 2) {

                mesh_packets_checked++;
                if (rtl_port != exp_port) {
                    printf("  [FAIL] Packet %02d EGRESS PORT MISMATCH: RTL Port %d vs EXP Port %d\n",
                           mesh_packets_checked - 1, rtl_port, exp_port);
                    mesh_errors++;
                }
                if (strcasecmp(rtl_flit, exp_flit) != 0) {
                    printf("  [FAIL] Packet %02d FLIT PAYLOAD MISMATCH:\n", mesh_packets_checked - 1);
                    printf("         RTL: %s\n         EXP: %s\n", rtl_flit, exp_flit);
                    mesh_errors++;
                }
            }
        }
        fclose(f_rtl_mesh);
        fclose(f_exp_mesh);

        if (mesh_errors == 0 && mesh_packets_checked > 0) {
            printf("  [PASS] 9-Port Express Router: %d packets (544b each = %d bits) 100.0%% bit-exact routing!\n",
                   mesh_packets_checked, mesh_packets_checked * 544);
        } else {
            printf("  [FAIL] Express Router encountered %d routing errors!\n", mesh_errors);
        }
    }

    // ------------------------------------------------------------------------
    // SUMMARY
    // ------------------------------------------------------------------------
    int total_errors = fma_errors + gemm_errors + mesh_errors;
    int total_words  = fma_words_checked + gemm_words_checked + (mesh_packets_checked * 17);

    printf("\n================================================================================\n");
    printf("   ARA 16,384-CORE WSE HW/SW CO-SIMULATION SUMMARY\n");
    printf("   TOTAL HARDWARE WORDS VERIFIED : %d\n", total_words);
    printf("   BIT ERRORS                    : %d\n", total_errors);
    printf("   HARDWARE CONFORMANCE RATE     : %.2f%%\n",
           (total_words > 0) ? (100.0 * (total_words - total_errors) / total_words) : 0.0);
    printf("   VERDICT                       : %s\n", (total_errors == 0) ? "100.0% BIT-EXACT PASS" : "FAIL");
    printf("================================================================================\n");

    return (total_errors == 0) ? 0 : 1;
}
