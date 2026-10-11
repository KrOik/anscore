`timescale 1ns / 1ps
// ips_ir_nec_rx : NEC infrared frame receiver for the ip_series_20k line.
//
// The timing base is an explicit tick input and the pin is sampled only on a
// tick, so models/ips_ir_nec_rx.py replays every measured width and every
// transition cycle-exactly; nothing here free-runs against an internal clock.
//
// Written contract:
//   * ir_in is the demodulated receiver pin: 1 = no carrier (space), 0 = carrier
//     burst (mark).  Widths are counted in ticks, never in clocks.
//   * on a tick the level is sampled.  If it is unchanged the running width
//     increments (saturating at W_MAX); if it changed, the finished segment is
//     committed with its width, the width restarts at 1 and the state machine
//     classifies the segment.
//   * a segment is accepted when its width lies within TOL ticks of the target
//     for that stage: TICK_LEAD for the 9 ms start burst, LEAD_SP for the 4.5 ms
//     start space, REPEAT_SP for the 2.25 ms repeat space, BIT_MARK for every bit
//     burst, BIT0_SP / BIT1_SP for the two data spaces.  The two data windows are
//     disjoint, and the 0-window wins if a mis-tuned build makes them overlap.
//   * 32 accepted bits, first received bit in bit 31, form {addr, ~addr, cmd,
//     ~cmd}.  A bit space is measured up to the burst that follows it, so the
//     frame is closed by a validated stop burst: the 32nd bit is published when
//     that burst starts and the burst itself is then checked against BIT_MARK in
//     the tail state.  The frame is published (rx_word, addr, cmd, frame_valid,
//     frame_count) only when both inverse pairs XOR to 8'hFF; otherwise
//     crc_sticky latches and crc_count steps.
//   * a width outside every window at an active stage is a timing error: the
//     partial frame is dropped, bit_index restarts, timing_sticky latches and
//     timing_count steps.  An idle space is never an error and an unvalidated
//     burst is one.
//   * a repeat code sets repeat_valid and steps repeat_count; like a data frame
//     it is closed by a burst that the tail state validates against BIT_MARK,
//     after which the receiver is back in idle.
//   * frame_valid / repeat_valid are one-tick pulses.  With tick low, or clk_en
//     low, the measurement freezes and resumes where it stopped.
//
// Every register is gated by clk_en and rst_n is the active-low asynchronous
// reset, per docs/IP_CORE_SOP.md (trap T2).
module ips_ir_nec_rx #(
    parameter TICK_LEAD = 48,
    parameter LEAD_SP = 24,
    parameter REPEAT_SP = 12,
    parameter BIT0_SP = 6,
    parameter BIT1_SP = 12,
    parameter TOL = 2
)(
    input  wire       clk,
    input  wire       clk_en,
    input  wire       rst_n,
    input  wire       tick,
    input  wire       ir_in,
    output reg [31:0] rx_word,
    output reg [7:0]  addr,
    output reg [7:0]  cmd,
    output reg        frame_valid,
    output reg        repeat_valid,
    output reg [2:0]  state,
    output reg [5:0]  bit_index,
    output reg [5:0]  width,
    output reg        timing_sticky,
    output reg        crc_sticky,
    output reg [7:0]  timing_count,
    output reg [7:0]  crc_count,
    output reg [7:0]  frame_count,
    output reg [7:0]  repeat_count
);

localparam integer BIT_MARK = 3;
localparam integer BITS = 32;
localparam [5:0] W_MAX = 6'h3F;
localparam [5:0] BIT_LAST = BITS - 1;

localparam [2:0] S_IDLE = 3'd0;
localparam [2:0] S_LEAD_SP = 3'd1;
localparam [2:0] S_BMARK = 3'd2;
localparam [2:0] S_BSPACE = 3'd3;
localparam [2:0] S_TAIL = 3'd4;

reg ir_q;

wire [5:0] wq = width;
wire mk_lead = (wq >= (TICK_LEAD - TOL)) && (wq <= (TICK_LEAD + TOL));
wire sp_lead = (wq >= (LEAD_SP - TOL)) && (wq <= (LEAD_SP + TOL));
wire sp_rep  = (wq >= (REPEAT_SP - TOL)) && (wq <= (REPEAT_SP + TOL));
wire mk_bit  = (wq >= (BIT_MARK - TOL)) && (wq <= (BIT_MARK + TOL));
wire sp_b0   = (wq >= (BIT0_SP - TOL)) && (wq <= (BIT0_SP + TOL));
wire sp_b1   = (wq >= (BIT1_SP - TOL)) && (wq <= (BIT1_SP + TOL));

wire       burst   = ~ir_q;
wire       bit_val = sp_b0 ? 1'b0 : 1'b1;
wire       acc_bit = sp_b0 || sp_b1;
wire [31:0] nxt_word = {rx_word[30:0], bit_val};
wire       crc_ok = ((nxt_word[31:24] ^ nxt_word[23:16]) == 8'hFF) &&
                    ((nxt_word[15:8] ^ nxt_word[7:0]) == 8'hFF);

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        rx_word       <= 32'h00000000;
        addr          <= 8'h00;
        cmd           <= 8'h00;
        frame_valid   <= 1'b0;
        repeat_valid  <= 1'b0;
        state         <= S_IDLE;
        bit_index     <= 6'd0;
        width         <= 6'd0;
        ir_q          <= 1'b1;
        timing_sticky <= 1'b0;
        crc_sticky    <= 1'b0;
        timing_count  <= 8'h00;
        crc_count     <= 8'h00;
        frame_count   <= 8'h00;
        repeat_count  <= 8'h00;
    end else if (clk_en) begin
        if (tick) begin
            frame_valid  <= 1'b0;
            repeat_valid <= 1'b0;
            ir_q         <= ir_in;
            if (ir_in != ir_q) begin
                width <= 6'd1;
                case (state)
                    S_IDLE: begin
                        if (burst && !mk_lead) begin
                            timing_sticky <= 1'b1;
                            if (timing_count != 8'hFF) begin
                                timing_count <= timing_count + 8'h01;
                            end
                        end else if (burst && mk_lead) begin
                            state <= S_LEAD_SP;
                        end
                    end
                    S_LEAD_SP: begin
                        if (!burst && sp_lead) begin
                            state     <= S_BMARK;
                            bit_index <= 6'd0;
                        end else if (!burst && sp_rep) begin
                            state        <= S_TAIL;
                            repeat_valid <= 1'b1;
                            if (repeat_count != 8'hFF) begin
                                repeat_count <= repeat_count + 8'h01;
                            end
                        end else begin
                            state         <= S_IDLE;
                            timing_sticky <= 1'b1;
                            if (timing_count != 8'hFF) begin
                                timing_count <= timing_count + 8'h01;
                            end
                        end
                    end
                    S_BMARK: begin
                        if (burst && mk_bit) begin
                            state <= S_BSPACE;
                        end else begin
                            state         <= S_IDLE;
                            bit_index     <= 6'd0;
                            timing_sticky <= 1'b1;
                            if (timing_count != 8'hFF) begin
                                timing_count <= timing_count + 8'h01;
                            end
                        end
                    end
                    S_BSPACE: begin
                        if (!burst && acc_bit) begin
                            rx_word <= nxt_word;
                            if (bit_index == BIT_LAST) begin
                                state     <= S_TAIL;
                                bit_index <= 6'd0;
                                if (crc_ok) begin
                                    addr          <= nxt_word[31:24];
                                    cmd           <= nxt_word[15:8];
                                    frame_valid   <= 1'b1;
                                    if (frame_count != 8'hFF) begin
                                        frame_count <= frame_count + 8'h01;
                                    end
                                end else begin
                                    crc_sticky <= 1'b1;
                                    if (crc_count != 8'hFF) begin
                                        crc_count <= crc_count + 8'h01;
                                    end
                                end
                            end else begin
                                bit_index <= bit_index + 6'd1;
                                state     <= S_BMARK;
                            end
                        end else begin
                            state         <= S_IDLE;
                            bit_index     <= 6'd0;
                            timing_sticky <= 1'b1;
                            if (timing_count != 8'hFF) begin
                                timing_count <= timing_count + 8'h01;
                            end
                        end
                    end
                    S_TAIL: begin
                        if (burst && mk_bit) begin
                            state <= S_IDLE;
                        end else if (burst) begin
                            state         <= S_IDLE;
                            timing_sticky <= 1'b1;
                            if (timing_count != 8'hFF) begin
                                timing_count <= timing_count + 8'h01;
                            end
                        end
                    end
                    default: begin
                        state <= S_IDLE;
                    end
                endcase
            end else if (width != W_MAX) begin
                width <= width + 6'd1;
            end
        end
    end
end

endmodule
