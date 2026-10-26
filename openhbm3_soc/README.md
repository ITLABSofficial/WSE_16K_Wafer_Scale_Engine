# OpenHBM3 SoC v2.1 Base-Die PIM Subsystem
**JEDEC HBM3/HBM3e Controller + 1024-Pin PHY + Base-Die Decoupled PIM Acceleration**

---

## Overview

The **OpenHBM3 SoC Base-Die PIM Subsystem** integrates high-bandwidth memory control with near-memory compute units directly situated on the base logic die (Logic Base Die) beneath 3D-stacked DRAM. It features **Decoupled PIM acceleration** (True-FMA, GEMM, FlashAttention, and RMSNorm kernels), delivering ultra-high memory bandwidth efficiency and low latency for large-scale AI acceleration.

---

## 1. Architectural Layers

The subsystem is composed of 4 tightly coupled hardware layers:

```text
┌────────────────────────────── OPENHBM3 SoC v2.1 IP ─────────────────────────────┐
│                                                                                 │
│  1. BASE-DIE DECOUPLED PIM ENGINE (`rtl/pim/`)                                  │
│     ├─ 16-Lane True IEEE-754 FP16/FP32/BF16/INT8 FMA                            │
│     ├─ Decoupled Command Dispatcher & Autonomous FSM                            │
│     ├─ 16-to-1 Binary Adder Tree (Dot-Product Reduction)                        │
│     ├─ Fused Piecewise-Linear SiLU / ReLU Activation Unit                       │
│     └─ 2.5D CoWoS Interposer Direct Peer-to-Peer (P2P) Bridge                   │
│                                                                                 │
│  2. JEDEC JESD238 DRAM CONTROLLER (`rtl/hbm3_ctrl/`)                            │
│     ├─ 16 Physical Channels / 32 Pseudo-Channels (PC)                           │
│     ├─ Dual-Sub-Lane Real DDR Datapath (2x 32-bit/cycle)                        │
│     ├─ Hamming(39,32) SECDED On-Die ECC and Dynamic DBI                         │
│     └─ Parametric `ROWBITS` (128 GB 8-Hi Stack Support)                         │
│                                                                                 │
│  3. 800G HIGH-SPEED STREAMING FABRIC (`rtl/hbm3_800g/`)                         │
│     ├─ 32-Entry Asynchronous Ingress Queues                                     │
│     ├─ 32-to-16 Two-Stage Round-Robin Arbitration                               │
│     └─ 2:1 Gearbox and Gray-Coded CDC Crossings                                 │
│                                                                                 │
│  4. 1024-PIN DIGITAL SerDes PHY FRONT-END (`rtl/phy/`)                          │
│     ├─ Dynamic Bit-Slip Deskew Across 64 Data Lanes                             │
│     └─ Autonomous 2-Phase Link Training FSM                                     │
└─────────────────────────────────────────────────────────────────────────────────┘
```

---

## 2. Directory Structure
* `rtl/pim/`: Base-die PIM RTL (`ara_hbm3_pim_true_fma.sv`, `ara_hbm3_pim_decoupled_fsm.sv`, `ara_hbm3_interposer_p2p.sv`, `ara_openhbm3_soc_top.sv`).
* `rtl/hbm3_ctrl/`: JEDEC HBM3 memory controller, bank state trackers, ECC, and DBI engines.
* `rtl/hbm3_800g/`: 800 GB/s high-speed streaming, CDC, and scheduling modules.
* `rtl/phy/`: 1024-pin digital PHY front-end.
* `tb/`: Comprehensive 34-test PIM integration verification suite (`tb/tb_ara_hbm3_pim.sv`).

---

## 3. Verification & Testing
To compile and execute the complete 34-test integration testbench:
```bash
make test_pim
```
**Expected Outcome:** `ALL 34 ARA_OPENHBM3_SOC TESTS PASSED SUCCESSFULLY! ZERO BUGS, ZERO TIMING HAZARDS, 100% COMPLIANT!`
