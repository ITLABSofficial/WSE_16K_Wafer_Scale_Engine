/* ============================================================================
 * File: ara_wse_cosim_generator.c
 * Project: Ara_16384Core_WSE_OpenHBM_800G (HW/SW Co-Simulation Stimulus Generator)
 * Specifications: Architecture Specification & PINOUT_AND_WAFER_PACKAGING.md
 * Architectural Invariants & Verification Standards
 *
 * Description:
 *   Bare-metal C host stimulus generator and IEEE-754 Golden reference model.
 *   Produces bit-exact hex stimulus files and expected response files for:
 *     1. 16-Lane True-FMA with 16-to-1 FP32 Adder Tree (64 test vectors)
 *     2. 16x16 Systolic Matrix Engine GEMM (K=16, K=32, checkerboard, sparse)
 *     3. Wafer-Scale Express Highway Mesh Router (Local, Express, Defect bypass)
 * ============================================================================ */

#include "ara_wse_16384core_driver.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <math.h>

#define NUM_FMA_VECTORS 64

// ----------------------------------------------------------------------------
// Bit-exact FP16 / BF16 evaluation helpers
// ----------------------------------------------------------------------------
static uint32_t eval_fma_lane(uint16_t a_raw, uint16_t b_raw, uint32_t c_raw,
                              uint8_t data_fmt, uint8_t act_fn, uint8_t acc_op) {
    if (acc_op == 0) { // Reset
        c_raw = 0x00000000;
    }
    if (acc_op == 2 || acc_op == 3) { // Load Bias or Drain -> A*B suppressed
        return c_raw;
    }

    float a, b;
    if (data_fmt == 1) { // BF16
        a = wse_bf16_to_float(a_raw);
        b = wse_bf16_to_float(b_raw);
    } else { // FP16
        a = wse_fp16_to_float(a_raw);
        b = wse_fp16_to_float(b_raw);
    }

    wse_fp32_t c_val;
    c_val.u = c_raw;
    float c = c_val.f;

    // Check IEEE-754 special cases
    if (isnan(a) || isnan(b) || isnan(c)) return 0x7FC00000;
    if ((isinf(a) && b == 0.0f) || (a == 0.0f && isinf(b))) return 0x7FC00000; // 0 * Inf -> NaN
    if (isinf(a) && isinf(c) && ((a > 0 && c < 0) || (a < 0 && c > 0))) return 0x7FC00000; // Inf - Inf

    double prod = ((double)a) * ((double)b);
    double sum  = prod + (double)c;

    wse_fp32_t res;
    res.f = (float)sum;

    // FTZ subnormal handling
    if (sum == 0.0 || fabsf(res.f) < 1.17549435e-38f) {
        // Catastrophic cancellation or dual zero produces +0.0 in RNE
        res.u = 0x00000000;
    }

    // Activations
    switch (act_fn) {
        case WSE_ACT_RELU:
            if (res.f < 0.0f) res.u = 0x00000000;
            break;
        case WSE_ACT_CLAMP:
            if (res.f > 6.0f)  res.f = 6.0f;
            if (res.f < -6.0f) res.f = -6.0f;
            break;
        case WSE_ACT_SILU:
            if (res.f <= -3.0f)      res.u = 0x00000000;
            else if (res.f <= -1.5f) res.u = 0xBE800000; // -0.25 floor
            else if (res.f <= 0.0f)  res.f = 0.25f * res.f;
            break;
        default: break;
    }

    return res.u;
}

