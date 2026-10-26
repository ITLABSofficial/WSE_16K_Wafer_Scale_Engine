// One independent, synthesizable request FIFO per HBM pseudo-channel.
// These queues are in CK domain.  They are deliberately *before* the
// CK-to-WCK CDC/gearbox boundary: a production PHY owns that boundary.
`include "hbm3_800g_defs.svh"

module hbm3_800g_pc_queues #(
    parameter int QUEUE_DEPTH = 4,
    parameter int PTR_BITS = $clog2(QUEUE_DEPTH)
) (
    input  logic clk_ck,
    input  logic rst_n,
    input  logic [HBM3_PSEUDO_CHANNELS-1:0] in_valid,
    output logic [HBM3_PSEUDO_CHANNELS-1:0] in_ready,
    input  logic [HBM3_PSEUDO_CHANNELS*HBM3_ADDR_BITS-1:0] in_addr,
    input  logic [HBM3_PSEUDO_CHANNELS*HBM3_HOST_DATA_BITS-1:0] in_wdata,

    output logic [HBM3_PSEUDO_CHANNELS-1:0] out_valid,
    input  logic [HBM3_PSEUDO_CHANNELS-1:0] out_ready,
    output logic [HBM3_PSEUDO_CHANNELS*HBM3_ADDR_BITS-1:0] out_addr,
    output logic [HBM3_PSEUDO_CHANNELS*HBM3_HOST_DATA_BITS-1:0] out_wdata
);
    // verilator lint_off MULTIDRIVEN
    // Partitioned per pseudo-channel: each generate instance drives only its own index.
    // Independent reset buffering prevents multi-thousand flip-flop fanout bottleneck.
    logic [PTR_BITS-1:0] wr_ptr [0:HBM3_PSEUDO_CHANNELS-1];
    logic [PTR_BITS-1:0] rd_ptr [0:HBM3_PSEUDO_CHANNELS-1];
    logic [PTR_BITS:0] count [0:HBM3_PSEUDO_CHANNELS-1];
    // verilator lint_on MULTIDRIVEN
    localparam logic [PTR_BITS:0] QUEUE_DEPTH_COUNT = QUEUE_DEPTH[PTR_BITS:0];
    logic [HBM3_PSEUDO_CHANNELS-1:0] push, pop;
    integer comb_pc, seq_pc;

    // Registered queue head buffer:
    // Decouples the 32-channel x 256-bit x QUEUE_DEPTH:1 multiplexer from the output
    // ports, ensuring clean timing margin without combinational muxing on egress path.
    // verilator lint_off MULTIDRIVEN
    logic [HBM3_ADDR_BITS-1:0]      head_addr [0:HBM3_PSEUDO_CHANNELS-1];
    logic [HBM3_HOST_DATA_BITS-1:0] head_data [0:HBM3_PSEUDO_CHANNELS-1];
    logic [PTR_BITS-1:0]            rd_nxt       [0:HBM3_PSEUDO_CHANNELS-1];
    // verilator lint_on MULTIDRIVEN
    logic                           push_to_head [0:HBM3_PSEUDO_CHANNELS-1];

    initial begin
        if (QUEUE_DEPTH < 2 || (QUEUE_DEPTH & (QUEUE_DEPTH - 1)) != 0)
            $error("QUEUE_DEPTH must be a power of two and at least 2");
    end

    always_comb begin
        for (comb_pc = 0; comb_pc < HBM3_PSEUDO_CHANNELS; comb_pc = comb_pc + 1) begin
            out_valid[comb_pc] = (count[comb_pc] != 0);
            pop[comb_pc] = out_valid[comb_pc] && out_ready[comb_pc];
            // Permit a push while a full queue pops: sustained one line/CK/PC.
            // Gated with rst_fan to prevent spurious input acceptance during reset release.
            in_ready[comb_pc] = rst_fan[comb_pc] &&
                                ((count[comb_pc] < QUEUE_DEPTH_COUNT) || pop[comb_pc]);
            push[comb_pc] = in_valid[comb_pc] && in_ready[comb_pc];
            out_addr[comb_pc*HBM3_ADDR_BITS +: HBM3_ADDR_BITS] = head_addr[comb_pc];
            out_wdata[comb_pc*HBM3_HOST_DATA_BITS +: HBM3_HOST_DATA_BITS] = head_data[comb_pc];
        end
    end

    // Continuous assignments for read pointer next and bypass condition
    genvar gpc;
    generate for (gpc = 0; gpc < HBM3_PSEUDO_CHANNELS; gpc = gpc + 1) begin : g_head_ctl
        assign rd_nxt[gpc]       = pop[gpc] ? (rd_ptr[gpc] + 1'b1) : rd_ptr[gpc];
        assign push_to_head[gpc] = push[gpc] && (wr_ptr[gpc] == rd_nxt[gpc]);
    end endgenerate

    // Dedicated per-PC reset distribution buffer to mitigate high fanout delay
    logic [HBM3_PSEUDO_CHANNELS-1:0] rst_fan;
    genvar grq;
    generate for (grq = 0; grq < HBM3_PSEUDO_CHANNELS; grq = grq + 1) begin : g_qrst
        hbm3_800g_rst_buf u_rb (.clk(clk_ck), .arst_n(rst_n),
                                .rst_n_in(rst_n), .rst_n_out(rst_fan[grq]));
    end endgenerate

    // verilator lint_off MULTIDRIVEN
    // Array partitioned per pseudo-channel: each instance drives only its own index.
    generate for (grq = 0; grq < HBM3_PSEUDO_CHANNELS; grq = grq + 1) begin : g_q
        logic [HBM3_ADDR_BITS-1:0] addr_mem [0:QUEUE_DEPTH-1];
        logic [HBM3_HOST_DATA_BITS-1:0] data_mem [0:QUEUE_DEPTH-1];

        always_ff @(posedge clk_ck or negedge rst_fan[grq]) begin
            if (!rst_fan[grq]) begin
                wr_ptr[grq] <= '0;
                rd_ptr[grq] <= '0;
                count[grq] <= '0;
                head_addr[grq] <= '0;
                head_data[grq] <= '0;
            end else begin
                // Update head copy for next read slot or bypass if pushing directly
                if (push_to_head[grq]) begin
                    head_addr[grq] <= in_addr[grq*HBM3_ADDR_BITS +: HBM3_ADDR_BITS];
                    head_data[grq] <= in_wdata[grq*HBM3_HOST_DATA_BITS +: HBM3_HOST_DATA_BITS];
                end else begin
                    head_addr[grq] <= addr_mem[rd_nxt[grq]];
                    head_data[grq] <= data_mem[rd_nxt[grq]];
                end
                case ({push[grq], pop[grq]})
                    2'b10: begin
                        addr_mem[wr_ptr[grq]] <= in_addr[grq*HBM3_ADDR_BITS +: HBM3_ADDR_BITS];
                        data_mem[wr_ptr[grq]] <= in_wdata[grq*HBM3_HOST_DATA_BITS +: HBM3_HOST_DATA_BITS];
                        wr_ptr[grq] <= wr_ptr[grq] + 1'b1;
                        count[grq] <= count[grq] + 1'b1;
                    end
                    2'b01: begin
                        rd_ptr[grq] <= rd_ptr[grq] + 1'b1;
                        count[grq] <= count[grq] - 1'b1;
                    end
                    2'b11: begin
                        addr_mem[wr_ptr[grq]] <= in_addr[grq*HBM3_ADDR_BITS +: HBM3_ADDR_BITS];
                        data_mem[wr_ptr[grq]] <= in_wdata[grq*HBM3_HOST_DATA_BITS +: HBM3_HOST_DATA_BITS];
                        wr_ptr[grq] <= wr_ptr[grq] + 1'b1;
                        rd_ptr[grq] <= rd_ptr[grq] + 1'b1;
                    end
                    default: ;
                endcase
            end
        end
    end endgenerate
    // verilator lint_on MULTIDRIVEN

endmodule
