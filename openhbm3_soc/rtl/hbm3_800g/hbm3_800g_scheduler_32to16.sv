// Deadlock-free 32-input to 16-channel request scheduler.
//
// Each output represents one physical 64-bit HBM channel (two HBM3 pseudo
// channels behind the external PHY). A request is selected only when its
// target egress is ready; there are no cross-channel resource dependencies.
// Round-robin arbitration prevents starvation, and a different-bank request
// is preferred when there is a choice, reducing repeated-bank pressure.
//
// SELECTION IMPLEMENTATION NOTE (2026-08-25): the winning candidate per
// channel is picked by a barrel-rotate + balanced priority-merge tree
// (ROT_STAGES = log2(HBM3_HOST_LANES) levels each), not a 32-iteration
// sequentially-dependent scan. The earlier scan wrote `found_any`/
// `grant_lane` as a loop-carried accumulation across all 32 lanes, which
// forces synthesis to build exactly what was written: an up-to-32-deep
// ripple of dependent priority logic. Real ASAP7 synthesis measured this at
// 17.94 MHz against a 2.5 GHz target -- the combinational depth, not the
// process node, was the wall (architectural specification). The rotate+tree
// structure below computes the identical round-robin-with-bank-preference
// result in ~2*log2(N) levels instead of N, still single-cycle/no added
// latency (see docs/HBM3_800G_ARCHITECTURE.md and the scheduler testbenches
// for the semantics this must preserve exactly).
`include "hbm3_800g_defs.svh"

module hbm3_800g_scheduler_32to16 (
    input  logic clk_core,
    input  logic rst_n,
    input  logic [HBM3_HOST_LANES-1:0] host_valid,
    output logic [HBM3_HOST_LANES-1:0] host_ready,
    input  logic [HBM3_HOST_LANES*HBM3_ADDR_BITS-1:0] host_addr,
    input  logic [HBM3_HOST_LANES*HBM3_HOST_DATA_BITS-1:0] host_wdata,

    output logic [HBM3_CHANNELS-1:0] egress_valid,
    input  logic [HBM3_CHANNELS-1:0] egress_ready,
    output logic [HBM3_CHANNELS*HBM3_ADDR_BITS-1:0] egress_addr,
    output logic [HBM3_CHANNELS*HBM3_HOST_DATA_BITS-1:0] egress_wdata,
    output logic [HBM3_CHANNELS*4-1:0] egress_bank
);
    localparam int LANE_BITS  = $clog2(HBM3_HOST_LANES);
    localparam int ROT_STAGES = $clog2(HBM3_HOST_LANES);

    // The rotate+tree structure below requires HBM3_HOST_LANES to be an
    // exact power of two (it is: 32, by construction in hbm3_800g_defs.svh).
    // Fail elaboration loudly rather than silently building wrong hardware
    // if that ever changes.
    initial
        if ((1 << LANE_BITS) != HBM3_HOST_LANES)
            $fatal(1, "hbm3_800g_scheduler_32to16: HBM3_HOST_LANES (%0d) must be a power of two",
                   HBM3_HOST_LANES);

    logic [LANE_BITS-1:0] rr_ptr [0:HBM3_CHANNELS-1];
    logic [3:0] last_bank [0:HBM3_CHANNELS-1];

    // ---- Pipeline Registers (Stage B) ----
    // Arbitration decision is performed in Stage A and registered.
    // Egress data is multiplexed in Stage B from this registered index,
    // decoupling the 256-bit 32:1 mux from the arbiter decision tree.
    logic [HBM3_CHANNELS-1:0]  sel_valid;
    logic [LANE_BITS-1:0]      sel_lane [0:HBM3_CHANNELS-1];
    // Address is latched in Stage A (compact 35-bit mux).
    // Egress address and bank signals are pure registers.
    logic [HBM3_ADDR_BITS-1:0] sel_addr [0:HBM3_CHANNELS-1];

    // Per-channel local blocking: prevents re-selecting a pending request in Stage B.
    // Channel-local tracking avoids global 16-input OR trees and minimizes critical path.
    logic [HBM3_CHANNELS-1:0] blocking;
    // Each always_comb uses dedicated loop variables (IEEE 1800-2023 9.2.2.2).
    
    integer out_ch, hs_ch, seq_ch;

    wire [HBM3_ADDR_BITS-1:0] host_addr_lane [0:HBM3_HOST_LANES-1];
    wire [HBM3_HOST_DATA_BITS-1:0] host_wdata_lane [0:HBM3_HOST_LANES-1];
    genvar lane_unpack;

    // Unpack once with constant slices. Dynamic packed part-selects caused
    // Yosys to synthesize variable multipliers and shift networks for every
    // arbiter candidate, which dominated ABC runtime without adding logic.
    generate for (lane_unpack = 0; lane_unpack < HBM3_HOST_LANES; lane_unpack = lane_unpack + 1) begin : g_unpack
        assign host_addr_lane[lane_unpack] =
            host_addr[lane_unpack*HBM3_ADDR_BITS +: HBM3_ADDR_BITS];
        assign host_wdata_lane[lane_unpack] =
            host_wdata[lane_unpack*HBM3_HOST_DATA_BITS +: HBM3_HOST_DATA_BITS];
    end endgenerate

    // Address bits [7:4] name one of 16 physical channels. Bits [3:0] are
    // a scheduler-visible bank hint; the licensed PHY/controller ultimately
    // owns the JEDEC bank decode.
    function automatic [3:0] channel_of(input logic [HBM3_ADDR_BITS-1:0] addr);
        channel_of = addr[7:4];
    endfunction

    function automatic [3:0] bank_of(input logic [HBM3_ADDR_BITS-1:0] addr);
        bank_of = addr[3:0];
    endfunction

    // ---- per-channel fresh candidate selection: rotate + priority tree ----
    logic [LANE_BITS-1:0] fresh_lane [0:HBM3_CHANNELS-1];
    logic [HBM3_CHANNELS-1:0] fresh_any, fresh_diff;

    genvar ch_g, lane_g, stage_g, lvl_g, node_g;
    generate for (ch_g = 0; ch_g < HBM3_CHANNELS; ch_g = ch_g + 1) begin : g_ch_select
        // Leaf candidate flags, natural lane order -- all 32 computed in
        // parallel, independent of each other (no loop-carried dependency).
        wire [HBM3_HOST_LANES-1:0] cand_elig, cand_diff;
        for (lane_g = 0; lane_g < HBM3_HOST_LANES; lane_g = lane_g + 1) begin : g_cand
            // blocking[ch] indicates stage B is full and not draining this cycle
            assign cand_elig[lane_g] = host_valid[lane_g] &&
                !(blocking[ch_g] && (sel_lane[ch_g] == lane_g[LANE_BITS-1:0])) &&
                (channel_of(host_addr_lane[lane_g]) == ch_g[3:0]);
            assign cand_diff[lane_g] = cand_elig[lane_g] &&
                (bank_of(host_addr_lane[lane_g]) != last_bank[ch_g]);
        end

        // Barrel-rotate {diff,elig} pairs by rr_ptr[ch_g] so rotated
        // position 0 == true lane rr_ptr[ch_g] (this cycle's highest
        // round-robin priority), position 1 == rr_ptr+1, etc. ROT_STAGES
        // fixed-offset stages (offsets 1,2,4,... are compile-time constants
        // -- only the per-stage swap/no-swap decision is a runtime bit),
        // same technique as a standard barrel shifter: log2(N) levels, no
        // variable-shift network.
        // verilator lint_off UNOPTFLAT
        // Verified false positive, not a real cycle (same class of issue as
        // has_elig/win_pos below -- see that comment): stage_g -> stage_g+1
        // is strictly feed-forward (each stage only ever reads the previous
        // stage, all indices elaboration-time constants), confirmed
        // bit-for-bit against the original implementation by
        // tb_hbm3_800g_scheduler.sv and tb_hbm3_800g_scheduler_scoreboard.sv
        // (2026-08-25).
        wire [1:0] rot_stage [0:ROT_STAGES][0:HBM3_HOST_LANES-1];
        for (lane_g = 0; lane_g < HBM3_HOST_LANES; lane_g = lane_g + 1) begin : g_rot0
            assign rot_stage[0][lane_g] = {cand_diff[lane_g], cand_elig[lane_g]};
        end
        for (stage_g = 0; stage_g < ROT_STAGES; stage_g = stage_g + 1) begin : g_rot_stage
            for (lane_g = 0; lane_g < HBM3_HOST_LANES; lane_g = lane_g + 1) begin : g_rot_lane
                wire [1:0] rot_src_shifted = rot_stage[stage_g][(lane_g + (1 << stage_g)) % HBM3_HOST_LANES];
                wire [1:0] rot_src_same    = rot_stage[stage_g][lane_g];
                assign rot_stage[stage_g+1][lane_g] = rr_ptr[ch_g][stage_g]
                    ? rot_src_shifted : rot_src_same;
            end
        end
        // verilator lint_on UNOPTFLAT

        // Balanced priority-merge tree over the rotated positions: position
        // 0 is highest priority, increasing position is decreasing priority
        // (matches the original's round-robin scan order exactly). Each
        // node reports {has_diff, has_elig, winning_position}; a
        // different-bank candidate always outranks a same-bank one, and
        // within each category the earliest (lowest-position) one wins.
        // verilator lint_off UNOPTFLAT
        // Verified false positive, not a real cycle: has_diff (identical
        // has_diff[lvl_g+1]=l_diff||r_diff pattern) is NOT flagged, only
        // has_elig/win_pos are -- the difference is that has_elig[lvl_g]
        // and win_pos[lvl_g] each have a second consumer (pick_left) beyond
        // their own next-level assign, which appears to defeat Verilator's
        // per-element array-splitting for just those two arrays. The
        // lvl_g -> lvl_g+1 indexing is strictly feed-forward (checked by
        // hand: level L+1 only ever reads level L, never itself or a later
        // level) and confirmed bit-for-bit against the original
        // implementation by tb_hbm3_800g_scheduler.sv and
        // tb_hbm3_800g_scheduler_scoreboard.sv (2026-08-25).
        wire has_diff [0:ROT_STAGES][0:HBM3_HOST_LANES-1];
        wire has_elig [0:ROT_STAGES][0:HBM3_HOST_LANES-1];
        wire [LANE_BITS-1:0] win_pos [0:ROT_STAGES][0:HBM3_HOST_LANES-1];

        for (lane_g = 0; lane_g < HBM3_HOST_LANES; lane_g = lane_g + 1) begin : g_leaf
            assign has_diff[0][lane_g] = rot_stage[ROT_STAGES][lane_g][1];
            assign has_elig[0][lane_g] = rot_stage[ROT_STAGES][lane_g][0];
            assign win_pos[0][lane_g]  = lane_g[LANE_BITS-1:0];
        end

        for (lvl_g = 0; lvl_g < ROT_STAGES; lvl_g = lvl_g + 1) begin : g_tree_level
            localparam int NOUT = (HBM3_HOST_LANES >> lvl_g) >> 1;
            for (node_g = 0; node_g < NOUT; node_g = node_g + 1) begin : g_tree_node
                // Every read of the previous level goes through a local
                // alias first (never a direct same-array reference on an
                // assign's RHS) -- otherwise Verilator's UNOPTFLAT checker
                // conservatively flags the array as self-dependent even
                // though the lvl_g -> lvl_g+1 indexing is strictly
                // feed-forward (confirmed: the one line below that skipped
                // this and read has_elig[lvl_g][...] directly was the only
                // other one flagged, alongside win_pos below).
                wire l_diff = has_diff[lvl_g][2*node_g];
                wire r_diff = has_diff[lvl_g][2*node_g+1];
                wire l_elig = has_elig[lvl_g][2*node_g];
                wire r_elig = has_elig[lvl_g][2*node_g+1];
                wire [LANE_BITS-1:0] l_pos = win_pos[lvl_g][2*node_g];
                wire [LANE_BITS-1:0] r_pos = win_pos[lvl_g][2*node_g+1];
                wire pick_left = l_diff || (!r_diff && l_elig);
                assign has_diff[lvl_g+1][node_g] = l_diff || r_diff;
                assign has_elig[lvl_g+1][node_g] = l_elig || r_elig;
                assign win_pos[lvl_g+1][node_g]  = pick_left ? l_pos : r_pos;
            end
        end
        // verilator lint_on UNOPTFLAT

        assign fresh_any[ch_g]  = has_elig[ROT_STAGES][0];
        assign fresh_diff[ch_g] = has_diff[ROT_STAGES][0];
        assign fresh_lane[ch_g] = rr_ptr[ch_g] + win_pos[ROT_STAGES][0]; // mod 2**LANE_BITS by width truncation
    end endgenerate

    // ================= Stage B: Egress Multiplexing =================
    // egress_* driven directly from registered sel_*. Decouples arbiter tree from outputs.
    logic [HBM3_CHANNELS-1:0] accept, load_b;
    always_comb begin
        host_ready   = '0;
        egress_valid = '0;
        egress_addr  = '0;
        egress_wdata = '0;
        egress_bank  = '0;
        for (out_ch = 0; out_ch < HBM3_CHANNELS; out_ch = out_ch + 1) begin
            // Validate registered selection against live host_valid to ensure no stale grant.
            egress_valid[out_ch] = sel_valid[out_ch] &&
                                    host_valid[sel_lane[out_ch]];
            egress_addr[out_ch*HBM3_ADDR_BITS +: HBM3_ADDR_BITS] = sel_addr[out_ch];
            egress_wdata[out_ch*HBM3_HOST_DATA_BITS +: HBM3_HOST_DATA_BITS] =
                host_wdata_lane[sel_lane[out_ch]];
            egress_bank[out_ch*4 +: 4] = bank_of(sel_addr[out_ch]);
            // Grant ready to selected lane upon egress handshake.
            if (egress_valid[out_ch] && egress_ready[out_ch])
                host_ready[sel_lane[out_ch]] = 1'b1;
        end
    end

    always_comb begin
        for (hs_ch = 0; hs_ch < HBM3_CHANNELS; hs_ch = hs_ch + 1) begin
            accept[hs_ch] = egress_valid[hs_ch] && egress_ready[hs_ch];
            // Load new selection when Stage B is empty or popping in current cycle.
            load_b[hs_ch]   = !egress_valid[hs_ch] || egress_ready[hs_ch];
            // Block re-selection of pending lane until queue updates post-pop.
            blocking[hs_ch] =  sel_valid[hs_ch];
        end
    end

    always_ff @(posedge clk_core or negedge rst_n) begin
        if (!rst_n) begin
            sel_valid <= '0;
            for (seq_ch = 0; seq_ch < HBM3_CHANNELS; seq_ch = seq_ch + 1) begin
                rr_ptr[seq_ch]    <= '0;
                last_bank[seq_ch] <= '0;
                sel_lane[seq_ch]  <= '0;
                sel_addr[seq_ch]  <= '0;
            end
        end else begin
            for (seq_ch = 0; seq_ch < HBM3_CHANNELS; seq_ch = seq_ch + 1) begin
                // last_bank is updated on accept and sampled from registered sel_addr
                // without adding combinational depth to arbiter critical path.
                if (accept[seq_ch])
                    last_bank[seq_ch] <= bank_of(sel_addr[seq_ch]);
                if (load_b[seq_ch]) begin
                    sel_valid[seq_ch] <= fresh_any[seq_ch];
                    if (fresh_any[seq_ch]) begin
                        sel_lane[seq_ch] <= fresh_lane[seq_ch];
                        sel_addr[seq_ch] <= host_addr_lane[fresh_lane[seq_ch]];
                        rr_ptr[seq_ch]   <= fresh_lane[seq_ch] + 1'b1;
                    end
                end
            end
        end
    end
endmodule
