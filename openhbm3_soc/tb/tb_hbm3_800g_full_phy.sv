// END-TO-END PIPELINE TESTBENCH: host -> ... -> DQ pins.
// Purpose: Verifies complete pipeline connectivity and active DQ pin driving.
`timescale 1ps/1ps
`include "hbm3_800g_defs.svh"
module tb_hbm3_800g_full_phy;
    localparam int CORE_PS = 400;    // 2.5 GHz
    localparam int PHY_PS  = 870;    // ~1.15 GHz
    localparam int WCK_PS  = 218;    // ~4.6 GHz  (~PHY/4)

    logic core_clk = 0, phy_clk = 0, wck = 0;
    always #(CORE_PS/2) core_clk = ~core_clk;
    always #(PHY_PS/2)  phy_clk  = ~phy_clk;
    always #(WCK_PS/2)  wck      = ~wck;

    logic core_rst_n = 0, phy_rst_n = 0, wck_rst_n = 0, phy_cal_done = 0;
    logic [HBM3_CHANNELS-1:0] core_flush = '0;
    logic [HBM3_HOST_LANES-1:0] host_valid = '0, host_ready;
    logic [HBM3_HOST_LANES*HBM3_ADDR_BITS-1:0] host_addr = '0;
    logic [HBM3_HOST_LANES*HBM3_HOST_DATA_BITS-1:0] host_wdata = '0;
    logic [HBM3_DQ_BITS-1:0] dq_rise, dq_fall;
    logic [HBM3_CHANNELS-1:0] dq_active;
    logic [HBM3_CHANNELS*HBM3_GEAR_RATIO-1:0] phy_mask;
    logic [HBM3_CHANNELS*HBM3_GEAR_RATIO*HBM3_ADDR_BITS-1:0] phy_addr;

    hbm3_800g_full_phy_top dut (
        .core_clk, .phy_clk, .wck, .core_rst_n, .phy_rst_n, .wck_rst_n,
        .phy_cal_done, .core_flush, .host_valid, .host_ready,
        .host_addr, .host_wdata, .dq_rise, .dq_fall, .dq_active,
        .phy_mask, .phy_addr);

    // DQ pin toggle counter to monitor signal transitions
    logic [HBM3_DQ_BITS-1:0] prev_r, prev_f;
    longint unsigned toggles = 0;
    int active_beats = 0;
    integer i, seed = 32'h1234_5678;
    always_ff @(posedge wck) begin
        if (wck_rst_n) begin
            toggles <= toggles + $countones(dq_rise ^ prev_r)
                                + $countones(dq_fall ^ prev_f);
            prev_r  <= dq_rise; prev_f <= dq_fall;
            if (|dq_active) active_beats <= active_beats + 1;
        end
    end

    // Host traffic generation
    always_ff @(posedge core_clk) begin
        if (core_rst_n) begin
            host_valid <= '1;
            for (i = 0; i < HBM3_HOST_LANES; i = i + 1) begin
                seed = seed * 1103515245 + 12345;
                host_addr[i*HBM3_ADDR_BITS +: HBM3_ADDR_BITS] <= seed;
                host_addr[i*HBM3_ADDR_BITS + 4 +: 4] <= seed[19:16];
                host_wdata[i*HBM3_HOST_DATA_BITS +: HBM3_HOST_DATA_BITS] <= {8{seed}};
            end
        end
    end

    initial begin
        #(20*CORE_PS);
        core_rst_n = 1; phy_rst_n = 1; wck_rst_n = 1;
        #(10*PHY_PS); phy_cal_done = 1;
        #(4000*WCK_PS);
        $display("=== FULL TOP PIPELINE (host -> DQ pins) ===");
        $display("  DQ pin count         : %0d  (%0d channels x %0d pins)",
                 HBM3_DQ_BITS, HBM3_CHANNELS, HBM3_DQ_BITS_PER_CHANNEL);
        $display("  DQ toggle count      : %0d", toggles);
        $display("  active data beats    : %0d", active_beats);
        if (toggles == 0 || active_beats == 0) begin
            $display("HBM3_800G_FULL_PHY: FAILED -- DQ pins not driven");
            $fatal(1, "");
        end
        $display("  host accept (ready)  : %0d lanes", $countones(host_ready));
        $display("HBM3_800G_FULL_PHY: PASS -- pipeline connected, DQ pins driven");
        $finish;
    end
endmodule
