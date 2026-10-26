/* ============================================================================
 * File: ara_wse_16384core_driver.h
 * Project: Ara_16384Core_WSE_OpenHBM_800G (300mm Wafer-Scale Engine Bare-Metal Driver)
 * Specifications: Architecture Specification & PINOUT_AND_WAFER_PACKAGING.md
 * Architectural Invariants & Verification Standards
 *
 * Description:
 *   Bare-metal C header defining the hardware register map, physical address
 *   space, bit-exact arithmetic formats, and job dispatch APIs for the
 *   16,384-Core 300mm Monolithic Wafer-Scale Engine with 48x OpenHBM 800G v2.1.
 * ============================================================================ */

#ifndef ARA_WSE_16384CORE_DRIVER_H
#define ARA_WSE_16384CORE_DRIVER_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ----------------------------------------------------------------------------
// 1. Wafer-Scale Physical Architecture Constants
// ----------------------------------------------------------------------------
#define WSE_TOTAL_CORES           16384
#define WSE_GRID_X                64
#define WSE_GRID_Y                64
#define WSE_ACTIVE_TILES          4096
#define WSE_CORES_PER_TILE        4
#define WSE_FABRICATED_GRID_X     66
#define WSE_FABRICATED_GRID_Y     66
#define WSE_SPARE_TILES           260

#define WSE_NUM_HBM_STACKS        48
#define WSE_HBM_CHANNELS_PER_STK  16
#define WSE_HBM_BANKS_PER_CH      16
#define WSE_BYTES_PER_STACK       (24ULL * 1024ULL * 1024ULL * 1024ULL) // 24 GB / stack
#define WSE_TOTAL_HBM_BYTES       (WSE_NUM_HBM_STACKS * WSE_BYTES_PER_STACK) // 1,152 GB

#define WSE_EXPRESS_STEP          8   // 8-Hop Highway skip distance
#define WSE_PDN_IVR_DOMAINS       1024 // 1,024 GaN IVR 48V->0.8V buck converters
#define WSE_CPO_OPTICAL_LINKS     16   // 16x 800G Co-Packaged Optics transceivers

// ----------------------------------------------------------------------------
// 2. Host MMIO Register Offsets (Bar0 Map)
// ----------------------------------------------------------------------------
#define WSE_REG_CMD_CTRL          0x0000 // Bit 0: START, Bit 1: ABORT, Bit 2: IRQ_ACK
#define WSE_REG_TENSOR_A_LO       0x0004 // Tensor A Host Physical Address [31:0]
#define WSE_REG_TENSOR_B_LO       0x0008 // Tensor B Host Physical Address [31:0]
#define WSE_REG_TENSOR_C_LO       0x000C // Tensor C Host Physical Address [31:0]
#define WSE_REG_DIM_MN            0x0010 // [31:16] = Dim M, [15:0] = Dim N
#define WSE_REG_DIM_K             0x0014 // [31:0]  = Dim K
#define WSE_REG_OPCODE_CFG        0x0018 // [3:0]=Opcode, [5:4]=ActFn, [7:6]=DataFmt, [8]=ModeSel
#define WSE_REG_PDN_CFG           0x001C // [7:0]=StepDelay, [8]=StaggerDown
#define WSE_REG_STATUS            0x0020 // [0]=Busy, [1]=Done, [2]=Error, [6:3]=Flags
#define WSE_REG_EXPRESS_HOPS      0x0024 // Total Express Highway Hops Logged
#define WSE_REG_LOCAL_HOPS        0x0028 // Total Local Mesh Hops Logged

// Opcodes
#define WSE_OP_IDLE               0x00
#define WSE_OP_GEMM               0x01
#define WSE_OP_PIM_ATTENTION      0x02
#define WSE_OP_SWIGLU             0x03
#define WSE_OP_RMSNORM            0x04
#define WSE_OP_REDUCTION          0x05

// Data Formats
#define WSE_FMT_FP16              0x00
#define WSE_FMT_BF16              0x01
#define WSE_FMT_INT8              0x02
#define WSE_FMT_INT32             0x03

// Activation Functions
#define WSE_ACT_NONE              0x00
#define WSE_ACT_RELU              0x01
#define WSE_ACT_CLAMP             0x02
#define WSE_ACT_SILU              0x03

// ----------------------------------------------------------------------------
// 3. Bit-Exact IEEE-754 Data Unions
// ----------------------------------------------------------------------------
typedef union {
    float    f;
    uint32_t u;
} wse_fp32_t;

typedef union {
    uint16_t u;
} wse_fp16_t;

typedef union {
    uint16_t u;
} wse_bf16_t;

// ----------------------------------------------------------------------------
// 4. Memory Address Slicing Helper Struct
// ----------------------------------------------------------------------------
typedef struct {
    uint8_t  stack_id;      // 0..47 (48 HBM stacks)
    uint8_t  channel_id;    // 0..15 (16 channels / stack)
    uint8_t  bank_id;       // 0..15 (16 banks / channel)
    uint32_t row_addr;      // Row address (17 bits)
    uint16_t col_addr;      // Column address (6 bits)
    uint8_t  byte_offset;   // 0..31 (256-bit burst beat)
} wse_hbm_coord_t;

// Function Prototypes
wse_hbm_coord_t wse_decode_hbm_addr(uint64_t phys_addr);
uint64_t        wse_encode_hbm_addr(const wse_hbm_coord_t *coord);

uint16_t        wse_float_to_fp16(float val);
float           wse_fp16_to_float(uint16_t val);
uint16_t        wse_float_to_bf16(float val);
float           wse_bf16_to_float(uint16_t val);

uint32_t        wse_true_fma_fp32(uint16_t a_fp16, uint16_t b_fp16, uint32_t c_fp32, uint8_t act_fn);
uint32_t        wse_reduce_16lanes_fp32(const uint32_t lanes[16]);

int             wse_calc_mesh_route(int src_x, int src_y, int dst_x, int dst_y,
                                    int *out_local_hops, int *out_express_hops);

#ifdef __cplusplus
}
#endif

#endif // ARA_WSE_16384CORE_DRIVER_H
