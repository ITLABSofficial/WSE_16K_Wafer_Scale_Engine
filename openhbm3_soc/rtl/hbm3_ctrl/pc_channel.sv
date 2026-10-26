// ============================================================================
// File: pc_channel.sv
// Project: Open_HBM3_Controller
// Description:
//   Single Pseudo-Channel Controller with ACT -> BL8 RD/WR -> PRE pipeline,
//   Hamming SECDED (39, 32) ECC generation, DBIac data bus inversion,
//   dual-subchannel DDR parallelism, and bank prefetch scheduling.
// ============================================================================

`timescale 1ns/1ps
`include "hbm3_defs.svh"


// NOTE: Timing constants (T_RCD, T_RP, T_REFI, T_RFC, NBANKS) are sourced
// directly from hbm3_defs.svh localparams to prevent circular parameter shadowing.
module pc_channel #(
    parameter int AW = ROWBITS + NBANK_AW + COLBITS
)(
    input  logic        clk,
    input  logic        rst_n,

    input  logic        req_valid,
    output logic        req_ready,
    input  logic        req_write,
    input  logic [AW-1:0]   req_addr,
    input  logic [255:0]    req_wdata,
    output logic        rsp_valid,
    output logic [255:0] rsp_rdata,

    // DRAM command bus (intra-channel row/col bus)
    output logic              cmd_valid,
    output logic [1:0]        cmd_type,
    output logic [NBANK_AW-1:0]    cmd_bank,
    output logic [ROWBITS-1:0] cmd_row,
    output logic [COLBITS-1:0] cmd_col,
    output logic [31:0]       cmd_wdata,
    output logic [3:0]        cmd_wdbi,   // Write-path DBI (1 bit per byte)
    // SECDED ECC: 7 check bits computed over raw 32-bit payload (rtl/ecc.sv)
    output logic [6:0]        cmd_wecc,
    // PREA (Precharge-All): Closes all banks simultaneously on PRE
    output logic              cmd_allbanks,
    input  logic [31:0]       cmd_rdata,
    input  logic [3:0]        cmd_rdbi,   // Read-path DBI (DRAM -> Controller)
    // ECC status: 2'b00=clean, 2'b01=single-bit corrected, 2'b10=double-bit detected
    input  logic [1:0]        cmd_recc_stat,
    // Sticky ECC error flags: remain asserted until reset to ensure host capture
    output logic               ecc_corrected_sticky,
    output logic               ecc_uncorrectable_sticky,

    // ---- Sub-channel B: Dual-column DDR data path in parallel with sub-channel A ----
    output logic [COLBITS-1:0] cmd_col_b,
    output logic [31:0]       cmd_wdata_b,
    output logic [3:0]        cmd_wdbi_b,
    output logic [6:0]        cmd_wecc_b,
    input  logic [31:0]       cmd_rdata_b,
    input  logic [3:0]        cmd_rdbi_b,
    input  logic [1:0]        cmd_recc_stat_b,

    output logic              refreshing,
    // Channel busy: asserted when FSM is active or requests remain in queue
    output logic              busy
);
    localparam QD  = 4;
    // Parallel DDR beats: 2 columns processed per cycle; burst completes in BL/2 cycles
    localparam int BLP = BL/2;
    typedef enum logic [2:0] {S_IDLE, S_ACT, S_ACTW, S_BEAT, S_PRE, S_PREALL, S_REF} st_e;
    st_e st;

    // kuyruk
    logic              q_wr   [QD];
    logic [AW-1:0]     q_addr [QD];
    logic [255:0]      q_wd   [QD];
    logic [$clog2(QD)-1:0] q_head, q_tail;
    logic [2:0]        q_cnt;
    wire q_empty = (q_cnt == 0);
    wire q_full  = (q_cnt == QD);

    // bank defteri
    logic [NBANKS-1:0]        b_open;
    logic [ROWBITS-1:0] b_row [NBANKS];

    // aktif istek
    logic              a_wr;
    logic [AW-1:0]     a_addr;
    logic [255:0]      a_wd;
    logic [255:0]      rd_buf;
    logic [2:0]        beat;
    logic [15:0]       waitc;
    logic [15:0]       ref_cnt, rfc_cnt;
    logic [15:0]       stuck;

    // Bank pre-activation (prefetch): when command bus is idle, evaluate
    // next queue entry for candidate prefetch ACT to hide access latency.
    // Preserves in-order completion guarantees while reducing pipeline bubbles.
    logic              pf_valid, pf_act_sent;
    logic [NBANK_AW-1:0] pf_bank;
    logic [ROWBITS-1:0]  pf_row;
    logic [15:0]         pf_waitc;
    wire [NBANK_AW-1:0]  nb   = q_addr[q_head][COLBITS +: NBANK_AW];
    wire [ROWBITS-1:0]   nrow = q_addr[q_head][COLBITS + NBANK_AW +: ROWBITS];
    wire cmdbus_free_for_pf = (st == S_ACTW) || (st == S_PRE && waitc != 16'(T_RP-1));

    // Address mapping: {row, bank, col} with col at LSB for sequential burst locality.
    wire [COLBITS-1:0]                  acol = a_addr[COLBITS-1:0];
    wire [NBANK_AW-1:0]                 ab   = a_addr[COLBITS +: NBANK_AW];
    wire [ROWBITS-1:0]                  arow = a_addr[COLBITS + NBANK_AW +: ROWBITS];
    // Head of queue request
    wire [NBANK_AW-1:0]                 hb   = q_addr[q_head][COLBITS +: NBANK_AW];
    wire [ROWBITS-1:0]                  hrow = q_addr[q_head][COLBITS + NBANK_AW +: ROWBITS];

    wire refresh_due = (ref_cnt >= 16'(T_REFI));
    assign refreshing = (st == S_REF);
    assign req_ready  = !q_full && (st == S_IDLE);
    // Commit pending state treated as busy until channel fully drains
    assign busy       = (st != S_IDLE) || !q_empty || pf_commit_pending;

    // Request queue management (push/pop and head staging)
    // If ACT already sent for head entry, wait for T_RCD before transitioning.
    wire pf_commit_pending = pf_valid && pf_act_sent;

    // ---- tRRD: minimum timing delay between consecutive ACT commands ----
    // Enforce tRRD timing constraint between consecutive ACT commands.
    logic [15:0] act_gap;
    wire act_issued = cmd_valid && (cmd_type == CMD_ACT);
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)                    act_gap <= 16'hFFFF;   // Max interval on reset
        else if (act_issued)           act_gap <= 0;
        else if (act_gap != 16'hFFFF)  act_gap <= act_gap + 1;
    end
    wire trrd_ok = (act_gap >= 16'(T_RRD - 1));

    wire start_req = (st == S_IDLE) && !q_empty && !refresh_due &&
                     !pf_commit_pending && trrd_ok;
    wire start_req_next = start_req;

    // Bank prefetch FSM (decoupled, does not alter S_IDLE decision logic;
    // only populates b_open/b_row early). Avoids new prefetch when refresh is pending.
    wire pf_want = cmdbus_free_for_pf && !pf_valid && !q_empty && !refresh_due &&
                   (nb != ab) && !(b_open[nb] && b_row[nb] == nrow);
    wire pf_act_fire = pf_valid && !pf_act_sent && cmdbus_free_for_pf && trrd_ok;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pf_valid <= 0; pf_act_sent <= 0; pf_bank <= '0; pf_row <= '0; pf_waitc <= 0;
        end else begin
            // PRIORITY: If physical ACT command already sent to DRAM (pf_act_sent),
            // wait until T_RCD completes to commit to b_open table.
            if (pf_valid && pf_act_sent) begin
                if (pf_waitc != 0) pf_waitc <= pf_waitc - 1;
                // b_open/b_row updated in single owner block below via pf_commit
                else pf_valid <= 0;
            end else if (st == S_REF || st == S_PREALL || st == S_IDLE) begin
                // Safe to cancel if physical command not yet dispatched
                pf_valid <= 0; pf_act_sent <= 0;
            end else if (pf_act_fire) begin
                pf_act_sent <= 1;
                pf_waitc    <= 16'(T_RCD - 1);
            end
            if (pf_want) begin
                pf_valid <= 1;
                pf_bank  <= nb;
                pf_row   <= nrow;
                pf_act_sent <= 0;
            end
        end
    end

    // ---- b_open / b_row: Single Owner State Management ----
    // Updated by both main FSM and prefetch logic using unified arbitration flags
    // to avoid multiple-driver conflicts during synthesis.
    wire fsm_open_set    = (st == S_ACTW)   && (waitc == 0);
    wire fsm_open_clr    = (st == S_PRE)    && (waitc == 0);
    wire fsm_open_clrall = (st == S_PREALL);          // PREA
    wire pf_commit       = pf_valid && pf_act_sent && (pf_waitc == 0);

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            b_open <= '0;
            for (int i = 0; i < NBANKS; i++) b_row[i] <= '0;
        end else if (fsm_open_clrall) begin
            b_open <= '0;                                // en yuksek oncelik
        end else begin
            if (fsm_open_set) begin
                b_open[ab] <= 1;
                b_row[ab]  <= arow;
            end
            if (fsm_open_clr) b_open[ab] <= 0;
            if (pf_commit) begin
                b_open[pf_bank] <= 1;
                b_row[pf_bank]  <= pf_row;
            end
        end
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            q_head <= 0; q_tail <= 0; q_cnt <= 0;
            a_wr <= 0; a_addr <= '0; a_wd <= '0;
        end else begin
            if (start_req) begin
                a_wr   <= q_wr[q_head];
                a_addr <= q_addr[q_head];
                a_wd   <= q_wd[q_head];
`ifdef DEBUG
                $display("[POP] %0t ch=%m head=%0d adr=%h wr=%b", $time, q_head, q_addr[q_head], q_wr[q_head]);
`endif
                q_head <= q_head + 1;
            end
            if (req_valid && req_ready) begin
                q_wr[q_tail]   <= req_write;
                q_addr[q_tail] <= req_addr;
                q_wd[q_tail]   <= req_wdata;
                q_tail <= q_tail + 1;
            end
            case ({start_req, req_valid && req_ready})
                2'b10: q_cnt <= q_cnt - 1;
                2'b01: q_cnt <= q_cnt + 1;
                default: ;
            endcase
            if (q_cnt > QD)
                $display("[Q-BOZUK] %0t ch=%m cnt=%0d head=%0d tail=%0d", $time, q_cnt, q_head, q_tail);
        end
    end

    // ana durum makinesi
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; beat <= 0; waitc <= 0;
            ref_cnt <= 0; rfc_cnt <= 0;
            rd_buf <= '0;   // b_open/b_row: tek sahipli blokta reset edilir
            rsp_valid <= 0; rsp_rdata <= '0;
        end else begin
            rsp_valid <= 0;
            if (ref_cnt < 16'(T_REFI)) ref_cnt <= ref_cnt + 1;

            if (st != S_IDLE) begin
                stuck <= stuck + 1;
                if (stuck == 5000)
                    $display("[PC-STUCK] st=%0d q=%0d beat=%0d waitc=%0d rfc=%0d rdue=%b cv=%b",
                             st, q_cnt, beat, waitc, rfc_cnt, refresh_due, cmd_valid);
            end else stuck <= 0;
`ifdef DEBUG
            if (st == S_BEAT)
                $display("[BEAT] %0t b=%0d wr=%b rd=%h", $time, beat, a_wr, cmd_rdata);
            if (st == S_PRE && waitc == 16'(T_RP-1))
                $display("[PREI] %0t wr=%b", $time, a_wr);
`endif
            case (st)
                S_IDLE: begin
                    beat <= 0;
                    // Refresh handling: if refresh is due and no prefetch commit is pending,
                    // precharge all open banks before entering refresh state (S_REF).
                    if (refresh_due && !pf_commit_pending) begin
                        if (b_open != '0) begin
                            st <= S_PREALL;   // Precharge all, then refresh
                        end else begin
                            st <= S_REF; rfc_cnt <= 16'(T_RFC); ref_cnt <= 0;
                        end
                    end else if (start_req_next) begin
                        if (b_open[hb] && b_row[hb] == hrow)
                            st <= S_BEAT;          // Page hit: proceed directly to column beat
                        else
                            st <= S_ACT;
                    end
                end

                S_ACT: begin
                    // ACT command pulsed for single cycle
                    waitc <= 16'(T_RCD - 1);
                    st    <= S_ACTW;
                end

                S_ACTW: begin
                    // b_open[ab]/b_row[ab] updated in single owner block (fsm_open_set)
                    if (waitc != 0) waitc <= waitc - 1;
                    else            st    <= S_BEAT;
                end

                S_BEAT: begin
`ifdef DEBUG
                    if (beat == 0)
                        $display("[BEAT0] %0t ch=%m aadr=%h", $time, a_addr);
`endif
                    if (beat == 3'(BLP-1)) begin
                        if (!a_wr) begin
                            rsp_valid <= 1;
                            rsp_rdata <= rd_buf;
                            rsp_rdata[beat*64      +: 32] <= cmd_rdata_dec;
                            rsp_rdata[beat*64 + 32 +: 32] <= cmd_rdata_dec_b;
`ifdef DEBUG
                            $display("[RSPI] %0t buf=%h A=%h B=%h", $time, rd_buf, cmd_rdata_dec, cmd_rdata_dec_b);
`endif
                        end
                        // Enforce tRTP turnaround latency on read bursts before precharge
                        waitc <= a_wr ? 16'(T_RP - 1)
                                      : 16'(T_RP - 1 + T_RTP - 1);
                        st    <= S_PRE;
                    end else begin
                        if (!a_wr) begin
                            rd_buf[beat*64      +: 32] <= cmd_rdata_dec;
                            rd_buf[beat*64 + 32 +: 32] <= cmd_rdata_dec_b;
                        end
                        beat <= beat + 1;
                    end
                end

                S_PRE: begin
                    // b_open[ab] temizleme tek sahipli blokta (fsm_open_clr)
                    if (waitc != 0) waitc <= waitc - 1;
                    else            st    <= S_IDLE;
                end

                S_PREALL: begin
                    // Single-cycle PREA: sends precharge-all command and clears tracking table
                    st <= S_REF; rfc_cnt <= 16'(T_RFC); ref_cnt <= 0;
                end

                S_REF: begin
                    if (rfc_cnt != 0) rfc_cnt <= rfc_cnt - 1;
                    else begin
                        st <= S_IDLE;
                    end
                end

                default: st <= S_IDLE;
            endcase
        end
    end

    // Pipelined Write DBI/ECC Generation:
    // DBI and ECC encoders compute one cycle in advance and latch into output registers.
    // This removes combinational encoding delay from the external command bus.
    // - Fast path (S_IDLE -> S_BEAT, page hit): pre-encodes directly from q_wd[q_head].
    // - ACT path (S_ACTW): pre-encodes beat 0 on the final ACT wait cycle (waitc == 0).
    // - S_BEAT: pre-encodes subsequent beat during the current beat transfer.
    wire fastpath_fire  = start_req_next && b_open[hb] && (b_row[hb] == hrow);
    wire actw_warmup    = (st == S_ACTW) && (waitc == 0);
    wire beatnext_fire  = (st == S_BEAT) && (beat != 3'(BLP-1));
    wire pre_fire       = fastpath_fire || actw_warmup || beatnext_fire;

    // Copy to local wire prior to variable indexed bit-slice for simulation precision
    logic [255:0] pre_src;
    always_comb pre_src = fastpath_fire ? q_wd[q_head] : a_wd;
    wire [2:0]  pre_beat  = (fastpath_fire || actw_warmup) ? 3'd0 : (beat + 3'd1);
    wire [31:0] pre_raw   = pre_src[pre_beat*64      +: 32];
    wire [31:0] pre_raw_b = pre_src[pre_beat*64 + 32 +: 32];

    logic [31:0] pre_enc, pre_enc_b;
    logic [3:0]  pre_dbi, pre_dbi_b;
    logic [6:0]  pre_ecc, pre_ecc_b;
    dbi_enc    #(.BYTES(4)) u_wenc   (.din(pre_raw),   .dout(pre_enc),   .dbi(pre_dbi));
    dbi_enc    #(.BYTES(4)) u_wenc_b (.din(pre_raw_b), .dout(pre_enc_b), .dbi(pre_dbi_b));
    ecc_encode u_wecc               (.din(pre_raw),   .ecc(pre_ecc));
    ecc_encode u_wecc_b             (.din(pre_raw_b), .ecc(pre_ecc_b));

    logic [31:0] wdata_pipe, wdata_b_pipe;
    logic [3:0]  wdbi_pipe,  wdbi_b_pipe;
    logic [6:0]  wecc_pipe,  wecc_b_pipe;
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wdata_pipe <= '0; wdata_b_pipe <= '0;
            wdbi_pipe  <= '0; wdbi_b_pipe  <= '0;
            wecc_pipe  <= '0; wecc_b_pipe  <= '0;
        end else if (pre_fire) begin
            wdata_pipe   <= pre_enc;   wdata_b_pipe <= pre_enc_b;
            wdbi_pipe    <= pre_dbi;   wdbi_b_pipe  <= pre_dbi_b;
            wecc_pipe    <= pre_ecc;   wecc_b_pipe  <= pre_ecc_b;
        end
    end

    logic [31:0] cmd_rdata_dec, cmd_rdata_dec_b;
    dbi_dec #(.BYTES(4)) u_rdec   (.din(cmd_rdata),   .dbi(cmd_rdbi),   .dout(cmd_rdata_dec));
    dbi_dec #(.BYTES(4)) u_rdec_b (.din(cmd_rdata_b), .dbi(cmd_rdbi_b), .dout(cmd_rdata_dec_b));

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ecc_corrected_sticky    <= 0;
            ecc_uncorrectable_sticky <= 0;
        end else begin
            if (cmd_valid && cmd_type == CMD_RD) begin
                if (cmd_recc_stat == 2'b01 || cmd_recc_stat_b == 2'b01)
                    ecc_corrected_sticky     <= 1;
                if (cmd_recc_stat == 2'b10 || cmd_recc_stat_b == 2'b10)
                    ecc_uncorrectable_sticky <= 1;
            end
        end
    end

    // komut uretimi (kombinasyonel, durum tabanli)
    always_comb begin
        cmd_valid = 0; cmd_type = CMD_ACT;
        cmd_bank = ab; cmd_row = arow; cmd_col = acol; cmd_col_b = acol;
        cmd_wdata = '0; cmd_wdbi = '0; cmd_wecc = '0; cmd_allbanks = 0;
        cmd_wdata_b = '0; cmd_wdbi_b = '0; cmd_wecc_b = '0;
        case (st)
            S_ACT:  begin cmd_valid = 1; cmd_type = CMD_ACT; end
            S_BEAT: begin
                cmd_valid = 1;
                cmd_type    = a_wr ? CMD_WR : CMD_RD;
                cmd_col     = acol + COLBITS'(beat*2);
                cmd_col_b   = acol + COLBITS'(beat*2 + 1);
                cmd_wdata   = wdata_pipe;  cmd_wdata_b = wdata_b_pipe;
                cmd_wdbi    = wdbi_pipe;   cmd_wdbi_b  = wdbi_b_pipe;
                cmd_wecc    = wecc_pipe;   cmd_wecc_b  = wecc_b_pipe;
            end
            S_PRE:  if (waitc == 16'(T_RP-1)) begin
                cmd_valid = 1; cmd_type = CMD_PRE;
            end
            S_PREALL: begin
                cmd_valid = 1; cmd_type = CMD_PRE; cmd_allbanks = 1;
            end
            default: ;
        endcase
        // Prefetch ACT: issued when command bus is unasserted by primary transaction
        if (!cmd_valid && pf_act_fire) begin
            cmd_valid = 1; cmd_type = CMD_ACT;
            cmd_bank  = pf_bank; cmd_row = pf_row;
        end
    end

endmodule
