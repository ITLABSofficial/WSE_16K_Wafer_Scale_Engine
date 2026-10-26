# ==============================================================================
# Makefile: Ara 16,384-Core 300mm Wafer-Scale Engine (WSE) + OpenHBM 800G v2.1 PIM
# Target: TSMC 5nm / ASAP7 7nm FinFET Predictive PDK (1.5 - 2.0 GHz)
# ==============================================================================

IVERILOG = iverilog -g2012 -DSIMULATION
VVP      = scripts/vvp_strict.sh
YOSYS    = yosys

RTL_DIR  = rtl
TB_DIR   = tb
PIM_DIR  = openhbm3_soc

RTL_CORE    = $(RTL_DIR)/ara_multicore_true_fma_6stage.sv $(RTL_DIR)/ara_systolic_tensor_unit.sv
RTL_NOC     = $(RTL_DIR)/ara_noc_fifo.sv $(RTL_DIR)/ara_noc_cdc_fifo.sv $(RTL_DIR)/ara_noc_mesh_router.sv $(RTL_DIR)/ara_noc_ni.sv $(RTL_DIR)/ara_noc_defect_bypass.sv
RTL_CLUSTER = $(RTL_DIR)/ara_tcdm_bank_interconnect.sv $(RTL_DIR)/ara_multicore_cluster.sv $(RTL_DIR)/ara_barrier_tree.sv $(RTL_DIR)/ara_pdn_stagger_ctrl.sv
RTL_MESH    = $(RTL_CORE) $(RTL_NOC) $(RTL_CLUSTER) $(RTL_DIR)/ara_host_cmd_dispatcher.sv $(RTL_DIR)/ara_wse_multi_cluster_top.sv

PIM_ALL     = $(PIM_DIR)/rtl/pim/ara_hbm3_pim_true_fma.sv \
              $(PIM_DIR)/rtl/pim/ara_hbm3_pim_decoupled_fsm.sv \
              $(PIM_DIR)/rtl/pim/ara_hbm3_interposer_p2p.sv \
              $(PIM_DIR)/rtl/pim/ara_openhbm3_soc_top.sv

RTL_ALL     = $(RTL_MESH) $(RTL_DIR)/ara_pcie_dma_engine.sv $(RTL_DIR)/ara_64core_durum_b_top.sv $(RTL_DIR)/ara_multicore_wse_hbm3_top.sv $(PIM_ALL)

.PHONY: all test test_all test_fma test_systolic test_router test_express_router test_ni test_defect test_gals test_mesh test_pim test_transformer test_wse_top test_c_driver test_cosim test_audit test_fma_deep_audit test_fsm_stress test_deep_stress test_formal test_fuzzing test_matrix_audit test_wafer_torture test_100m_torture test_10m_torture test_silicon_qual test_thermal_voltage test_192core_reticle_top synth_check clean

all: test_all

test: test_all

# 1. 6-Stage 2.0 GHz True-FMA Unit Test (IEEE-754 Bit-Exact)
test_fma:
	$(IVERILOG) -o sim_fma $(RTL_DIR)/ara_multicore_true_fma_6stage.sv $(TB_DIR)/tb_ara_multicore_fma_6stage.sv
	$(VVP) sim_fma

# 2. 16x16 Systolic Tensor Matrix Unit Test
test_systolic:
	$(IVERILOG) -o sim_systolic $(RTL_CORE) $(TB_DIR)/tb_ara_systolic_tensor_unit.sv
	$(VVP) sim_systolic

# 3. 2D-Mesh NoC Router with VC0/VC1 Skid Buffers
test_router:
	$(IVERILOG) -o sim_router $(RTL_DIR)/ara_noc_fifo.sv $(RTL_DIR)/ara_noc_mesh_router.sv $(TB_DIR)/tb_ara_noc_mesh_router.sv
	$(VVP) sim_router

# 3b. 9-Port Hierarchical Express Mesh Router (8-Hop Skip Highway)
test_express_router:
	$(IVERILOG) -o sim_express_router $(RTL_DIR)/ara_noc_fifo.sv $(RTL_DIR)/ara_noc_express_mesh_router.sv $(TB_DIR)/tb_ara_noc_express_mesh_router.sv
	$(VVP) sim_express_router

# 4. NoC Network Interface (AXI5 <-> 544-bit Flit)
test_ni:
	$(IVERILOG) -o sim_ni $(RTL_DIR)/ara_noc_fifo.sv $(RTL_DIR)/ara_noc_ni.sv $(TB_DIR)/tb_ara_noc_ni.sv
	$(VVP) sim_ni

