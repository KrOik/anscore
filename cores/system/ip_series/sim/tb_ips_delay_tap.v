`timescale 1ns / 1ps
// tb_ips_delay_tap : production-line testbench for the programmable tap line.
//
// BEATS deterministic beats from the shared LCG stimulus contract, with the
// delay word reprogrammed through a sequence that deliberately exceeds
// MAX_DELAY (clamp path) and periodic stall windows (backpressure / drop
// accounting).  out_data is sampled one bit wider than PAY_W so a widened PAY_W
// reaches the digest.  Checks use === / !== only (trap T6); the expected stream
// is computed independently by models/ips_delay_tap.py (trap T1).
module tb_ips_delay_tap;

`include "ips_tb_common.vh"

localparam integer BEATS = 400;
localparam [31:0]  SEED  = 32'h517A1E05;

reg                rst_n;
reg                clk_en;
reg                in_valid;
reg  [11:0]        in_data;
reg                stall;
reg  [7:0]         delay_sel;
reg  [31:0]        state;
reg                stall_q;

wire [11:0]        out_data;
wire               out_valid;
wire               in_ready;
wire [7:0]         tap_index;
wire [7:0]         active_lat;
wire [7:0]         beat_count;
wire [7:0]         drop_count;
wire [7:0]         lat_events;
wire               drop_sticky;

// No #() override: the defaults are the shipped configuration.
ips_delay_tap dut (
    .clk        (ips_clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .in_valid   (in_valid),
    .in_data    (in_data),
    .stall      (stall),
    .delay_sel  (delay_sel),
    .out_data   (out_data),
    .out_valid  (out_valid),
    .in_ready   (in_ready),
    .tap_index  (tap_index),
    .active_lat (active_lat),
    .beat_count (beat_count),
    .drop_count (drop_count),
    .lat_events (lat_events),
    .drop_sticky(drop_sticky)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

function [7:0] dsel_at;
    input integer n;
    begin
        if (n < 60) begin
            dsel_at = 8'd0;
        end else if (n < 120) begin
            dsel_at = 8'd7;
        end else if (n < 180) begin
            dsel_at = 8'd15;
        end else if (n < 240) begin
            dsel_at = 8'd20;
        end else if (n < 300) begin
            dsel_at = 8'd3;
        end else begin
            dsel_at = 8'd255;
        end
    end
endfunction

function stalling;
    input integer n;
    begin
        stalling = (((n % 53) < 4) ? 1'b1 : 1'b0);
    end
endfunction

integer i;
reg     bad;

initial begin
    ips_fnv_reset();
    rst_n     = 1'b0;
    clk_en    = 1'b0;
    in_valid  = 1'b0;
    in_data   = 12'd0;
    stall     = 1'b0;
    delay_sel = 8'd0;
    state     = SEED;
    stall_q   = 1'b0;
    bad       = 1'b0;

    repeat (3) @(negedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(negedge ips_clk);

    clk_en    = 1'b1;
    state     = state * 32'd1664525 + 32'd1013904223;
    in_data   = state[11:0];
    in_valid  = ~state[0];
    stall     = stalling(0);
    delay_sel = dsel_at(0);
    stall_q   = stall;

    for (i = 0; i < BEATS; i = i + 1) begin
        @(negedge ips_clk);

        if (^{out_data, tap_index, active_lat, beat_count, drop_count,
              lat_events} === 1'bx)                                  bad = 1'b1;
        if (out_valid === 1'bx || in_ready === 1'bx ||
            drop_sticky === 1'bx)                                    bad = 1'b1;
        if (in_ready !== ~stall_q)                                   bad = 1'b1;
        if (drop_sticky === 1'b0 && drop_count !== 8'h00)            bad = 1'b1;

        ips_fnv_word({16'd0, tap_index, active_lat});
        ips_fnv_word({16'd0, beat_count, drop_count});
        ips_fnv_word({21'd0, lat_events, drop_sticky, in_ready, out_valid});
        ips_fnv_word({20'd0, out_data});

        state     = state * 32'd1664525 + 32'd1013904223;
        in_data   = state[11:0];
        in_valid  = ~state[0];
        stall     = stalling(i + 1);
        delay_sel = dsel_at(i + 1);
        stall_q   = stall;
    end

    clk_en   = 1'b0;
    stall    = 1'b0;
    in_valid = 1'b0;

    repeat (3) @(negedge ips_clk);
    ips_fnv_word(BEATS);

    ips_verdict(!bad, "ips_delay_tap");
end

endmodule
