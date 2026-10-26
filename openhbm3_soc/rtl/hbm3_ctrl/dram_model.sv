// ============================================================================
// File: dram_model.sv
// Project: Open_HBM3_Controller
// Description:
//   Behavioral HBM3 DRAM model: bank/row activation, column RD/WR (32B chunk).
//   Persistent storage indexed by {bank, row, col}; ACT/PRE are bookkeeping ops.
//   DBI decoding on write, encoding on read.
//   Dual sub-channels (A and B) processed in parallel per clock cycle.
//   Includes address aliasing collision detection and timing checkers (tRRD, tRTP).
// ============================================================================
`timescale 1ns/1ps
`include "hbm3_defs.svh"

module dram_model (
    input  logic        clk,
    input  logic        rst_n,
    input  logic              cmd_valid,
    input  logic [1:0]        cmd_type,
    input  logic [NBANK_AW-1:0] cmd_bank,
    input  logic [ROWBITS-1:0] cmd_row,
    input  logic [COLBITS-1:0] cmd_col,
    input  logic [31:0]       cmd_wdata,
    input  logic [3:0]        cmd_wdbi,
    input  logic [6:0]        cmd_wecc,      // Write ECC computed over raw payload
    input  logic              cmd_allbanks,  // PREA: Precharge all banks simultaneously
    output logic [31:0]       cmd_rdata,
    output logic [3:0]        cmd_rdbi,
    // On-die ECC status on read: 00=clean, 01=single-bit corrected, 10=double-bit detected
    output logic [1:0]        cmd_recc_stat,

    // Sub-channel B: parallel dual-column DDR access
    input  logic [COLBITS-1:0] cmd_col_b,
    input  logic [31:0]       cmd_wdata_b,
    input  logic [3:0]        cmd_wdbi_b,
    input  logic [6:0]        cmd_wecc_b,
    output logic [31:0]       cmd_rdata_b,
    output logic [3:0]        cmd_rdbi_b,
    output logic [1:0]        cmd_recc_stat_b,

    // Fault injection port for simulation-only negative testing
    input  logic               fault_valid,
    input  logic [NBANK_AW+6+COLBITS-1:0] fault_key,
    input  logic [38:0]        fault_flip
);

    logic [NBANKS-1:0]         open;
    logic [NBANKS*ROWBITS-1:0] open_row;

    wire [NBANK_AW-1:0] rb = cmd_bank;
    logic [ROWBITS-1:0] r_row;
    assign r_row = open_row[rb*ROWBITS +: ROWBITS];

    // Write-path DBI decoders: reconstruct raw unencoded data payload
    logic [31:0] wdata_raw, wdata_raw_b;
    dbi_dec #(.BYTES(4)) u_wdec   (.din(cmd_wdata),   .dbi(cmd_wdbi),   .dout(wdata_raw));
    dbi_dec #(.BYTES(4)) u_wdec_b (.din(cmd_wdata_b), .dbi(cmd_wdbi_b), .dout(wdata_raw_b));

    // Sparse storage array: key = bank | lower RSTOR bits of row | col
    // Row bits truncated to RSTOR=6 for simulation efficiency.
    // Full row stored as tag to detect address aliasing collisions.
    localparam int RSTOR = 6;
    logic [31:0]        mem     [0:(NBANKS*(1<<RSTOR)*(1<<COLBITS))-1];
    logic [6:0]         mem_ecc [0:(NBANKS*(1<<RSTOR)*(1<<COLBITS))-1];
    logic [ROWBITS-1:0] mem_tag [0:(NBANKS*(1<<RSTOR)*(1<<COLBITS))-1];
    logic               mem_vld [0:(NBANKS*(1<<RSTOR)*(1<<COLBITS))-1];
    wire [NBANK_AW+RSTOR+COLBITS-1:0] skey   = {cmd_bank, r_row[RSTOR-1:0], cmd_col};
    wire [NBANK_AW+RSTOR+COLBITS-1:0] skey_b = {cmd_bank, r_row[RSTOR-1:0], cmd_col_b};

    // Read path: retrieve raw payload + ECC, decode with SECDED, encode DBI onto DQ
    logic [31:0] rdata_stored, rdata_corrected, rdata_stored_b, rdata_corrected_b;
    logic [6:0]  ecc_stored, ecc_stored_b;
    logic        ecc_corr, ecc_uncorr, ecc_corr_b, ecc_uncorr_b;
    ecc_decode u_ecc_dec  (.din(rdata_stored),   .ecc(ecc_stored),   .dout(rdata_corrected),
                            .err_corrected(ecc_corr),   .err_uncorrectable(ecc_uncorr));
    ecc_decode u_ecc_dec_b(.din(rdata_stored_b), .ecc(ecc_stored_b), .dout(rdata_corrected_b),
                            .err_corrected(ecc_corr_b), .err_uncorrectable(ecc_uncorr_b));

    logic [31:0] rdata_raw, rdata_raw_b;
    dbi_enc #(.BYTES(4)) u_renc   (.din(rdata_raw),   .dout(cmd_rdata),   .dbi(cmd_rdbi));
    dbi_enc #(.BYTES(4)) u_renc_b (.din(rdata_raw_b), .dout(cmd_rdata_b), .dbi(cmd_rdbi_b));

    wire rd_now = cmd_valid && cmd_type == CMD_RD;
    assign rdata_stored   = rd_now ? mem[skey]       : 32'd0;
    assign ecc_stored     = rd_now ? mem_ecc[skey]   : 7'd0;
    assign rdata_stored_b = rd_now ? mem[skey_b]     : 32'd0;
    assign ecc_stored_b   = rd_now ? mem_ecc[skey_b] : 7'd0;
    assign rdata_raw      = rd_now ? rdata_corrected   : 32'd0;
    assign rdata_raw_b    = rd_now ? rdata_corrected_b : 32'd0;
    assign cmd_recc_stat   = rd_now ? (ecc_uncorr   ? 2'b10 : (ecc_corr   ? 2'b01 : 2'b00)) : 2'b00;
    assign cmd_recc_stat_b = rd_now ? (ecc_uncorr_b ? 2'b10 : (ecc_corr_b ? 2'b01 : 2'b00)) : 2'b00;

    // Read tag check: verify requested row matches stored tag
    always_ff @(posedge clk) begin
        if (cmd_valid && cmd_type == CMD_RD && mem_vld[skey] &&
            mem_tag[skey] !== r_row)
            $display("[DRAM-ERROR] %0t ADDRESS ALIASING COLLISION on read: b=%0d col=%0d, row %0d requested but storage has %0d",
                     $time, rb, cmd_col, r_row, mem_tag[skey]);
    end
    always_ff @(posedge clk) begin
        if (cmd_valid && cmd_type == CMD_RD && mem_vld[skey_b] &&
            mem_tag[skey_b] !== r_row)
            $display("[DRAM-ERROR] %0t ADDRESS ALIASING COLLISION on read (B): b=%0d col=%0d, row %0d requested but storage has %0d",
                     $time, rb, cmd_col_b, r_row, mem_tag[skey_b]);
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            open <= '0; open_row <= '0;
            for (int i = 0; i < NBANKS*(1<<RSTOR)*(1<<COLBITS); i++)
                mem_vld[i] <= 0;
        end else if (cmd_valid) begin
`ifdef DEBUG
            if (cmd_type == CMD_ACT)
                $display("[DMA] %0t b=%0d row=%0d", $time, rb, cmd_row);
            else if (cmd_type == CMD_RD || cmd_type == CMD_WR) begin
                $display("[DM] %0t t=%s b=%0d row=%0d col=%0d/%0d wd=%h/%h", $time,
                         (cmd_type==CMD_WR?"WR":"RD"), rb, r_row, cmd_col, cmd_col_b,
                         wdata_raw, wdata_raw_b);
                $display("[DMR] %0t rdata=%h/%h", $time, rdata_raw, rdata_raw_b);
            end
`endif
            case (cmd_type)
                CMD_ACT: begin
                    open[rb] <= 1;
                    open_row[rb*ROWBITS +: ROWBITS] <= cmd_row;
                end
                CMD_PRE: if (cmd_allbanks) open <= '0;  // PREA
                         else               open[rb] <= 0;
                CMD_WR: begin
                    mem[skey]     <= wdata_raw;
                    mem_ecc[skey] <= cmd_wecc;
                    mem_tag[skey] <= r_row;
                    mem_vld[skey] <= 1;
                    if (mem_vld[skey] && mem_tag[skey] !== r_row)
                        $display("[DRAM-ERROR] %0t ADDRESS ALIASING COLLISION: b=%0d col=%0d, row %0d overwriting %0d (RSTOR=%0d insufficient)",
                                 $time, rb, cmd_col, mem_tag[skey], r_row, RSTOR);
                    // Sub-channel B: simultaneous write to dual column
                    mem[skey_b]     <= wdata_raw_b;
                    mem_ecc[skey_b] <= cmd_wecc_b;
                    mem_tag[skey_b] <= r_row;
                    mem_vld[skey_b] <= 1;
                    if (mem_vld[skey_b] && mem_tag[skey_b] !== r_row)
                        $display("[DRAM-ERROR] %0t ADDRESS ALIASING COLLISION (B): b=%0d col=%0d, row %0d overwriting %0d (RSTOR=%0d insufficient)",
                                 $time, rb, cmd_col_b, mem_tag[skey_b], r_row, RSTOR);
                end
                default: ;
            endcase
        end
        // Fault injection for simulation testbenches
        if (fault_valid) begin
            mem[fault_key]     <= mem[fault_key]     ^ fault_flip[31:0];
            mem_ecc[fault_key] <= mem_ecc[fault_key] ^ fault_flip[38:32];
        end
    end

    // Closed bank access checker
    logic err_closed;
    always_ff @(posedge clk) begin
        err_closed <= cmd_valid &&
                      (cmd_type == CMD_RD || cmd_type == CMD_WR) &&
                      !open[rb];
        if (err_closed)
            $display("[DRAM-ERROR] %0t Column access to closed bank! bank=%0d",
                     $time, rb);
    end

    // ACT on open bank without prior PRE checker
    logic err_react;
    always_ff @(posedge clk) begin
        err_react <= cmd_valid && cmd_type == CMD_ACT && open[rb];
        if (err_react)
            $display("[DRAM-ERROR] %0t Second ACT on open bank without PRE! bank=%0d",
                     $time, rb);
    end

    // Timing constraint checkers (tRRD / tRTP)
    logic [15:0] cyc, last_act_cyc;
    logic        act_seen;
    logic [15:0] last_rd_cyc [NBANKS];
    logic [NBANKS-1:0] rd_since_act;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cyc <= 0; last_act_cyc <= 0; act_seen <= 0; rd_since_act <= '0;
            for (int i = 0; i < NBANKS; i++) last_rd_cyc[i] <= 0;
        end else begin
            cyc <= cyc + 1;
            if (cmd_valid && cmd_type == CMD_ACT) begin
                if (act_seen && (cyc - last_act_cyc) < 16'(T_RRD))
                    $display("[DRAM-ERROR] %0t tRRD timing violation: ACT %0d cycles after previous ACT (min %0d) bank=%0d",
                             $time, cyc - last_act_cyc, T_RRD, rb);
                last_act_cyc    <= cyc;
                act_seen        <= 1;
                rd_since_act[rb] <= 0;
            end
            if (cmd_valid && cmd_type == CMD_RD) begin
                last_rd_cyc[rb]  <= cyc;
                rd_since_act[rb] <= 1;
            end
            if (cmd_valid && cmd_type == CMD_PRE) begin
                if (cmd_allbanks) begin
                    for (int i = 0; i < NBANKS; i++)
                        if (rd_since_act[i] && (cyc - last_rd_cyc[i]) < 16'(T_RTP))
                            $display("[DRAM-ERROR] %0t tRTP timing violation (PREA): bank=%0d %0d cycles after last RD (min %0d)",
                                     $time, i, cyc - last_rd_cyc[i], T_RTP);
                    rd_since_act <= '0;
                end else begin
                    if (rd_since_act[rb] && (cyc - last_rd_cyc[rb]) < 16'(T_RTP))
                        $display("[DRAM-ERROR] %0t tRTP timing violation: bank=%0d %0d cycles after last RD (min %0d)",
                                 $time, rb, cyc - last_rd_cyc[rb], T_RTP);
                    rd_since_act[rb] <= 0;
                end
            end
        end
    end

endmodule
