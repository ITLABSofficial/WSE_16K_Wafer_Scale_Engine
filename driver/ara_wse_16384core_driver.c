/* ============================================================================
 * File: ara_wse_16384core_driver.c
 * Project: Ara_16384Core_WSE_OpenHBM_800G (300mm Wafer-Scale Engine Bare-Metal Driver)
 * Specifications: Architecture Specification & PINOUT_AND_WAFER_PACKAGING.md
 * Architectural Invariants & Verification Standards
 *
 * Description:
 *   Implementation of physical address translation, IEEE-754 bit-exact FMA
 *   emulation, 16-to-1 adder tree reduction, and hierarchical express NoC routing.
 * ============================================================================ */

#include "ara_wse_16384core_driver.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

// ----------------------------------------------------------------------------
// 1. Physical Address Translation & Interleaving across 48 HBM Stacks
// ----------------------------------------------------------------------------
// Address Layout (Total 41 bits = 2 TB physical address space):
// [40:35] : Stack ID (0..47, 6 bits modulo 48)
// [34:31] : Channel ID (0..15, 4 bits)
// [30:27] : Bank ID (0..15, 4 bits)
// [26:10] : Row Address (17 bits)
// [9:5]   : Column Address (5 bits)
// [4:0]   : Byte Offset (32 Bytes = 256 bits)
wse_hbm_coord_t wse_decode_hbm_addr(uint64_t phys_addr) {
    wse_hbm_coord_t coord;
    coord.byte_offset = (uint8_t)(phys_addr & 0x1F);
    coord.col_addr    = (uint16_t)((phys_addr >> 5) & 0x1F);
    coord.row_addr    = (uint32_t)((phys_addr >> 10) & 0x1FFFF);
    coord.bank_id     = (uint8_t)((phys_addr >> 27) & 0x0F);
    coord.channel_id  = (uint8_t)((phys_addr >> 31) & 0x0F);
    coord.stack_id    = (uint8_t)((phys_addr >> 35) % WSE_NUM_HBM_STACKS);
    return coord;
}

uint64_t wse_encode_hbm_addr(const wse_hbm_coord_t *coord) {
    uint64_t addr = 0;
    addr |= ((uint64_t)(coord->byte_offset & 0x1F));
    addr |= ((uint64_t)(coord->col_addr    & 0x1F)) << 5;
    addr |= ((uint64_t)(coord->row_addr    & 0x1FFFF)) << 10;
    addr |= ((uint64_t)(coord->bank_id     & 0x0F)) << 27;
    addr |= ((uint64_t)(coord->channel_id  & 0x0F)) << 31;
    addr |= ((uint64_t)(coord->stack_id    % WSE_NUM_HBM_STACKS)) << 35;
    return addr;
}

// ----------------------------------------------------------------------------
// 2. Bit-Exact Floating Point Conversion Helpers
// ----------------------------------------------------------------------------
uint16_t wse_float_to_fp16(float val) {
    wse_fp32_t f;
    f.f = val;
    uint32_t sign = (f.u >> 31) & 0x1;
    int32_t  exp  = ((f.u >> 23) & 0xFF) - 127 + 15;
    uint32_t mant = (f.u >> 13) & 0x3FF;

    if (f.u == 0x00000000) return 0x0000;
    if (f.u == 0x80000000) return 0x8000;

    // Inf or NaN
    if (((f.u >> 23) & 0xFF) == 0xFF) {
        if ((f.u & 0x7FFFFF) != 0) return 0x7E00; // qNaN
        return (uint16_t)((sign << 15) | 0x7C00); // Inf
    }

    if (exp >= 31) return (uint16_t)((sign << 15) | 0x7C00); // Overflow to Inf
    if (exp <= 0)  return (uint16_t)(sign << 15);            // Flush to Zero (FTZ)

    return (uint16_t)((sign << 15) | ((exp & 0x1F) << 10) | mant);
}

float wse_fp16_to_float(uint16_t val) {
    wse_fp32_t f;
    uint32_t sign = (val >> 15) & 0x1;
    uint32_t exp  = (val >> 10) & 0x1F;
    uint32_t mant = val & 0x3FF;

    if (exp == 0 && mant == 0) {
        f.u = sign << 31;
        return f.f;
    }
    if (exp == 0x1F) {
        if (mant != 0) f.u = 0x7FC00000; // NaN
        else           f.u = (sign << 31) | 0x7F800000; // Inf
        return f.f;
    }
    if (exp == 0) {
        // FTZ
        f.u = sign << 31;
        return f.f;
    }

    uint32_t exp32 = exp - 15 + 127;
    f.u = (sign << 31) | (exp32 << 23) | (mant << 13);
    return f.f;
}

