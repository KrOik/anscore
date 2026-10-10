`timescale 1ns / 1ps
// tb_ips_cdc_reset_bridge : production-line testbench for the reset bridge.
//
// One physical clock carries two enable streams (src_tick every 7th beat,
// dst_tick every 5th beat), which is the series model of two unrelated clocks
// (docs/IP_CORE_SOP.md trap T13).  BEATS deterministic beats are driven, the
// arst_req pattern deliberately contains narrow single-beat pulses and long
// re-assert stretches so the glitch path and the event counters are exercised.
// Only registered DUT output state is folded into the FNV-1a digest; the
// expected stream lives in models/ips_cdc_reset_bridge.py (trap T1).
module tb_ips_cdc_reset_bridge;

`include "ips_tb_common.vh"

localparam integer BEATS = 600;

reg rst_n;
reg clk_en;
reg src_tick;
reg dst_tick;
reg arst_req;

wire        src_ok;
wire        por_done;
wire [7:0]  por_count;
wire        sync1;
wire        sync2;
wire        rst_out_n;
wire        released;
wire        glitch_sticky;
wire [3:0]  glitch_count;
wire [3:0]  rst_events;

// No #() override: the TB exercises the declared default geometry, which is the
// shipped configuration the manifest records.  por_count is sampled one bit
// wider than POR_W so a widened POR_W changes the folded word.
ips_cdc_reset_bridge dut (
    .clk          (ips_clk),
    .clk_en       (clk_en),
    .rst_n        (rst_n),
    .src_tick     (src_tick),
    .dst_tick     (dst_tick),
    .arst_req     (arst_req),
    .src_ok       (src_ok),
    .por_done     (por_done),
    .por_count    (por_count),
    .sync1        (sync1),
    .sync2        (sync2),
    .rst_out_n    (rst_out_n),
    .released     (released),
    .glitch_sticky(glitch_sticky),
    .glitch_count (glitch_count),
    .rst_events   (rst_events)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

function arst_at;
    input integer n;
    begin
        arst_at = (((n >= 60 && n <= 64) || (n == 120) || (n >= 200 && n <= 235) ||
                    (n == 300) || (n == 302) || (n >= 400 && n <= 404) ||
                    (n == 500) || (n == 520) || (n >= 560 && n <= 566)) ? 1'b1 : 1'b0);
    end
endfunction

integer i;
reg     bad;

initial begin
    ips_fnv_reset();
    rst_n    = 1'b0;
    clk_en   = 1'b0;
    src_tick = 1'b0;
    dst_tick = 1'b0;
    arst_req = 1'b0;
    bad      = 1'b0;

    repeat (3) @(negedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(negedge ips_clk);

    clk_en   = 1'b1;
    src_tick = 1'b1;
    dst_tick = 1'b1;
    arst_req = arst_at(0);

    for (i = 0; i < BEATS; i = i + 1) begin
        @(negedge ips_clk);

        if (^{por_count, glitch_count, rst_events} === 1'bx)      bad = 1'b1;
        if (released === 1'bx || rst_out_n === 1'bx)              bad = 1'b1;
        if (rst_out_n === 1'b1 && sync2 === 1'b0)                bad = 1'b1;
        if (released === 1'b1 && sync2 === 1'b0)                 bad = 1'b1;
        if (released === 1'b1 && por_done === 1'b0)              bad = 1'b1;
        if (src_ok === 1'b1 && por_done === 1'b0)                bad = 1'b1;
        if (glitch_sticky === 1'b0 && glitch_count !== 4'h0)     bad = 1'b1;

        ips_fnv_word({25'd0, por_done, src_ok, sync1, sync2,
                      released, glitch_sticky, rst_out_n});
        ips_fnv_word({24'd0, por_count});
        ips_fnv_word({24'd0, glitch_count, rst_events});

        src_tick = (((i + 1) % 7) == 0);
        dst_tick = (((i + 1) % 5) == 0);
        arst_req = arst_at(i + 1);
    end

    clk_en   = 1'b0;
    src_tick = 1'b0;
    dst_tick = 1'b0;
    arst_req = 1'b0;

    repeat (3) @(negedge ips_clk);
    ips_fnv_word(BEATS);

    ips_verdict(!bad, "ips_cdc_reset_bridge");
end

endmodule
