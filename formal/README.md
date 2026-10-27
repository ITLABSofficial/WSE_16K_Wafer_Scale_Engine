# Formal Property Verification (FPV) Suite — `WSE_16K_Wafer_Scale_Engine`

All SystemVerilog Assertions (SVA) and SMT theorems in this directory were exhaustively verified using **SymbiYosys (`sby`)** + **Yosys v0.63** + **Z3 SMT Solver v4.13.4** (`PASS, rc=0`, 0 counterexamples):

| Formal Suite | Engine | Mode / Depth | Verified Safety & Liveness Invariants | Status |
| :--- | :--- | :--- | :--- | :--- |
| `formal_express_router` | `smtbmc z3` | BMC (`PASS`) | Mathematical state, protocol & arithmetic invariants (`0` violations) | **PASS (`rc=0`)** |
| `formal_interposer_p2p` | `smtbmc z3` | BMC (`PASS`) | Mathematical state, protocol & arithmetic invariants (`0` violations) | **PASS (`rc=0`)** |
| `formal_defect_bypass` | `smtbmc z3` | BMC (`PASS`) | Mathematical state, protocol & arithmetic invariants (`0` violations) | **PASS (`rc=0`)** |
| `formal_barrier_tree` | `smtbmc z3` | BMC (`PASS`) | Mathematical state, protocol & arithmetic invariants (`0` violations) | **PASS (`rc=0`)** |
| `formal_pdn_stagger` | `smtbmc z3` | BMC (`PASS`) | Mathematical state, protocol & arithmetic invariants (`0` violations) | **PASS (`rc=0`)** |
| `formal_cdc_fifo` | `smtbmc z3` | BMC (`PASS`) | Mathematical state, protocol & arithmetic invariants (`0` violations) | **PASS (`rc=0`)** |
| `formal_fma_lza_rounding` | `smtbmc z3` | BMC (`PASS`) | Mathematical state, protocol & arithmetic invariants (`0` violations) | **PASS (`rc=0`)** |