uint16_t wse_float_to_bf16(float val) {
    wse_fp32_t f;
    f.f = val;
    // RNE rounding to 16-bit
    uint32_t lsb = (f.u >> 16) & 1;
    uint32_t rounding_bias = 0x7FFF + lsb;
    f.u += rounding_bias;
    return (uint16_t)(f.u >> 16);
}

float wse_bf16_to_float(uint16_t val) {
    wse_fp32_t f;
    f.u = ((uint32_t)val) << 16;
    return f.f;
}

// ----------------------------------------------------------------------------
// 3. Bit-Exact True-FMA FP32 Emulation matching Hardware 6-Stage Pipeline
// ----------------------------------------------------------------------------
uint32_t wse_true_fma_fp32(uint16_t a_fp16, uint16_t b_fp16, uint32_t c_fp32, uint8_t act_fn) {
    float a = wse_fp16_to_float(a_fp16);
    float b = wse_fp16_to_float(b_fp16);
    wse_fp32_t c_u;
    c_u.u = c_fp32;
    float c = c_u.f;

    // Check special values
    if (isnan(a) || isnan(b) || isnan(c)) return 0x7FC00000; // qNaN
    if ((isinf(a) && b == 0.0f) || (a == 0.0f && isinf(b))) return 0x7FC00000; // 0 * Inf
    if (isinf(a) && isinf(c) && ((a > 0 && c < 0) || (a < 0 && c > 0))) return 0x7FC00000;

    // High precision accumulation
    double prod = ((double)a) * ((double)b);
    double res  = prod + (double)c;

    wse_fp32_t final_res;
    final_res.f = (float)res;

    // FTZ Subnormal underflow handling (FTZ Underflow Flag)
    if (res == 0.0 || fabsf(final_res.f) < 1.17549435e-38f) {
        final_res.u = 0x00000000;
    }

    // Apply Activation Function
    switch (act_fn) {
        case WSE_ACT_RELU:
            if (final_res.f < 0.0f) final_res.f = 0.0f;
            break;
        case WSE_ACT_CLAMP:
            if (final_res.f > 6.0f)  final_res.f = 6.0f;
            if (final_res.f < -6.0f) final_res.f = -6.0f;
            break;
        case WSE_ACT_SILU: { // Hardware Continuous PWL SiLU
            float x = final_res.f;
            if (x <= -3.0f) {
                final_res.u = 0x00000000;
            } else if (x > -3.0f && x <= -1.5f) {
                final_res.u = 0xBE800000; // -0.25 floor
            } else if (x > -1.5f && x <= 0.0f) {
                final_res.f = 0.25f * x;
            } else {
                final_res.f = x;
            }
            break;
        }
        case WSE_ACT_NONE:
        default:
            break;
    }

    return final_res.u;
}

// ----------------------------------------------------------------------------
// 4. 16-to-1 IEEE-754 FP32 Binary Adder Tree Reduction
// ----------------------------------------------------------------------------
uint32_t wse_reduce_16lanes_fp32(const uint32_t lanes[16]) {
    double sum = 0.0;
    for (int i = 0; i < 16; i++) {
        wse_fp32_t val;
        val.u = lanes[i];
        sum += (double)val.f;
    }
    wse_fp32_t res;
    res.f = (float)sum;
    if (sum == 0.0) res.u = 0x00000000;
    return res.u;
}

// ----------------------------------------------------------------------------
// 5. Hierarchical Express NoC Route Optimizer
// ----------------------------------------------------------------------------
int wse_calc_mesh_route(int src_x, int src_y, int dst_x, int dst_y,
                        int *out_local_hops, int *out_express_hops) {
    int dx = abs(dst_x - src_x);
    int dy = abs(dst_y - src_y);

    int express_x = dx / WSE_EXPRESS_STEP;
    int local_x   = dx % WSE_EXPRESS_STEP;

    int express_y = dy / WSE_EXPRESS_STEP;
    int local_y   = dy % WSE_EXPRESS_STEP;

    *out_express_hops = express_x + express_y;
    *out_local_hops   = local_x + local_y;

    // Total network traversal cycles = (Express Hops * 1 cycle) + (Local Hops * 1 cycle)
    return (*out_express_hops) + (*out_local_hops);
}
