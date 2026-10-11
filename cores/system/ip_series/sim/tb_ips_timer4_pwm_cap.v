`timescale 1ns / 1ps
// tb_ips_timer4_pwm_cap : production-line testbench for the four-channel timer.
//
// Clocking: clk_en comes from a free-running 6-state divisor in the testbench;
// exactly one enabled beat is produced per loop iteration, which is the step the
// Python golden model replays.
//
// Stimulus contract shared with models/ips_timer4_pwm_cap.py (one LCG step per
// enabled beat):
//     state    = state * 1664525 + 1013904223  (mod 2**32), starting from SEED
//     ch_sel   = state[3:0]
//     pin_hold = state[3] ^ state[1], re-rolled every 8 beats, drives cap_pin so a
//                measurement sometimes runs into the capture watchdog instead of
//                being closed by the very next sample
//     cap_pin  = pin_hold
//     run_hold = state[7:4], re-rolled only on beats 0, 32, 64, ... so a channel
//                keeps running long enough to arm and to wrap several times
//     run_req  = run_hold | 4'hC
//     wr_addr  = state[13:10]
//     wr_stb   = state[14]
//     wr_data  = {4'h0, ~state[1:0]}  (the 0..3 written into PRE/PER/DTY keeps
//                prescale ticks and period wraps dense)
// Only DUT outputs are folded; every check uses === (docs/IP_CORE_SOP.md trap T6)
// and the run ends on a fixed edge count rather than a DUT condition.
module tb_ips_timer4_pwm_cap;

`include "ips_tb_common.vh"

localparam integer BEATS = 260;
localparam [31:0]  SEED  = 32'h3E91A705;
localparam [3:0]   DIV   = 4'd5;

reg [3:0]  div_q;
wire       tick;
reg        rst_n;
reg [3:0]  ch_sel;
reg        cap_pin;
reg        pin_hold;
reg [3:0]  run_req;
reg [3:0]  wr_addr;
reg        wr_stb;
reg [7:0]  wr_data;
reg [31:0] state;
reg [3:0]  run_hold;

wire [3:0]  pwm_out;
wire [7:0]  rd_data;
wire [3:0]  cap_pend;
wire [3:0]  ovf_pend;
wire [3:0]  trans_pend;
wire [3:0]  run_r;
wire [3:0]  arm_r;
wire        cap_busy;
wire [3:0]  ph_r;
wire [3:0]  vec_out;
wire [1:0]  cap_hold;
wire [1:0]  cur_ch;
wire [7:0]  tick_count;
wire [7:0]  cap_count;
wire [3:0]  cap_max;
wire [3:0]  cap_min;
wire [3:0]  last_width;
wire [3:0]  err_count;
wire        err_sticky;
wire        cmp_irq;

assign tick = (div_q == 4'd0);

always @(posedge ips_clk) begin
    div_q <= (div_q == DIV) ? 4'd0 : (div_q + 4'd1);
end

ips_timer4_pwm_cap dut (
    .clk        (ips_clk),
    .clk_en     (tick),
    .rst_n      (rst_n),
    .ch_sel     (ch_sel),
    .cap_pin    (cap_pin),
    .run_req    (run_req),
    .wr_addr    (wr_addr),
    .wr_stb     (wr_stb),
    .wr_data    (wr_data),
    .pwm_out    (pwm_out),
    .rd_data    (rd_data),
    .cap_pend   (cap_pend),
    .ovf_pend   (ovf_pend),
    .trans_pend (trans_pend),
    .run_r      (run_r),
    .arm_r      (arm_r),
    .cap_busy   (cap_busy),
    .ph_r       (ph_r),
    .vec_out    (vec_out),
    .cap_hold   (cap_hold),
    .cur_ch     (cur_ch),
    .tick_count (tick_count),
    .cap_count  (cap_count),
    .cap_max    (cap_max),
    .cap_min    (cap_min),
    .last_width (last_width),
    .err_count  (err_count),
    .err_sticky (err_sticky),
    .cmp_irq    (cmp_irq)
);

always @(posedge ips_clk) begin
    if (tick === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

integer i;
reg     bad;

task beat;
begin
    @(negedge ips_clk);
    while (tick !== 1'b1) begin
        @(negedge ips_clk);
    end
end
endtask

initial begin
    ips_fnv_reset();
    rst_n     = 1'b0;
    div_q     = 4'd0;
    ch_sel    = 4'h0;
    cap_pin   = 1'b0;
    pin_hold  = 1'b0;
    pin_hold  = 1'b0;
    run_req   = 4'h0;
    wr_addr   = 4'h0;
    wr_stb    = 1'b0;
    wr_data   = 8'h00;
    state     = SEED;
    run_hold  = 4'h0;
    bad       = 1'b0;

    repeat (4) @(negedge ips_clk);
    // Release reset just after an enabled edge the core still spent in reset, so
    // the first enabled beat of the loop is the first beat the model replays.
    beat;
    @(negedge ips_clk);
    rst_n = 1'b1;

    for (i = 0; i < BEATS; i = i + 1) begin
        beat;
        state   = state * 32'd1664525 + 32'd1013904223;
        if ((i % 32) == 0) begin
            run_hold = state[7:4];
        end
        ch_sel  = state[3:0];
        if ((i % 8) == 0) begin
            pin_hold = state[3] ^ state[1];
        end
        cap_pin = pin_hold;
        run_req = run_hold | 4'hC;
        wr_addr = state[13:10];
        wr_stb  = state[14];
        wr_data = {4'h0, ~state[1:0]};

        @(negedge ips_clk);

        if ((^rd_data === 1'bx) || (^cap_max === 1'bx) || (^cap_min === 1'bx) ||
            (^last_width === 1'bx) || (^tick_count === 1'bx) || (^vec_out === 1'bx) ||
            (^pwm_out === 1'bx) || (^cap_count === 1'bx) || (^err_count === 1'bx) ||
            (^cap_hold === 1'bx) || (cap_busy === 1'bx) || (err_sticky === 1'bx) ||
            (cmp_irq === 1'bx)) begin
            bad = 1'b1;
        end
        if (err_sticky === 1'b0 && err_count !== 4'h0) begin
            bad = 1'b1;
        end
        if (cap_count !== 8'h00 && cap_max < cap_min) begin
            bad = 1'b1;
        end
        if (cmp_irq === 1'b1 && tick_count === 8'h00) begin
            bad = 1'b1;
        end
        if (arm_r === 4'hF && run_r === 4'h0) begin
            bad = 1'b1;
        end

        ips_fnv_word({24'd0, rd_data});
        ips_fnv_word({3'd0, cap_busy, run_r, arm_r, ph_r, cap_pend, ovf_pend,
                      trans_pend, pwm_out});
        ips_fnv_word({12'd0, cap_max, cap_min, last_width, cap_count});
        ips_fnv_word({24'd0, cap_hold, vec_out, err_sticky, cmp_irq});
        ips_fnv_word({24'd0, tick_count});
        if ((i % 8) == 7) begin
            ips_fnv_word({28'd0, err_count});
        end
    end

    repeat (2) @(negedge ips_clk);
    ips_fnv_word({28'd0, err_count});
    ips_fnv_word({24'd0, tick_count});
    ips_fnv_word(BEATS);

    ips_verdict(!bad, "ips_timer4_pwm_cap");
end

endmodule
