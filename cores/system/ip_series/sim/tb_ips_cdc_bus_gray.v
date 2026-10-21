`timescale 1ns / 1ps
// tb_ips_cdc_bus_gray : production-line testbench for the Gray pointer crossing.
//
// src_tick is a free-running divisor mod 7 and dst_tick mod 5 on one physical
// clock, which is the series model of two unrelated clocks.  src_step is 1 while
// the source is settling and then deliberately takes 2 and 3 sized steps so the
// destination sees multi-bit Gray deltas and the non-atomic crossing detector,
// its sticky flag and its counters all land in the digest.  Every PTR_W derived
// bus is sampled two bits wider than the default so a widened PTR_W reaches the
// digest; checks use === / !== only (trap T6).  models/ips_cdc_bus_gray.py
// computes the expected stream independently (trap T1).
module tb_ips_cdc_bus_gray;

`include "ips_tb_common.vh"

localparam integer BEATS = 500;

reg        rst_n;
reg        clk_en;
reg        src_tick;
reg        dst_tick;
reg [5:0]  src_step;
reg        src_tick_q;
reg        dst_tick_q;
reg [5:0]  bin_ptr_p;
reg [5:0]  gray_q_p;
reg [5:0]  sync1_p;
reg [5:0]  sync2_p;

wire [5:0] bin_ptr;
wire [5:0] gray_q;
wire [5:0] sync1;
wire [5:0] sync2;
wire [5:0] bin_dec;
wire       err_sticky;
wire [3:0] err_count;
wire [3:0] sync_count;
wire [3:0] hold_count;

// No #() override: the TB exercises the declared default geometry.
ips_cdc_bus_gray dut (
    .clk        (ips_clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .src_tick   (src_tick),
    .dst_tick   (dst_tick),
    .src_step   (src_step),
    .bin_ptr    (bin_ptr),
    .gray_q     (gray_q),
    .sync1      (sync1),
    .sync2      (sync2),
    .bin_dec    (bin_dec),
    .err_sticky (err_sticky),
    .err_count  (err_count),
    .sync_count (sync_count),
    .hold_count (hold_count)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

function [5:0] step_at;
    input integer n;
    begin
        if (n < 40) begin
            step_at = 6'd1;
        end else if ((n % 7) == 2) begin
            step_at = 6'd2;
        end else if ((n % 13) == 5) begin
            step_at = 6'd3;
        end else begin
            step_at = 6'd1;
        end
    end
endfunction

task drive_beat;
    input integer n;
    begin
        src_tick = (((n % 7) == 0) ? 1'b1 : 1'b0);
        dst_tick = (((n % 5) == 0) ? 1'b1 : 1'b0);
        src_step = step_at(n);
    end
endtask

integer i;
reg     bad;

initial begin
    ips_fnv_reset();
    rst_n       = 1'b0;
    clk_en      = 1'b0;
    src_tick    = 1'b0;
    dst_tick    = 1'b0;
    src_step    = 6'd1;
    src_tick_q  = 1'b0;
    dst_tick_q  = 1'b0;
    bin_ptr_p   = 6'd0;
    gray_q_p    = 6'd0;
    sync1_p     = 6'd0;
    sync2_p     = 6'd0;
    bad         = 1'b0;

    repeat (3) @(negedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(negedge ips_clk);

    clk_en = 1'b1;
    drive_beat(0);
    src_tick_q = src_tick;
    dst_tick_q = dst_tick;

    for (i = 0; i < BEATS; i = i + 1) begin
        @(negedge ips_clk);

        if (^{bin_ptr, gray_q, sync1, sync2, bin_dec} === 1'bx)  bad = 1'b1;
        if (^{err_count, sync_count, hold_count} === 1'bx)       bad = 1'b1;
        if (err_sticky === 1'bx)                                bad = 1'b1;
        if (err_sticky === 1'b0 && err_count !== 4'h0)          bad = 1'b1;
        if (!src_tick_q && bin_ptr !== bin_ptr_p)               bad = 1'b1;
        if (!src_tick_q && gray_q !== gray_q_p)                 bad = 1'b1;
        if (dst_tick_q) begin
            if (sync1 !== gray_q_p)                             bad = 1'b1;
            if (sync2 !== sync1_p)                              bad = 1'b1;
        end else begin
            if (sync1 !== sync1_p)                              bad = 1'b1;
            if (sync2 !== sync2_p)                              bad = 1'b1;
        end

        ips_fnv_word({20'd0, bin_ptr, gray_q});
        ips_fnv_word({20'd0, sync1, sync2});
        ips_fnv_word({21'd0, err_sticky, bin_dec, err_count});
        ips_fnv_word({24'd0, sync_count, hold_count});

        bin_ptr_p  = bin_ptr;
        gray_q_p   = gray_q;
        sync1_p    = sync1;
        sync2_p    = sync2;
        drive_beat(i + 1);
        src_tick_q = src_tick;
        dst_tick_q = dst_tick;
    end

    clk_en   = 1'b0;
    src_tick = 1'b0;
    dst_tick = 1'b0;

    repeat (3) @(negedge ips_clk);
    ips_fnv_word(BEATS);

    ips_verdict(!bad, "ips_cdc_bus_gray");
end

endmodule