# 5. Wafer Defect Bypass Unit (1-Cycle Deflection)
test_defect:
	$(IVERILOG) -o sim_defect $(RTL_DIR)/ara_noc_fifo.sv $(RTL_DIR)/ara_noc_defect_bypass.sv $(TB_DIR)/tb_ara_noc_defect_bypass.sv
	$(VVP) sim_defect

# 6. GALS Asynchronous Dual-Clock CDC FIFO
test_gals:
	$(IVERILOG) -o sim_gals $(RTL_DIR)/ara_noc_fifo.sv $(RTL_DIR)/ara_noc_cdc_fifo.sv $(RTL_DIR)/ara_pdn_stagger_ctrl.sv $(TB_DIR)/tb_ara_noc_cdc_gals.sv
	$(VVP) sim_gals

# 7. Multi-Tile 2D-Mesh Wafer Fabric Stress
test_mesh:
	$(IVERILOG) -o sim_wse_mesh $(RTL_MESH) $(TB_DIR)/tb_ara_wse_noc_mesh.sv
	$(VVP) sim_wse_mesh

# 8. OpenHBM 800G v2.1 Base-Die PIM Subsystem (34 Tests)
test_pim:
	$(MAKE) -C $(PIM_DIR) test_pim

# 9. End-to-End LLM Transformer Layer RTL Test
test_transformer:
	$(IVERILOG) -o sim_transformer $(RTL_ALL) $(TB_DIR)/tb_ara_llm_transformer_layer.sv
	$(VVP) sim_transformer

# 10. Top-Level 16,384-Core Wafer Engine System Test
test_wse_top:
	$(IVERILOG) -o sim_wse_top $(RTL_MESH) $(RTL_DIR)/ara_wse_16384core_top.sv $(TB_DIR)/tb_ara_wse_16384core_top.sv
	$(VVP) sim_wse_top

# 11. Bare-Metal C Host Driver Regression (48-Stack HBM, Express Router, True-FMA, LLM)
test_c_driver:
	$(MAKE) -C driver clean && $(MAKE) -C driver test

# 12. Bare-Metal HW/SW Co-Simulation (C Stimulus Generator <-> SystemVerilog RTL <-> C Checker)
test_cosim:
	gcc -O3 driver/ara_wse_cosim_generator.c driver/ara_wse_16384core_driver.c -lm -o driver/ara_wse_cosim_generator
	./driver/ara_wse_cosim_generator
	$(IVERILOG) -o sim_cosim $(RTL_DIR)/ara_noc_fifo.sv $(RTL_DIR)/ara_noc_express_mesh_router.sv $(RTL_DIR)/ara_multicore_true_fma_6stage.sv $(RTL_DIR)/ara_systolic_tensor_unit.sv $(TB_DIR)/tb_ara_wse_cosim_runner.sv
	$(VVP) sim_cosim
	gcc -O3 driver/ara_wse_cosim_checker.c -lm -o driver/ara_wse_cosim_checker
	./driver/ara_wse_cosim_checker

# 13. Bare-Metal Microscopic Cell-by-Cell PE & Congestion Audit
test_audit:
	gcc -O3 driver/ara_wse_microscopic_cell_audit.c -lm -o driver/ara_wse_microscopic_cell_audit
	./driver/ara_wse_microscopic_cell_audit gen
	$(IVERILOG) -o sim_audit $(RTL_DIR)/ara_noc_fifo.sv $(RTL_DIR)/ara_noc_express_mesh_router.sv $(RTL_DIR)/ara_noc_defect_bypass.sv $(RTL_DIR)/ara_multicore_true_fma_6stage.sv $(RTL_DIR)/ara_systolic_tensor_unit.sv $(TB_DIR)/tb_ara_wse_microscopic_cell_audit.sv
	$(VVP) sim_audit
	./driver/ara_wse_microscopic_cell_audit

# 14. Bare-Metal Microscopic Deep Arithmetic Audit (Cycle-by-cycle FP16/BF16/INT8/INT32)
test_fma_deep_audit:
	gcc -O3 -Wall driver/ara_wse_fma_deep_arithmetic_audit.c -lm -o driver/ara_wse_fma_deep_arithmetic_audit
	./driver/ara_wse_fma_deep_arithmetic_audit
	$(IVERILOG) -o sim_fma_audit $(RTL_DIR)/ara_multicore_true_fma_6stage.sv $(TB_DIR)/tb_ara_wse_fma_deep_arithmetic_audit.sv
	$(VVP) sim_fma_audit

# 15. Deep FMA & FSM Stress / Corner-Case Testbench (Arithmetic Verification)
test_fsm_stress:
	$(IVERILOG) -o sim_fsm_stress $(RTL_CORE) $(TB_DIR)/tb_deep_fma_fsm_stress.sv
	$(VVP) sim_fsm_stress

