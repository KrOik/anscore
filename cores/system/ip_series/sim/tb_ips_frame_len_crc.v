`timescale 1ns / 1ps
// tb_ips_frame_len_crc : production-line testbench for the length-prefixed
// framer/deframer core.
//
// Emits 96 deterministically scheduled frames covering the good path (including
// the zero-length and MAX_LEN boundaries), over-length rejection, truncated
// frames (last marker on the length byte and inside the payload), corrupted check
// bytes, in-frame restart pulses, idle gap beats and one clk_en-disabled window
// where the core must not advance at all (docs/IP_CORE_SOP.md trap T2).
// Only DUT outputs are folded into the FNV word stream; the expected stream is
// NOT written here -- models/ips_frame_len_crc.py computes it independently from
// the documented framing contract (trap T1).  Verdicts use === so X can never
// look like a pass (trap T6).
module tb_ips_frame_len_crc;

`include "ips_tb_common.vh"

localparam integer NFRAMES    = 96;
localparam integer MIN_BEATS  = 200;
localparam [31:0]  SEED       = 32'h5A17C0DE;
// The testbench exercises the core's declared defaults, so it mirrors them here
// instead of overriding #() on the instance.
localparam [7:0]   LEN_MAX_TB = 8'd20;
localparam [7:0]   FLIP_TB    = 8'h5A;

