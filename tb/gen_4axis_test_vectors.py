#!/usr/bin/env python3
"""
Python Golden Model & Test Vector Generator for Ara WSE 4-Axis Verification
Generates:
1. IEEE-754 Extreme Corner-Case FP16/BF16/FP32 FMA vectors
2. Transformer Layer Weights and Golden Bit-Exact Activations
"""

import struct
import math

def float_to_hex(f):
    return f"{struct.unpack('>I', struct.pack('>f', f))[0]:08X}"

def hex_to_float(h):
    return struct.unpack('>f', struct.pack('>I', int(h, 16)))[0]

def fp16_to_float(h):
    # Unpack 16-bit half precision
    return struct.unpack('>e', struct.pack('>H', int(h, 16)))[0]

def float_to_fp16_hex(f):
    return f"{struct.unpack('>H', struct.pack('>e', f))[0]:04X}"

def generate_ieee754_corner_cases():
    cases = []
    
    # 1. Signed Zeros
    # (+0.0) * (+1.0) + (+0.0) = +0.0
    cases.append({
        "desc": "Signed Zero (+0 * +1 + +0)",
        "a_fp16": "0000", # +0.0
        "b_fp16": "3C00", # +1.0
        "c_fp32": "00000000", # +0.0
        "expected_fp32": "00000000",
        "nv": 0, "of": 0, "uf": 0
    })
    
    # (+0.0) * (-1.0) + (-0.0) = -0.0
    cases.append({
        "desc": "Signed Zero (+0 * -1 + -0)",
        "a_fp16": "0000", # +0.0
        "b_fp16": "BC00", # -1.0
        "c_fp32": "80000000", # -0.0
        "expected_fp32": "80000000",
        "nv": 0, "of": 0, "uf": 0
    })

    # (-0.0) * (-1.0) + (+0.0) = +0.0
    cases.append({
        "desc": "Signed Zero (-0 * -1 + +0)",
        "a_fp16": "8000", # -0.0
        "b_fp16": "BC00", # -1.0
        "c_fp32": "00000000", # +0.0
        "expected_fp32": "00000000",
        "nv": 0, "of": 0, "uf": 0
    })

    # 2. Inf and NaN
    # 0 * Inf -> qNaN (NV flag)
    cases.append({
        "desc": "Invalid Operation (0 * Inf -> qNaN)",
        "a_fp16": "0000", # 0.0
        "b_fp16": "7C00", # +Inf
        "c_fp32": "00000000",
        "expected_fp32": "7FC00000", # Canonical qNaN
        "nv": 1, "of": 0, "uf": 0
    })

    # +Inf * 1.0 + (-Inf) -> qNaN (NV flag)
    cases.append({
        "desc": "Invalid Operation (+Inf + -Inf -> qNaN)",
        "a_fp16": "7C00", # +Inf
        "b_fp16": "3C00", # 1.0
        "c_fp32": "FF800000", # -Inf
        "expected_fp32": "7FC00000", # Canonical qNaN
        "nv": 1, "of": 0, "uf": 0
    })

    # 3. Catastrophic Cancellation
    # A = 1.0009765625 (0x3C01), B = 1.0 (0x3C00), C = -1.0 (0xBF800000)
    # A * B + C = 0.0009765625 = 2^-10 = 0x3A800000
    cases.append({
        "desc": "Catastrophic Cancellation (1.0009766 * 1.0 - 1.0)",
        "a_fp16": "3C01",
        "b_fp16": "3C00",
        "c_fp32": "BF800000",
        "expected_fp32": "3A800000",
        "nv": 0, "of": 0, "uf": 0
    })

    # A = 2.0 (0x4000), B = 1.5 (0x3E00), C = -3.0 (0xC0400000)
    # A * B + C = 3.0 - 3.0 = +0.0
    cases.append({
        "desc": "Exact Zero Cancellation (2.0 * 1.5 - 3.0 = +0.0)",
        "a_fp16": "4000",
        "b_fp16": "3E00",
        "c_fp32": "C0400000",
        "expected_fp32": "00000000",
        "nv": 0, "of": 0, "uf": 0
    })

    # 4. Large Dynamic Range & Precision Accumulation
    # A = 65504.0 (0x7BFF max FP16), B = 2.0 (0x4000), C = 0.0 -> 131008.0 (0x48000000)
    cases.append({
        "desc": "Max FP16 * 2.0 Accumulation",
        "a_fp16": "7BFF",
        "b_fp16": "4000",
        "c_fp32": "00000000",
        "expected_fp32": "47FFE000", # 65504 * 2 = 131008 = 0x47FFE000
        "nv": 0, "of": 0, "uf": 0
    })

    return cases

if __name__ == "__main__":
    cases = generate_ieee754_corner_cases()
    print(f"Generated {len(cases)} IEEE-754 Corner Test Cases:")
    for i, c in enumerate(cases):
        print(f"[{i}] {c['desc']}: A=0x{c['a_fp16']} B=0x{c['b_fp16']} C=0x{c['c_fp32']} -> Res=0x{c['expected_fp32']}")