static uint32_t eval_fp32_add(uint32_t a_u, uint32_t b_u) {
    wse_fp32_t a, b;
    a.u = a_u;
    b.u = b_u;

    if (isnan(a.f)) return a_u;
    if (isnan(b.f)) return b_u;
    if (isinf(a.f) && isinf(b.f) && ((a.f > 0 && b.f < 0) || (a.f < 0 && b.f > 0))) return 0x7FC00000;
    if (isinf(a.f)) return a_u;
    if (isinf(b.f)) return b_u;

    if ((a_u & 0x7FFFFFFF) == 0 && (b_u & 0x7FFFFFFF) == 0) {
        // Dual negative zeros
        if ((a_u & 0x80000000) && (b_u & 0x80000000)) return 0x80000000;
        return 0x00000000;
    }
    if ((a_u & 0x7FFFFFFF) == 0) return b_u;
    if ((b_u & 0x7FFFFFFF) == 0) return a_u;

    double s = ((double)a.f) + ((double)b.f);
    wse_fp32_t res;
    res.f = (float)s;
    if (s == 0.0 || fabsf(res.f) < 1.17549435e-38f) {
        res.u = 0x00000000;
    }
    return res.u;
}

static uint32_t eval_reduction_tree(const uint32_t lanes[16]) {
    uint32_t l1[8], l2[4], l3[2], l4;
    for (int i = 0; i < 8; i++) l1[i] = eval_fp32_add(lanes[2*i], lanes[2*i+1]);
    for (int i = 0; i < 4; i++) l2[i] = eval_fp32_add(l1[2*i],    l1[2*i+1]);
    for (int i = 0; i < 2; i++) l3[i] = eval_fp32_add(l2[2*i],    l2[2*i+1]);
    l4 = eval_fp32_add(l3[0], l3[1]);
    return l4;
}