function [7:0] tb_crc_byte;
    input [7:0] c_in;
    input [7:0] d_in;
    integer i;
    reg [7:0] c;
    begin
        c = c_in ^ d_in;
        for (i = 0; i < 8; i = i + 1) begin
            if (c[7]) c = {c[6:0], 1'b0} ^ 8'h07;
            else      c = {c[6:0], 1'b0};
        end
        tb_crc_byte = c;
    end
endfunction

function [7:0] tb_frame_crc;
    input [7:0] len_field;
    input [31:0] fst;
    input integer nf;
    integer j;
    reg [7:0] c;
    begin
        c = 8'hFF;
        c = tb_crc_byte(c, len_field);
        for (j = 0; j < nf; j = j + 1) begin
            c = tb_crc_byte(c, fst[7:0] ^ j[7:0] ^ 8'h3D);
        end
        tb_frame_crc = c;
    end
endfunction

reg                 rst_n;
reg                 clk_en;
reg                 in_valid;
reg                 in_start;
reg                 in_last;
reg  [7:0]          in_byte;

wire                in_ready;
wire                out_valid;
wire                out_ok;
wire [7:0]          out_len;
wire [7:0]          out_crc;
wire [7:0]          out_recv_crc;
wire [7:0]          crc_run;
wire [3:0]          err_sticky;
wire [3:0]          cnt_good;
wire [3:0]          cnt_bad_crc;
wire [3:0]          cnt_over_len;
wire [3:0]          cnt_trunc;
wire [3:0]          cnt_restart;
wire [4:0]          cnt_sat;

ips_frame_len_crc dut (
    .clk          (ips_clk),
    .clk_en       (clk_en),
    .rst_n        (rst_n),
    .in_valid     (in_valid),
    .in_start     (in_start),
    .in_last      (in_last),
    .in_byte      (in_byte),
    .in_ready     (in_ready),
    .out_valid    (out_valid),
    .out_ok       (out_ok),
    .out_len      (out_len),
    .out_crc      (out_crc),
    .out_recv_crc (out_recv_crc),
    .crc_run      (crc_run),
    .err_sticky   (err_sticky),
    .cnt_good     (cnt_good),
    .cnt_bad_crc  (cnt_bad_crc),
    .cnt_over_len (cnt_over_len),
    .cnt_trunc    (cnt_trunc),
    .cnt_restart  (cnt_restart),
    .cnt_sat      (cnt_sat)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

integer f;
integer g;
integer p;
integer kind;
integer lb;
integer gap;
integer len;
integer tpos;
integer inj;
integer beats;
reg     bad;
reg     bce;
reg     bv;
reg     bs;
reg     bl;
reg [7:0] bd;
reg [7:0] crcb;
reg [31:0] state;
reg [4:0] sat_prev;
reg [3:0] stick_prev;

task fold_beat;
    begin
        ips_fnv_word({30'd0, out_valid, out_ok});
        ips_fnv_word({24'd0, out_len});
        ips_fnv_word({24'd0, out_crc});
        ips_fnv_word({24'd0, out_recv_crc});
        ips_fnv_word({24'd0, crc_run});
        ips_fnv_word({28'd0, err_sticky});
        ips_fnv_word({31'd0, in_ready});

        if (out_ok === 1'bx || in_ready === 1'bx) bad = 1'b1;
        if ((^out_crc) === 1'bx || (^crc_run) === 1'bx) bad = 1'b1;
        if ((^err_sticky) === 1'bx || (^cnt_sat) === 1'bx) bad = 1'b1;
        if ((^cnt_good) === 1'bx || (^cnt_bad_crc) === 1'bx) bad = 1'b1;
        if ((^cnt_over_len) === 1'bx || (^cnt_trunc) === 1'bx) bad = 1'b1;
        if ((^cnt_restart) === 1'bx || (^out_len) === 1'bx) bad = 1'b1;
        // A report that claims a good frame must carry matching check bytes, and no
        // accepted frame may exceed the configured length field.
        if (out_valid === 1'b1 && out_ok === 1'b1 && out_crc !== out_recv_crc) bad = 1'b1;
        if (out_valid === 1'b1 && out_ok === 1'b1 && out_len > LEN_MAX_TB) bad = 1'b1;
        if (out_valid === 1'b1 && out_ok === 1'b0 && out_crc === out_recv_crc
            && out_recv_crc !== 8'h00) bad = 1'b1;
        // Sticky accounting may never clear and may never wrap silently: every
        // cause word and saturation bit must be monotone over the whole run.
        if ((sat_prev & ~cnt_sat) !== 5'h0) bad = 1'b1;
        if ((stick_prev & ~err_sticky) !== 4'h0) bad = 1'b1;
        sat_prev   = cnt_sat;
        stick_prev = err_sticky;
        if (cnt_bad_crc !== 4'h0 && err_sticky[0] !== 1'b1) bad = 1'b1;
        if (cnt_over_len !== 4'h0 && err_sticky[1] !== 1'b1) bad = 1'b1;
        if (cnt_trunc !== 4'h0 && err_sticky[2] !== 1'b1) bad = 1'b1;
        if (cnt_restart !== 4'h0 && err_sticky[3] !== 1'b1) bad = 1'b1;
        beats = beats + 1;
    end
endtask

task beat;
    input        v;
    input        s;
    input        l;
    input [7:0]  d;
    input        ce;
    begin
        @(negedge ips_clk);
        clk_en   = ce;
        in_valid = v;
        in_start = s;
        in_last  = l;
        in_byte  = d;
        @(negedge ips_clk);
        in_valid = 1'b0;
        in_start = 1'b0;
        in_last  = 1'b0;
        in_byte  = 8'h00;
        fold_beat();
    end
endtask

initial begin
    ips_fnv_reset();
    rst_n     = 1'b0;
    clk_en    = 1'b0;
    in_valid  = 1'b0;
    in_start  = 1'b0;
    in_last   = 1'b0;
    in_byte   = 8'h00;
    state     = SEED;
    bad       = 1'b0;
    beats     = 0;
    sat_prev  = 5'h00;
    stick_prev = 4'h0;

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);
    clk_en = 1'b1;

    for (f = 0; f < NFRAMES; f = f + 1) begin
        state = state * 32'd1664525 + 32'd1013904223;
        kind  = state[1:0];
        lb    = state[4:2];
        gap   = 2 + state[7:6];
        inj   = (kind == 0 && lb >= 5) ? 1 : 0;

        if (kind == 2) begin
            len = LEN_MAX_TB + 1;
        end else if (kind == 0 && lb == 0) begin
            len = LEN_MAX_TB;
        end else if (kind == 3) begin
            len = lb + 1;
        end else begin
            len = lb;
        end
        tpos = (len >= 2) ? 1 : 0;

        crcb = tb_frame_crc(len[7:0], state, len);
        if (kind == 1) begin
            crcb = crcb ^ FLIP_TB;
        end

        for (g = 0; g < gap; g = g + 1) begin
            bce = 1'b1;
            bv  = 1'b0;
            bd  = 8'h00;
            if (f == 7 && g == 2) begin
                // Clock-enable window: the core must hold, not consume this byte.
                bce = 1'b0;
                bv  = 1'b1;
                bd  = 8'h2F;
            end
            beat(bv, 1'b0, 1'b0, bd, bce);
        end

        beat(1'b1, 1'b1, (kind == 3 && len == 1) ? 1'b1 : 1'b0, len[7:0], 1'b1);

        for (p = 0; p < len; p = p + 1) begin
            bd = state[7:0] ^ p[7:0] ^ 8'h3D;
            bs = (inj == 1 && p == 2) ? 1'b1 : 1'b0;
            bl = (kind == 3 && p == tpos) ? 1'b1 : 1'b0;
            beat(1'b1, bs, bl, bd, 1'b1);
        end

        if (kind != 3) begin
            beat(1'b1, 1'b0, 1'b1, crcb, 1'b1);
        end
    end

    repeat (4) @(negedge ips_clk);

    ips_fnv_word({28'd0, cnt_good});
    ips_fnv_word({28'd0, cnt_bad_crc});
    ips_fnv_word({28'd0, cnt_over_len});
    ips_fnv_word({28'd0, cnt_trunc});
    ips_fnv_word({28'd0, cnt_restart});
    ips_fnv_word({27'd0, cnt_sat});
    ips_fnv_word({28'd0, err_sticky});
    ips_fnv_word({24'd0, crc_run});
    ips_fnv_word({31'd0, in_ready});

    if (beats < MIN_BEATS) bad = 1'b1;

    ips_verdict(!bad, "ips_frame_len_crc");
end

endmodule
