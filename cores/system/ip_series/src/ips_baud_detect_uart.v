`timescale 1ns / 1ps
// ips_baud_detect_uart : UART receive-side baud estimator for the ip_series_20k
// production line.
//
// It learns the incoming bit rate from the length of the received 0 bits: every
// low run on `rx` is measured in input quanta (`tick`), the shortest credible run
// is the bit length, and the oversample tick the receiver's baud divider has to be
// reloaded with is that length divided by the oversampling factor.  No multiply,
// no real divider: the division is the shift OS_SHIFT.
//
// Board-free design: the quantum strobe `tick` is an input, exactly as in
// ips_one_wire_master, so models/ips_baud_detect_uart.py replays the measurement
// cycle-exactly.  No board timing evidence is claimed.
//
// Written contract (the golden model implements the same rules):
//   * `rx` is sampled on a tick only and every register moves on an enabled tick
//     only: a beat with tick low or clk_en low freezes the whole estimator, so the
//     run plan expressed in ticks stays aligned whatever the beat pattern does.
//     rx_q resets to 1'b1 because the line idles high.
//   * a high -> low transition starts a run with len = 8'd1; while the level stays
//     low len steps by one per tick and holds at LEN_MAX, so an over-long break
//     reports LEN_MAX instead of wrapping;
//   * a low -> high transition closes the run: run_valid pulses for that tick,
//     meas takes the closed length, len returns to 0 and state returns to S_IDLE.
//     max_len keeps the longest run ever closed, min_len the shortest *accepted*
//     run;
//   * the closed run is classified in this order:
//       len < GLITCH                     line noise: glitch_sticky latches, the
//                                        run is discarded and nothing steps;
//       len < RUN_MIN or len > RUN_MAX   out of range: range_sticky latches,
//                                        err_count steps, the agreement built so
//                                        far is dropped (agree = 0) and a locked
//                                        tracker unlocks (unlock_count steps);
//       otherwise                        the run is a credible 0 bit and feeds the
//                                        estimator below.  run_count steps for
//                                        every non-noise run, accepted or not.
//   * estimator, with bit_len the current bit-length estimate and
//     tick_est = bit_len >> OS_SHIFT the integer oversample tick:
//       not locked, agree = 0        the run seeds the estimate, agree = 3'd1;
//       not locked, agree != 0,
//             |len - bit_len| <= TOL the run agrees: the estimate tracks it, and
//                                    when agree + 1 >= LOCK_N it locks
//                                    (lock_valid pulses, lock_count steps,
//                                     agree returns to 0);
//             otherwise              the run disagrees: the estimate re-seeds,
//                                    agree = 3'd1;
//       locked, agreeing             the estimate tracks it and hold_count steps
//                                    (drift inside TOL is tolerated, that is what
//                                    keeps a slightly-off rate locked);
//       locked, disagreeing          the tracker unlocks (unlock_count steps) and
//                                    the run re-seeds, agree = 3'd1;
//   * `restart` clears the agreement (agree = 0) and, if the tracker was locked,
//     counts an unlock.  It is a request to re-acquire and never corrupts a run in
//     progress;
//   * every counter saturates and holds: err_count/lock_count/unlock_count/
//     hold_count at 4'hF, run_count at 6'h3F, agree at 3'd7.
//
// Lock/unlock accounting: lock_count counts acquisitions, unlock_count counts
// losses of lock (rate jump, out-of-range run or restart) and hold_count counts
// the runs that kept an established lock, so a suite can prove it actually locked
// and actually let go.
//
// Every register is gated by clk_en and rst_n is the active-low asynchronous
// reset, per docs/IP_CORE_SOP.md (trap T2).
module ips_baud_detect_uart #(
    parameter OS_SHIFT = 2,
    parameter RUN_MIN  = 8'd12,
    parameter RUN_MAX  = 8'd20,
    parameter LOCK_N   = 3'd3,
    parameter TOL      = 8'd3,
    parameter LEN_MAX  = 8'd60,
    parameter GLITCH   = 8'd3
)(
    input  wire       clk,
    input  wire       clk_en,
    input  wire       rst_n,

    input  wire       tick,
    input  wire       rx,
    input  wire       restart,

    output reg        locked,
    output reg  [1:0] state,
    output reg  [7:0] len,
    output reg  [7:0] meas,
    output reg  [7:0] bit_len,
    output reg  [7:0] min_len,
    output reg  [7:0] max_len,
    output reg  [7:0] tick_est,
    output reg  [2:0] agree,
    output reg  [5:0] run_count,
    output reg  [3:0] lock_count,
    output reg  [3:0] unlock_count,
    output reg  [3:0] hold_count,
    output reg  [3:0] err_count,
    output reg        rx_q,
    output reg        run_valid,
    output reg        lock_valid,
    output reg        glitch_sticky,
    output reg        range_sticky
);

localparam [1:0] S_IDLE = 2'd0;
localparam [1:0] S_LOW  = 2'd1;

localparam [2:0] AGREE_SEED = 3'd1;
localparam [5:0] RUN_SAT    = 6'h3F;

// rx_q is the previous sample and rx the new one, so a low run closes when the
// line goes low -> high and opens when it goes high -> low.
wire end_run = (!rx_q && rx);
wire bgn_run = (rx_q && !rx);

wire       in_range = (len >= RUN_MIN) && (len <= RUN_MAX);
wire       noise    = (len < GLITCH);
wire [7:0] delta    = (len > bit_len) ? (len - bit_len) : (bit_len - len);
wire       near     = (delta <= TOL);
wire [3:0] agree_nx = {1'b0, agree} + 4'd1;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        locked       <= 1'b0;
        state        <= S_IDLE;
        len          <= 8'd0;
        meas         <= 8'h00;
        bit_len      <= 8'h00;
        min_len      <= 8'hFF;
        max_len      <= 8'h00;
        tick_est     <= 8'h00;
        agree        <= 3'd0;
        run_count    <= 6'd0;
        lock_count   <= 4'h0;
        unlock_count <= 4'h0;
        hold_count   <= 4'h0;
        err_count    <= 4'h0;
        rx_q         <= 1'b1;
        run_valid    <= 1'b0;
        lock_valid   <= 1'b0;
        glitch_sticky<= 1'b0;
        range_sticky <= 1'b0;
    end else if (clk_en) begin
        if (tick) begin
            run_valid  <= 1'b0;
            lock_valid <= 1'b0;
            rx_q       <= rx;
            if (end_run) begin
                state     <= S_IDLE;
                len       <= 8'd0;
                meas      <= len;
                run_valid <= 1'b1;
                if (len > max_len) begin
                    max_len <= len;
                end
                if (noise) begin
                    glitch_sticky <= 1'b1;
                end else begin
                    if (run_count != RUN_SAT) begin
                        run_count <= run_count + 6'd1;
                    end
                    if (!in_range) begin
                        range_sticky <= 1'b1;
                        if (err_count != 4'hF) begin
                            err_count <= err_count + 4'd1;
                        end
                        agree <= 3'd0;
                        if (locked) begin
                            locked <= 1'b0;
                            if (unlock_count != 4'hF) begin
                                unlock_count <= unlock_count + 4'd1;
                            end
                        end
                    end else begin
                        if (len < min_len) begin
                            min_len <= len;
                        end
                        tick_est <= len >> OS_SHIFT;
                        if (locked) begin
                            if (near) begin
                                bit_len <= len;
                                if (hold_count != 4'hF) begin
                                    hold_count <= hold_count + 4'd1;
                                end
                            end else begin
                                locked  <= 1'b0;
                                bit_len <= len;
                                agree   <= AGREE_SEED;
                                if (unlock_count != 4'hF) begin
                                    unlock_count <= unlock_count + 4'd1;
                                end
                            end
                        end else if (agree == 3'd0) begin
                            bit_len <= len;
                            agree   <= AGREE_SEED;
                        end else if (near) begin
                            bit_len <= len;
                            if (agree_nx >= LOCK_N) begin
                                locked     <= 1'b1;
                                lock_valid <= 1'b1;
                                agree      <= 3'd0;
                                if (lock_count != 4'hF) begin
                                    lock_count <= lock_count + 4'd1;
                                end
                            end else begin
                                agree <= agree + 3'd1;
                            end
                        end else begin
                            bit_len <= len;
                            agree   <= AGREE_SEED;
                        end
                    end
                end
            end else if (bgn_run) begin
                state <= S_LOW;
                len   <= 8'd1;
            end else if (state == S_LOW) begin
                if (len != LEN_MAX) begin
                    len <= len + 8'd1;
                end
            end
            if (restart) begin
                agree <= 3'd0;
                if (locked) begin
                    locked <= 1'b0;
                    if (unlock_count != 4'hF) begin
                        unlock_count <= unlock_count + 4'd1;
                    end
                end
            end
        end
    end
end

endmodule