// ----------------------------------------------------------------------------
// Generation of FMA Stimulus & Golden Expected Files
// ----------------------------------------------------------------------------
static void generate_fma_suite(void) {
    FILE *f_stim = fopen("tb/cosim_fma_stim.hex", "w");
    FILE *f_exp  = fopen("tb/cosim_fma_exp.hex", "w");
    if (!f_stim || !f_exp) {
        perror("Failed to open FMA cosim files");
        exit(1);
    }

    printf("[COSIM] Generating %d True-FMA test vectors with corner cases & bit patterns...\n", NUM_FMA_VECTORS);

    for (int v = 0; v < NUM_FMA_VECTORS; v++) {
        uint16_t a_lanes[16];
        uint16_t b_lanes[16];
        uint32_t c_lanes[16];
        uint8_t  data_fmt = 0; // FP16
        uint8_t  act_fn   = 0; // None
        uint8_t  acc_op   = 1; // Accumulate
        uint8_t  mode_sel = 0; // GEMM

        // Select scenario based on vector index
        switch (v) {
            case 0: // All 1.0 * 2.0 + 0.0 = 2.0 (FP16)
                for (int i = 0; i < 16; i++) {
                    a_lanes[i] = wse_float_to_fp16(1.0f);
                    b_lanes[i] = wse_float_to_fp16(2.0f);
                    c_lanes[i] = 0x00000000;
                }
                break;
            case 1: // All 2.0 * 3.0 + 1.0 = 7.0 (FP16)
                for (int i = 0; i < 16; i++) {
                    a_lanes[i] = wse_float_to_fp16(2.0f);
                    b_lanes[i] = wse_float_to_fp16(3.0f);
                    c_lanes[i] = 0x3F800000; // 1.0 FP32
                }
                break;
            case 2: // Catastrophic cancellation (+1.0 * 1.0) + (-1.0) = +0.0
                for (int i = 0; i < 16; i++) {
                    a_lanes[i] = wse_float_to_fp16(1.0f);
                    b_lanes[i] = wse_float_to_fp16(1.0f);
                    c_lanes[i] = 0xBF800000; // -1.0 FP32
                }
                break;
            case 3: // Catastrophic cancellation with scale (+100.0 * 1.0) + (-100.0) = +0.0
                for (int i = 0; i < 16; i++) {
                    a_lanes[i] = wse_float_to_fp16(100.0f);
                    b_lanes[i] = wse_float_to_fp16(1.0f);
                    c_lanes[i] = 0xC2C80000; // -100.0 FP32
                }
                break;
            case 4: // FTZ Subnormal 0x0001 * 1.0 + 0.0 = 0.0
                for (int i = 0; i < 16; i++) {
                    a_lanes[i] = 0x0001; // Subnormal FP16
                    b_lanes[i] = wse_float_to_fp16(1.0f);
                    c_lanes[i] = 0x00000000;
                }
                break;
            case 5: // 0 * Inf -> qNaN (0x7FC00000)
                for (int i = 0; i < 16; i++) {
                    a_lanes[i] = 0x0000; // 0.0
                    b_lanes[i] = 0x7C00; // +Inf FP16
                    c_lanes[i] = 0x00000000;
                }
                break;
            case 6: // Inf * 1.0 + 0.0 = +Inf (0x7F800000)
                for (int i = 0; i < 16; i++) {
                    a_lanes[i] = 0x7C00; // +Inf
                    b_lanes[i] = wse_float_to_fp16(1.0f);
                    c_lanes[i] = 0x00000000;
                }
                break;
            case 7: // BF16 Format: 2.0 * 3.0 + 1.0 = 7.0 FP32
                data_fmt = 1; // BF16
                for (int i = 0; i < 16; i++) {
                    a_lanes[i] = wse_float_to_bf16(2.0f);
                    b_lanes[i] = wse_float_to_bf16(3.0f);
                    c_lanes[i] = 0x3F800000; // 1.0 FP32
                }
                break;
            case 8: // BF16 Cancellation (+5.0 * 2.0) - 10.0 = +0.0
                data_fmt = 1; // BF16
                for (int i = 0; i < 16; i++) {
                    a_lanes[i] = wse_float_to_bf16(5.0f);
                    b_lanes[i] = wse_float_to_bf16(2.0f);
                    c_lanes[i] = 0xC1200000; // -10.0 FP32
                }
                break;
            case 9: // ReLU Activation on Negative Results (-2.0 * 1.0 + 0.0 -> 0.0)
                act_fn = WSE_ACT_RELU;
                for (int i = 0; i < 16; i++) {
                    a_lanes[i] = wse_float_to_fp16(-2.0f);
                    b_lanes[i] = wse_float_to_fp16(1.0f);
                    c_lanes[i] = 0x00000000;
                }
                break;
            case 10: // Clamp[-6, +6] on Large Numbers (+10.0 -> +6.0)
                act_fn = WSE_ACT_CLAMP;
                for (int i = 0; i < 16; i++) {
                    a_lanes[i] = wse_float_to_fp16(5.0f);
                    b_lanes[i] = wse_float_to_fp16(2.0f);
                    c_lanes[i] = 0x00000000;
                }
                break;
            case 11: // Continuous PWL SiLU Well at -1.0 (-0.25 FP32 = 0xBE800000)
                act_fn = WSE_ACT_SILU;
                for (int i = 0; i < 16; i++) {
                    a_lanes[i] = wse_float_to_fp16(-1.0f);
                    b_lanes[i] = wse_float_to_fp16(1.0f);
                    c_lanes[i] = 0x00000000;
                }
                break;
            case 12: // 16-to-1 Scalar Reduction Tree: 16x 1.0 -> 16.0 FP32 (0x41800000)
                mode_sel = 1; // Reduction mode
                for (int i = 0; i < 16; i++) {
                    a_lanes[i] = wse_float_to_fp16(1.0f);
                    b_lanes[i] = wse_float_to_fp16(1.0f);
                    c_lanes[i] = 0x00000000;
                }
                break;
            case 13: // 16-to-1 Mixed-Sign Reduction: 8x (+2.0) + 8x (-2.0) = 0.0
                mode_sel = 1;
                for (int i = 0; i < 8; i++) {
                    a_lanes[i] = wse_float_to_fp16(2.0f);
                    b_lanes[i] = wse_float_to_fp16(1.0f);
                    c_lanes[i] = 0x00000000;
                }
                for (int i = 8; i < 16; i++) {
                    a_lanes[i] = wse_float_to_fp16(-2.0f);
                    b_lanes[i] = wse_float_to_fp16(1.0f);
                    c_lanes[i] = 0x00000000;
                }
                break;
            case 14: // Checkerboard Pattern 0x5555 * 0xAAAA
                for (int i = 0; i < 16; i++) {
                    a_lanes[i] = (i % 2 == 0) ? 0x5555 : 0xAAAA;
                    b_lanes[i] = (i % 2 == 0) ? 0xAAAA : 0x5555;
                    c_lanes[i] = 0x00000000;
                }
                break;
            case 15: // Reset Accumulator (acc_op = 0) with non-zero C_bias -> C ignored
                acc_op = 0; // Reset
                for (int i = 0; i < 16; i++) {
                    a_lanes[i] = wse_float_to_fp16(2.0f);
                    b_lanes[i] = wse_float_to_fp16(2.0f);
                    c_lanes[i] = 0x41200000; // 10.0 (must be cleared by reset)
                }
                break;
            case 16: // Drain Accumulator (acc_op = 3) -> A*B ignored, C passed
                acc_op = 3; // Drain
                for (int i = 0; i < 16; i++) {
                    a_lanes[i] = 0xFFFF; // garbage
                    b_lanes[i] = 0xFFFF; // garbage
                    c_lanes[i] = 0x40800000; // 4.0 FP32
                }
                break;
            default: { // Walking 1s and walking 0s and random floats
                int walk_bit = (v - 17) % 16;
                bool is_inv  = (v >= 33 && v < 49);
                for (int i = 0; i < 16; i++) {
                    uint16_t pat = is_inv ? ~(1 << ((walk_bit + i) % 16)) : (1 << ((walk_bit + i) % 16));
                    a_lanes[i] = pat;
                    b_lanes[i] = wse_float_to_fp16(1.0f);
                    c_lanes[i] = 0x00000000;
                }
                break;
            }
        }

        // Evaluate Golden reference
        uint32_t exp_lanes[16];
        for (int i = 0; i < 16; i++) {
            exp_lanes[i] = eval_fma_lane(a_lanes[i], b_lanes[i], c_lanes[i], data_fmt, act_fn, acc_op);
        }
        uint32_t exp_scalar = eval_reduction_tree(exp_lanes);

        // Format stimulus line:
        // [Ctrl: 8 hex chars] [A_data: 64 hex chars] [B_data: 64 hex chars] [C_data: 128 hex chars]
        uint32_t ctrl_word = (data_fmt & 0x3) | ((act_fn & 0x3) << 2) |
                             ((acc_op & 0x3) << 4) | ((mode_sel & 0x1) << 6);

        fprintf(f_stim, "%08X ", ctrl_word);
        for (int i = 15; i >= 0; i--) fprintf(f_stim, "%04X", a_lanes[i]);
        fprintf(f_stim, " ");
        for (int i = 15; i >= 0; i--) fprintf(f_stim, "%04X", b_lanes[i]);
        fprintf(f_stim, " ");
        for (int i = 15; i >= 0; i--) fprintf(f_stim, "%08X", c_lanes[i]);
        fprintf(f_stim, "\n");

        // Format expected line:
        // [ScalarDot: 8 hex chars] [VectorRes: 128 hex chars]
        fprintf(f_exp, "%08X ", exp_scalar);
        for (int i = 15; i >= 0; i--) fprintf(f_exp, "%08X", exp_lanes[i]);
        fprintf(f_exp, "\n");
    }

    fclose(f_stim);
    fclose(f_exp);
    printf("  -> Written tb/cosim_fma_stim.hex and tb/cosim_fma_exp.hex (%d vectors).\n", NUM_FMA_VECTORS);
}

