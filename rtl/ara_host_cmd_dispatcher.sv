// ============================================================================
// File: ara_host_cmd_dispatcher.sv
// Project: Ara_MultiCore_WSE_HBM3 (Host Command Dispatcher & Doorbell Subsystem)
// Technology: ASAP7 7nm FinFET Predictive PDK (Target: 2.0 GHz / 500 ps cycle)
// Specification: Architectural Invariants & Verification Standards
// Architectural Invariants & Verification Standards
//
// Description:
//   MMIO Doorbell Register Interface & Hardware Command Dispatcher.
//   Accepts 128-bit task descriptors from Host CPU (PCIe/CXL MMIO space)
//   and triggers cluster execution on doorbell register write.
//   Captures hardware interrupts and generates Host MSI-X IRQ pulses.
//   Provides unified MMIO register space matching driver/ara_wse_driver.h.
// ============================================================================

`timescale 1ps/1ps

module ara_host_cmd_dispatcher #(
    parameter int unsigned MMIO_ADDR_W = 16,
    parameter int unsigned MMIO_DATA_W = 32
)(
    input  logic                     clk,
    input  logic                     rst_n,

    // ------------------------------------------------------------------------
    // Host MMIO Slave Interface (32-bit AXI-Lite style or synchronous register bus)
    // ------------------------------------------------------------------------
    input  logic                     mmio_req_i,
    input  logic                     mmio_we_i,
    input  logic [MMIO_ADDR_W-1:0]   mmio_addr_i,
    input  logic [MMIO_DATA_W-1:0]   mmio_wdata_i,
    output logic [MMIO_DATA_W-1:0]   mmio_rdata_o,
    output logic                     mmio_rvalid_o,
    output logic                     mmio_ready_o,

    // Host Interrupt Line (PCIe MSI-X Notification)
    output logic                     host_irq_o,

    // ------------------------------------------------------------------------
    // Cluster Command Dispatch Interface
    // ------------------------------------------------------------------------
    output logic [127:0]             cluster_cmd_desc_o,
    output logic                     cluster_cmd_valid_o,
    input  logic                     cluster_cmd_ready_i,
    output logic                     cluster_force_abort_o,

    // Cluster Status & Interrupt Inputs
    input  logic                     cluster_busy_i,
    input  logic                     cluster_done_irq_i,
    input  logic                     cluster_err_irq_i,
    input  logic [3:0]               cluster_status_flags_i,

    // ------------------------------------------------------------------------
    // PDN & Telemetry Configuration Interface
    // ------------------------------------------------------------------------
    output logic [7:0]               cfg_pdn_step_delay_o,
    output logic                     cfg_pdn_stagger_down_o,
    input  logic [3:0]               pdn_status_i = 4'h0,
    input  logic [31:0]              barrier_state_i = 32'h0,
    output logic [31:0]              completed_task_id_o
);

    // MMIO Register Offsets (Synchronized with driver/ara_wse_driver.h per hardware invariant)
    localparam logic [7:0] ADDR_DESC_0         = 8'h00; // Desc[31:0]
    localparam logic [7:0] ADDR_DESC_1         = 8'h04; // Desc[63:32]
    localparam logic [7:0] ADDR_DESC_2         = 8'h08; // Desc[95:64]
    localparam logic [7:0] ADDR_DESC_3         = 8'h0C; // Desc[127:96]
    localparam logic [7:0] ADDR_DOORBELL       = 8'h10; // Doorbell trigger with task_id
    localparam logic [7:0] ADDR_STATUS         = 8'h14; // Status & flags
    localparam logic [7:0] ADDR_ABORT          = 8'h18; // Force abort trigger (write 0x18)
    localparam logic [7:0] ADDR_RING_HEAD      = 8'h20; // Ring head index
    localparam logic [7:0] ADDR_RING_TAIL      = 8'h24; // Ring tail index
    localparam logic [7:0] ADDR_COMPLETED_TASK = 8'h28; // Last completed task ID
    localparam logic [7:0] ADDR_BARRIER_STATE  = 8'h2C; // Hardware barrier state
    localparam logic [7:0] ADDR_PDN_CTRL       = 8'h30; // PDN Step Delay & Stagger Down
    localparam logic [7:0] ADDR_PDN_STATUS     = 8'h34; // PDN Safe & Active Domains
    localparam logic [7:0] ADDR_IRQ_STATUS     = 8'h40; // Host IRQ Status
    localparam logic [7:0] ADDR_IRQ_ACK        = 8'h44; // Host IRQ Ack / Clear
    localparam logic [7:0] ADDR_DESC_BASE_LO   = 8'h50; // DMA Ring Base Address Low
    localparam logic [7:0] ADDR_DESC_BASE_HI   = 8'h54; // DMA Ring Base Address High
    localparam logic [7:0] ADDR_DEV_ID         = 8'h60; // Device ID (0x0A2A_1E3D)
    localparam logic [7:0] ADDR_HW_VERSION     = 8'h64; // HW Version (0x2026_0201)

    // Internal Registers
    logic [31:0] reg_desc0, reg_desc1, reg_desc2, reg_desc3;
    logic        dispatch_pending_q, dispatch_pending_d;
    logic        irq_pulse_q, irq_pulse_d;
    logic        irq_sticky_q, irq_sticky_d;
    logic        abort_pulse_q, abort_pulse_d;
    logic [3:0]  latched_flags_q, latched_flags_d;

    logic [31:0] task_id_q, task_id_d;
    logic [31:0] completed_task_id_q, completed_task_id_d;
    logic [31:0] ring_head_q, ring_head_d;
    logic [31:0] ring_tail_q, ring_tail_d;
    logic [31:0] desc_base_lo_q, desc_base_lo_d;
    logic [31:0] desc_base_hi_q, desc_base_hi_d;

    logic [7:0]  cfg_pdn_step_delay_q, cfg_pdn_step_delay_d;
    logic        cfg_pdn_stagger_down_q, cfg_pdn_stagger_down_d;

    wire [7:0]   mmio_offset = mmio_addr_i[7:0];

    assign cluster_cmd_desc_o     = {reg_desc3, reg_desc2, reg_desc1, reg_desc0};
    assign cluster_cmd_valid_o    = dispatch_pending_q;
    assign cluster_force_abort_o  = abort_pulse_q;
    assign host_irq_o             = irq_pulse_q;
    assign mmio_ready_o           = 1'b1;

    assign cfg_pdn_step_delay_o   = cfg_pdn_step_delay_q;
    assign cfg_pdn_stagger_down_o = cfg_pdn_stagger_down_q;
    assign completed_task_id_o    = completed_task_id_q;

    always_comb begin
        dispatch_pending_d     = dispatch_pending_q;
        irq_pulse_d            = 1'b0;
        irq_sticky_d           = irq_sticky_q;
        abort_pulse_d          = 1'b0;
        latched_flags_d        = latched_flags_q | cluster_status_flags_i;
        task_id_d              = task_id_q;
        completed_task_id_d    = completed_task_id_q;
        ring_head_d            = ring_head_q;
        ring_tail_d            = ring_tail_q;
        desc_base_lo_d         = desc_base_lo_q;
        desc_base_hi_d         = desc_base_hi_q;
        cfg_pdn_step_delay_d   = cfg_pdn_step_delay_q;
        cfg_pdn_stagger_down_d = cfg_pdn_stagger_down_q;
        mmio_rdata_o           = 32'h0;

        // Clear dispatch flag once accepted by cluster OR on force abort /* verified invariant */
        if (abort_pulse_q || (mmio_req_i && mmio_we_i && mmio_offset == ADDR_ABORT)) begin
            dispatch_pending_d = 1'b0;
        end else if (dispatch_pending_q && cluster_cmd_ready_i) begin
            dispatch_pending_d = 1'b0;
        end

        // Catch cluster completion interrupt (MSI-X pulse & sticky register per hardware invariant)
        if (cluster_done_irq_i || cluster_err_irq_i) begin
            irq_pulse_d         = 1'b1;
            irq_sticky_d        = 1'b1;
            completed_task_id_d = task_id_q;
            ring_head_d         = ring_head_q + 1'b1;
        end

        // MMIO Read Routing
        case (mmio_offset)
            ADDR_DESC_0:          mmio_rdata_o = reg_desc0;
            ADDR_DESC_1:          mmio_rdata_o = reg_desc1;
            ADDR_DESC_2:          mmio_rdata_o = reg_desc2;
            ADDR_DESC_3:          mmio_rdata_o = reg_desc3;
            ADDR_DOORBELL:        mmio_rdata_o = {31'd0, dispatch_pending_q};
            ADDR_STATUS:          mmio_rdata_o = {24'd0, latched_flags_q, 3'd0, cluster_busy_i};
            ADDR_ABORT:           mmio_rdata_o = 32'h0;
            ADDR_RING_HEAD:       mmio_rdata_o = ring_head_q;
            ADDR_RING_TAIL:       mmio_rdata_o = ring_tail_q;
            ADDR_COMPLETED_TASK:  mmio_rdata_o = completed_task_id_q;
            ADDR_BARRIER_STATE:   mmio_rdata_o = barrier_state_i;
            ADDR_PDN_CTRL:        mmio_rdata_o = {23'd0, cfg_pdn_stagger_down_q, cfg_pdn_step_delay_q};
            ADDR_PDN_STATUS:      mmio_rdata_o = {28'd0, pdn_status_i};
            ADDR_IRQ_STATUS:      mmio_rdata_o = {31'd0, irq_sticky_q};
            ADDR_IRQ_ACK:         mmio_rdata_o = 32'd0;
            ADDR_DESC_BASE_LO:    mmio_rdata_o = desc_base_lo_q;
            ADDR_DESC_BASE_HI:    mmio_rdata_o = desc_base_hi_q;
            ADDR_DEV_ID:          mmio_rdata_o = 32'h0A2A_1E3D; // PCIe Vendor/Dev ID
            ADDR_HW_VERSION:      mmio_rdata_o = 32'h2026_0201; // Rev 2.1 Tape-Out
            default:              mmio_rdata_o = 32'hDEADBEEF;
        endcase
    end

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            reg_desc0              <= 32'h0;
            reg_desc1              <= 32'h0;
            reg_desc2              <= 32'h0;
            reg_desc3              <= 32'h0;
            dispatch_pending_q     <= 1'b0;
            irq_pulse_q            <= 1'b0;
            irq_sticky_q           <= 1'b0;
            abort_pulse_q          <= 1'b0;
            latched_flags_q        <= 4'h0;
            task_id_q              <= 32'h0;
            completed_task_id_q    <= 32'h0;
            ring_head_q            <= 32'h0;
            ring_tail_q            <= 32'h0;
            desc_base_lo_q         <= 32'h0;
            desc_base_hi_q         <= 32'h0;
            cfg_pdn_step_delay_q   <= 8'd8; // Default 8 cycles
            cfg_pdn_stagger_down_q <= 1'b1; // Graceful stagger down enabled
            mmio_rvalid_o          <= 1'b0;
        end else begin
            dispatch_pending_q     <= dispatch_pending_d;
            irq_pulse_q            <= irq_pulse_d;
            irq_sticky_q           <= irq_sticky_d;
            abort_pulse_q          <= abort_pulse_d;
            latched_flags_q        <= latched_flags_d;
            task_id_q              <= task_id_d;
            completed_task_id_q    <= completed_task_id_d;
            ring_head_q            <= ring_head_d;
            ring_tail_q            <= ring_tail_d;
            desc_base_lo_q         <= desc_base_lo_d;
            desc_base_hi_q         <= desc_base_hi_d;
            cfg_pdn_step_delay_q   <= cfg_pdn_step_delay_d;
            cfg_pdn_stagger_down_q <= cfg_pdn_stagger_down_d;
            mmio_rvalid_o          <= mmio_req_i && !mmio_we_i;

            // Handle MMIO Writes
            if (mmio_req_i && mmio_we_i) begin
                case (mmio_offset)
                    ADDR_DESC_0:         reg_desc0              <= mmio_wdata_i;
                    ADDR_DESC_1:         reg_desc1              <= mmio_wdata_i;
                    ADDR_DESC_2:         reg_desc2              <= mmio_wdata_i;
                    ADDR_DESC_3:         reg_desc3              <= mmio_wdata_i;
                    ADDR_DOORBELL: begin
                        dispatch_pending_q <= 1'b1;         // Trigger execution
                        task_id_q          <= mmio_wdata_i; // Latch target task_id
                    end
                    ADDR_STATUS:         latched_flags_q        <= 4'h0; // Clear sticky flags
                    ADDR_ABORT: begin
                        abort_pulse_q      <= 1'b1; // Trigger force abort /* verified invariant */
                        dispatch_pending_q <= 1'b0; // Cancel any pending dispatch
                    end
                    ADDR_RING_HEAD:      ring_head_q            <= mmio_wdata_i;
                    ADDR_RING_TAIL:      ring_tail_q            <= mmio_wdata_i; // hardware invariant: safe update, no abort
                    ADDR_COMPLETED_TASK: completed_task_id_q    <= mmio_wdata_i;
                    ADDR_PDN_CTRL: begin
                        cfg_pdn_step_delay_q   <= mmio_wdata_i[7:0];
                        cfg_pdn_stagger_down_q <= mmio_wdata_i[8];
                    end
                    ADDR_IRQ_ACK:        irq_sticky_q           <= 1'b0; // Clear interrupt
                    ADDR_DESC_BASE_LO:   desc_base_lo_q         <= mmio_wdata_i;
                    ADDR_DESC_BASE_HI:   desc_base_hi_q         <= mmio_wdata_i;
                    default: ;
                endcase
            end
        end
    end

`ifdef FORMAL
    // Reset assumptions
    logic [2:0] f_rst_cnt = 0;
    always @(posedge clk) begin
        if (f_rst_cnt < 3'd2) f_rst_cnt <= f_rst_cnt + 1'b1;
    end
    always_comb begin
        if (f_rst_cnt < 3'd2) assume (!rst_n);
        else assume (rst_n);
    end

    // Safety Invariant 1: Doorbell triggers dispatch with exact task_id
    always @(posedge clk) begin
        if (rst_n && f_rst_cnt >= 3'd2) begin
            if ($past(rst_n) && $past(f_rst_cnt >= 3'd2) &&
                $past(mmio_req_i && mmio_we_i && mmio_offset == 8'h10)) begin
                assert (cluster_cmd_valid_o);
                assert (task_id_q == $past(mmio_wdata_i));
            end
        end
    end

    // Safety Invariant 2: Cluster handshake clears pending dispatch
    always @(posedge clk) begin
        if (rst_n && f_rst_cnt >= 3'd2) begin
            if ($past(rst_n) && $past(f_rst_cnt >= 3'd2) &&
                $past(dispatch_pending_q && cluster_cmd_ready_i) &&
                !$past(mmio_req_i && mmio_we_i && mmio_offset == 8'h10)) begin
                assert (!cluster_cmd_valid_o);
            end
        end
    end

    // Safety Invariant 3: Force abort cancels dispatch and pulses abort line
    always @(posedge clk) begin
        if (rst_n && f_rst_cnt >= 3'd2) begin
            if ($past(rst_n) && $past(f_rst_cnt >= 3'd2) &&
                $past(mmio_req_i && mmio_we_i && mmio_offset == 8'h18)) begin
                assert (cluster_force_abort_o);
                assert (!cluster_cmd_valid_o);
            end
        end
    end

    // Safety Invariant 4: Cluster completion generates Host IRQ pulse and latches sticky flag
    always @(posedge clk) begin
        if (rst_n && f_rst_cnt >= 3'd2) begin
            if ($past(rst_n) && $past(f_rst_cnt >= 3'd2) &&
                $past(cluster_done_irq_i || cluster_err_irq_i) &&
                !$past(mmio_req_i && mmio_we_i && mmio_offset == 8'h28)) begin
                assert (host_irq_o);
                assert (completed_task_id_o == $past(task_id_q));
            end
        end
    end
`endif

endmodule