# 16. Pre-P&R 7-Axis Deep Resilience, Security & Stress Testbench (Fault Tolerance Verification)
test_deep_stress:
	$(IVERILOG) -Wall -Wno-sensitivity-entire-array -I $(RTL_DIR) -I $(PIM_DIR)/rtl -o sim_deep_stress $(TB_DIR)/tb_deep_resilience_and_security_stress.sv $(PIM_DIR)/rtl/hbm3_ctrl/ecc.sv $(RTL_DIR)/ara_noc_mesh_router.sv $(RTL_DIR)/ara_pcie_dma_engine.sv $(RTL_DIR)/ara_tcdm_bank_interconnect.sv $(RTL_DIR)/ara_pdn_stagger_ctrl.sv $(RTL_DIR)/ara_noc_fifo.sv
	$(VVP) sim_deep_stress

# 17. Formal Property Verification with SymbiYosys (SBY) & Z3 SMT Solver (15 Proven Suites)
test_formal:
	sby -f formal/formal_noc_fifo.sby
	sby -f formal/formal_noc_router.sby
	sby -f formal/formal_pcie_dma.sby
	sby -f formal/formal_true_fma.sby
	sby -f formal/formal_barrier_tree.sby
	sby -f formal/formal_cdc_fifo.sby
	sby -f formal/formal_defect_bypass.sby
	sby -f formal/formal_hbm3_pim.sby
	sby -f formal/formal_systolic.sby
	sby -f formal/formal_fma_lza_rounding.sby
	sby -f formal/formal_host_dispatcher.sby
	sby -f formal/formal_tcdm_interconnect.sby
	sby -f formal/formal_interposer_p2p.sby
	sby -f formal/formal_express_router.sby
	sby -f formal/formal_noc_ni.sby

# 18. 100,000-Cycle Constrained-Random Hardware Torture & Fuzzing Engine
test_fuzzing:
	$(IVERILOG) -Wall -Wno-sensitivity-entire-array -I $(RTL_DIR) -I $(PIM_DIR)/rtl -o sim_fuzzer $(TB_DIR)/tb_ara_constrained_random_torture_fuzzer.sv $(PIM_DIR)/rtl/hbm3_ctrl/ecc.sv $(RTL_DIR)/ara_noc_mesh_router.sv $(RTL_DIR)/ara_pcie_dma_engine.sv $(RTL_DIR)/ara_tcdm_bank_interconnect.sv $(RTL_DIR)/ara_pdn_stagger_ctrl.sv $(RTL_DIR)/ara_noc_fifo.sv
	$(VVP) sim_fuzzer

# 19. Multi-Matrix Bit-Exact Numerical & FMA Audit Engine (24 Suites, 6,144 Cells, 98,304 FMA Ops)
test_matrix_audit:
	python3 driver/ara_deep_matrix_fma_test_generator.py
	$(IVERILOG) -o sim_matrix_audit $(RTL_DIR)/ara_multicore_true_fma_6stage.sv $(RTL_DIR)/ara_systolic_tensor_unit.sv $(TB_DIR)/tb_deep_numerical_matrix_fma_audit.sv
	$(VVP) sim_matrix_audit
	python3 driver/ara_deep_matrix_fma_verifier.py

# 20. 1,000,000-Cycle Wafer-Scale Integrated Hardware Torture Engine
test_wafer_torture:
	$(IVERILOG) -g2012 -DSIMULATION -o sim_wafer_torture $(RTL_DIR)/ara_multicore_true_fma_6stage.sv $(RTL_DIR)/ara_systolic_tensor_unit.sv $(RTL_DIR)/ara_noc_fifo.sv $(RTL_DIR)/ara_noc_express_mesh_router.sv $(RTL_DIR)/ara_noc_ni.sv $(RTL_DIR)/ara_tcdm_bank_interconnect.sv $(RTL_DIR)/ara_barrier_tree.sv $(RTL_DIR)/ara_host_cmd_dispatcher.sv $(PIM_DIR)/rtl/pim/ara_hbm3_interposer_p2p.sv $(TB_DIR)/tb_wafer_scale_torture_loop.sv
	$(VVP) sim_wafer_torture

# 21. 100,000,000-Step Autonomous Wafer-Scale Torture Benchmark
test_100m_torture:
	gcc -O3 -Wall -Wextra driver/ara_wse_10m_step_torture_engine.c -o driver/ara_wse_10m_step_torture_engine
	./driver/ara_wse_10m_step_torture_engine 100000000

# 21b. 10,000,000-Step Autonomous Wafer-Scale Torture Benchmark
test_10m_torture:
	gcc -O3 -Wall -Wextra driver/ara_wse_10m_step_torture_engine.c -o driver/ara_wse_10m_step_torture_engine
	./driver/ara_wse_10m_step_torture_engine 10000000