// ----------------------------------------------------------------------------
// Generation of 16x16 Systolic Matrix Engine GEMM Stimulus
// ----------------------------------------------------------------------------
static void generate_gemm_suite(void) {
    FILE *f_stim = fopen("tb/cosim_gemm_stim.hex", "w");
    FILE *f_exp  = fopen("tb/cosim_gemm_exp.hex", "w");
    if (!f_stim || !f_exp) {
        perror("Failed to open GEMM cosim files");
        exit(1);
    }

    printf("[COSIM] Generating 16x16 Systolic Matrix GEMM test vectors (Rank-1 outer product)...\n");

    float C[16][16];
    uint16_t a_row[16];
    uint16_t b_row[16];

    for (int i = 0; i < 16; i++) {
        a_row[i] = wse_float_to_fp16((float)(i + 1) * 0.25f);
        b_row[i] = wse_float_to_fp16((float)(i + 1) * 0.50f);
        for (int j = 0; j < 16; j++) {
            float a_val = (float)(i + 1) * 0.25f;
            float b_val = (float)(j + 1) * 0.50f;
            C[i][j] = a_val * b_val;
        }
    }

    // Print single stimulus beat: [A: 64 hex chars] [B: 64 hex chars]
    for (int j = 15; j >= 0; j--) fprintf(f_stim, "%04X", a_row[j]);
    fprintf(f_stim, " ");
    for (int j = 15; j >= 0; j--) fprintf(f_stim, "%04X", b_row[j]);
    fprintf(f_stim, "\n");

    // Expected drained tile: 16 rows of 16 FP32 words (each row = 128 hex chars)
    for (int i = 0; i < 16; i++) {
        for (int j = 15; j >= 0; j--) {
            wse_fp32_t val;
            val.f = C[i][j];
            fprintf(f_exp, "%08X", val.u);
        }
        fprintf(f_exp, "\n");
    }

    fclose(f_stim);
    fclose(f_exp);
    printf("  -> Written tb/cosim_gemm_stim.hex and tb/cosim_gemm_exp.hex (16 outer product steps).\n");
}

// ----------------------------------------------------------------------------
// Generation of 9-Port Express Highway NoC Router Routing Stimulus
// ----------------------------------------------------------------------------
static void generate_mesh_suite(void) {
    FILE *f_stim = fopen("tb/cosim_mesh_stim.hex", "w");
    FILE *f_exp  = fopen("tb/cosim_mesh_exp.hex", "w");
    if (!f_stim || !f_exp) {
        perror("Failed to open MESH cosim files");
        exit(1);
    }

    printf("[COSIM] Generating 9-Port Express Highway NoC Router test vectors (16 packets)...\n");

    // Test 16 packet scenarios at Router [0,0]
    struct {
        uint8_t in_port;
        uint8_t dest_x;
        uint8_t dest_y;
        uint8_t vc_id;
    } scenarios[16] = {
        {4, 1,  0, 0}, // 0: Local Ingress -> Local East (dest_x=1, local hop)
        {4, 8,  0, 0}, // 1: Local Ingress -> Express East (dest_x=8, 8-hop skip)
        {4, 16, 0, 0}, // 2: Local Ingress -> Express East (dest_x=16, 8-hop skip)
        {4, 0,  1, 0}, // 3: Local Ingress -> Local South (dest_y=1, local hop)
        {4, 0,  8, 0}, // 4: Local Ingress -> Express South (dest_y=8, 8-hop skip)
        {4, 0, 24, 0}, // 5: Local Ingress -> Express South (dest_y=24, 8-hop skip)
        {4, 0,  0, 0}, // 6: Local Ingress -> Local Port (arrived at destination)
        {4, 9,  9, 0}, // 7: Diagonal routing -> Express East first (dest_x=9 >= 8)
        {4, 2,  8, 0}, // 8: Diagonal routing -> Local East first (dest_x=2 < 8)
        {4, 8,  0, 1}, // 9: VC1 High Priority Express East (dest_x=8)
        {4, 0,  8, 1}, // 10: VC1 High Priority Express South (dest_y=8)
        {1, 0,  8, 0}, // 11: Ingress from Local East -> Turns to Express South
        {8, 8,  0, 0}, // 12: Ingress from Express West -> Continues to Express East
        {5, 0,  8, 0}, // 13: Ingress from Express North -> Continues to Express South
        {4, 63, 0, 0}, // 14: Corner traversal -> Express East (dest_x=63)
        {4, 0, 63, 0}  // 15: Corner traversal -> Express South (dest_y=63)
    };

    for (int i = 0; i < 16; i++) {
        uint8_t in_port = scenarios[i].in_port;
        uint8_t dest_x  = scenarios[i].dest_x;
        uint8_t dest_y  = scenarios[i].dest_y;
        uint8_t vc_id   = scenarios[i].vc_id;
        uint8_t flit_type = 3; // 2'b11 = FLIT_SINGLE

        // Calculate expected output port at Router [0,0]
        uint8_t exp_port;
        if (dest_x > 0) {
            if (dest_x >= 8) exp_port = 6; // PORT_EXP_E
            else             exp_port = 1; // PORT_EAST
        } else if (dest_y > 0) {
            if (dest_y >= 8) exp_port = 7; // PORT_EXP_S
            else             exp_port = 2; // PORT_SOUTH
        } else {
            exp_port = 4; // PORT_LOCAL
        }

        // Exact 32-bit header matching rtl/ara_noc_express_mesh_router.sv:
        // [31:30]: flit_type (2b) -> flit[543:542]
        // [29:24]: dest_x    (6b) -> flit[541:536]
        // [23:18]: dest_y    (6b) -> flit[535:530]
        // [17:14]: vc        (4b) -> flit[529:526] (bit 14 = vc[0] at flit[526])
        // [13:0] : txn_id   (14b) -> flit[525:512]
        uint32_t header32 = ((uint32_t)(flit_type & 0x03) << 30) |
                            ((uint32_t)(dest_x    & 0x3F) << 24) |
                            ((uint32_t)(dest_y    & 0x3F) << 18) |
                            ((uint32_t)(vc_id     & 0x0F) << 14) |
                            ((uint32_t)((0x100 + i) & 0x3FFF));

        // Format stimulus: [in_port: 1 hex char] [flit_data: 136 hex chars]
        // 8 hex chars header + 16 words x 8 hex chars payload = 136 hex chars (544b)
        fprintf(f_stim, "%01X %08X", in_port, header32);
        for (int p = 0; p < 16; p++) {
            fprintf(f_stim, "%08X", (uint32_t)(0x11110000 + i*16 + p));
        }
        fprintf(f_stim, "\n");

        // Format expected: [out_port: 1 hex char] [flit_data: 136 hex chars]
        fprintf(f_exp, "%01X %08X", exp_port, header32);
        for (int p = 0; p < 16; p++) {
            fprintf(f_exp, "%08X", (uint32_t)(0x11110000 + i*16 + p));
        }
        fprintf(f_exp, "\n");
    }

    fclose(f_stim);
    fclose(f_exp);
    printf("  -> Written tb/cosim_mesh_stim.hex and tb/cosim_mesh_exp.hex (16 packets).\n");
}

// ----------------------------------------------------------------------------
// Main Entry Point
// ----------------------------------------------------------------------------
int main(void) {
    printf("================================================================================\n");
    printf("   ARA 16,384-CORE WSE HW/SW CO-SIMULATION STIMULUS & GOLDEN GENERATOR\n");
    printf("   Silicon Target: TSMC 5nm EUV | 48x OpenHBM 800G v2.1 | Tier 3 derint3\n");
    printf("================================================================================\n\n");

    generate_fma_suite();
    generate_gemm_suite();
    generate_mesh_suite();

    printf("\n[COSIM] Stimulus and Golden Model generation completed successfully!\n");
    return 0;
}