# 22. Industry-Standard Automated Silicon Qualification & ATE Compliance
test_silicon_qual:
	$(IVERILOG) -o sim_silicon_qual $(RTL_MESH) $(RTL_DIR)/ara_pcie_dma_engine.sv $(RTL_DIR)/ara_64core_durum_b_top.sv $(TB_DIR)/tb_industry_standard_silicon_qualification.sv
	$(VVP) sim_silicon_qual

# 23. On-Die Digital Thermal Sensors (DTS), Fast Voltage Droop (DVS) & Telemetry Hub Benchmark
test_thermal_voltage:
	$(IVERILOG) -g2012 -DSIMULATION -o sim_thermal_voltage $(RTL_DIR)/ara_digital_thermal_sensor.sv $(RTL_DIR)/ara_digital_voltage_sensor.sv $(RTL_DIR)/ara_ivr_power_stage.sv $(RTL_DIR)/ara_telemetry_hub.sv $(TB_DIR)/tb_ara_thermal_voltage_sensor.sv
	$(VVP) sim_thermal_voltage

# 24. Flagship 192-Core Reticle-Limit SoC Top-Level Integration Benchmark
test_192core_reticle_top:
	$(IVERILOG) -g2012 -DSIMULATION -o sim_192core_soc $(RTL_DIR)/ara_multicore_true_fma_6stage.sv $(RTL_DIR)/ara_systolic_tensor_unit.sv $(RTL_DIR)/ara_noc_fifo.sv $(RTL_DIR)/ara_noc_cdc_fifo.sv $(RTL_DIR)/ara_noc_mesh_router.sv $(RTL_DIR)/ara_noc_ni.sv $(RTL_DIR)/ara_noc_defect_bypass.sv $(RTL_DIR)/ara_tcdm_bank_interconnect.sv $(RTL_DIR)/ara_multicore_cluster.sv $(RTL_DIR)/ara_barrier_tree.sv $(RTL_DIR)/ara_pdn_stagger_ctrl.sv $(RTL_DIR)/ara_host_cmd_dispatcher.sv $(RTL_DIR)/ara_wse_multi_cluster_top.sv $(RTL_DIR)/ara_pcie_dma_engine.sv $(RTL_DIR)/ara_digital_thermal_sensor.sv $(RTL_DIR)/ara_digital_voltage_sensor.sv $(RTL_DIR)/ara_ivr_power_stage.sv $(RTL_DIR)/ara_telemetry_hub.sv $(RTL_DIR)/ara_192core_reticle_top.sv $(TB_DIR)/tb_ara_192core_reticle_top.sv
	$(VVP) sim_192core_soc

# Run All Verified Test Suites
test_all: test_fma test_systolic test_router test_express_router test_ni test_defect test_gals test_mesh test_pim test_transformer test_wse_top test_c_driver test_cosim test_audit test_fma_deep_audit test_fsm_stress test_deep_stress test_fuzzing test_matrix_audit test_wafer_torture test_100m_torture test_silicon_qual test_thermal_voltage test_192core_reticle_top
	@echo "================================================================================"
	@echo "   >>> ALL 16,384-CORE WSE SYSTEM VERIFICATION SUITES PASSED (0 ERRORS)! <<<"
	@echo "================================================================================"

# Formal Synthesizability & Latch Checking with Yosys
synth_check:
	$(YOSYS) -p "read_verilog -sv $(RTL_MESH) $(RTL_DIR)/ara_noc_express_mesh_router.sv $(RTL_DIR)/ara_wse_16384core_top.sv; hierarchy -check -top ara_wse_16384core_top; proc; opt; check -assert"
	$(YOSYS) -p "read_verilog -sv $(RTL_DIR)/ara_noc_fifo.sv $(RTL_DIR)/ara_noc_express_mesh_router.sv; hierarchy -check -top ara_noc_express_mesh_router; check -assert"

clean:
	rm -f sim_fma sim_systolic sim_router sim_express_router sim_ni sim_defect sim_gals sim_wse_mesh sim_transformer sim_wse_top sim_cosim sim_audit sim_fma_audit sim_fsm_stress sim_deep_stress sim_fuzzing sim_matrix_audit sim_wafer_torture sim_silicon_qual sim_thermal_voltage sim_192core_soc *.vcd
	rm -f tb/cosim_*.hex tb/audit_*.hex driver/ara_wse_cosim_generator driver/ara_wse_cosim_checker driver/ara_wse_microscopic_cell_audit driver/ara_wse_fma_deep_arithmetic_audit driver/ara_wse_10m_step_torture_engine
	$(MAKE) -C driver clean
	$(MAKE) -C $(PIM_DIR) clean

