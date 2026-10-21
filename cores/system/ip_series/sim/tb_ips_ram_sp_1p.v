`timescale 1ns / 1ps
// tb_ips_ram_sp_1p : production-line testbench for the single-port RAM wrapper.
//
// 216 deterministic beats drive one port through the shipped geometry
// (WIDTH = 32, DEPTH = 1 << ADDR_BITS = 32, OUT_REG = 1).  Every beat is exactly
// one enabled clock: the stimulus of beat b is driven at the negedge that starts
// it and the DUT result of that beat is taken at the next negedge, which is also
// where the next beat is driven, so one access is issued per beat.
//
// Beat plan (the same plan models/ips_ram_sp_1p.py implements):
//   0..31    full-word write sweep, be = 1111, waddr = beat, wdata = wdat(beat)
//   32..63   byte-lane sweep, j = beat-32, be = 0101 for j < 16 else 1010,
//            waddr = j % 16, wdata = bdat(j) -> addresses 0..15 end up merged
//   64..95   read pass raddr = beat-64            (warms the read pipeline)
//   96..127  read pass raddr = beat-96, folded    (whole array read back)
//   128..159 top_sel = 1, folded                 (highest address DEPTH-1)
//   160..191 top_sel = beat[0], folded           (interleaved top/normal reads)
//   192..207 we = 1 with ce = 0                  (must latch error_sticky)
//   208..215 idle
// Only DUT outputs are folded into ips_fnv_word, every check uses === / !==, and
// the read port is required to be X-free on every beat (docs/IP_CORE_SOP.md trap
// T6).  rdata and raddr_q are declared wider than the core's ports so a byte
// lane the core stops driving, or a bit the declared WIDTH no longer covers,
// shows up instead of being truncated away (the headroom trick of the exemplar).
// The expected stream is NOT written here: models/ips_ram_sp_1p.py computes it
// independently and the gate compares the two digests (trap T1).
module tb_ips_ram_sp_1p;

`include "ips_tb_common.vh"

localparam integer DEPTH  = 32;
localparam integer NW     = 16;
localparam integer S_W    = 0;
localparam integer S_BW   = 32;
localparam integer S_R1   = 64;
localparam integer S_R2   = 96;
localparam integer S_TOP  = 128;
localparam integer S_ALT  = 160;
localparam integer S_ERR  = 192;
localparam integer S_IDL  = 208;
localparam integer NBEATS = 216;
localparam [7:0]   TOP8   = DEPTH - 1;

reg                 rst_n;
reg                 clk_en;
reg                 ce;
reg                 we;
reg                 top_sel;
reg  [3:0]          be;
reg  [7:0]          waddr;
reg  [7:0]          raddr;
reg  [39:0]         wdata;

wire [39:0]         rdata;
wire [7:0]          raddr_q;
wire [7:0]          hit_count;
wire [7:0]          guard_count;
wire [15:0]         addr_count;
wire                error_sticky;

// No #() override here: the testbench exercises the core's declared default
// geometry, which is the configuration the manifest records.
ips_ram_sp_1p dut (
    .clk         (ips_clk),
    .clk_en      (clk_en),
    .rst_n       (rst_n),
    .ce          (ce),
    .we          (we),
    .be          (be),
    .waddr       (waddr),
    .raddr       (raddr),
    .top_sel     (top_sel),
    .wdata       (wdata),
    .rdata       (rdata),
    .raddr_q     (raddr_q),
    .hit_count   (hit_count),
    .guard_count (guard_count),
    .addr_count  (addr_count),
    .error_sticky(error_sticky)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

// Full-word write datum of sweep address a.  Addresses 29..31 are the three
// match-shaped entries: 31 equals MATCH_CONST exactly (hit and guard), 30 differs
// only in the byte below bit SHIFT (guard only) and 29 differs above it (neither).
// They live above NW so the byte-lane sweep cannot merge over them.
function [31:0] wdat;
    input [7:0]  a;
    reg   [31:0] v;
    begin
        v = ({24'd0, a} * 32'h0101_0101) ^ 32'h9E37_79B9;
        if (a == 8'd31) begin
            v = 32'hA5A5_5A5A;
        end else if (a == 8'd30) begin
            v = 32'hA5A5_5A5B;
        end else if (a == 8'd29) begin
            v = 32'hA5A5_5B5A;
        end
        wdat = v;
    end
endfunction

// Write datum of byte-lane beat j (0 .. 2*NW-1).
function [31:0] bdat;
    input [7:0]  j;
    reg   [31:0] v;
    begin
        v = ({24'd0, j} * 32'h00FF_00FF) ^ 32'hC2B2_AE3C;
        bdat = v;
    end
endfunction

// Documented content of address a once both write phases have run: below NW the
// even byte lanes hold the first half's datum and the odd lanes the second one's.
function [31:0] expected;
    input [7:0]  a;
    reg [31:0]   w0;
    reg [31:0]   b0;
    reg [31:0]   b1;
    begin
        w0 = wdat(a);
        b0 = bdat(a);
        b1 = bdat(a + NW);
        if (a < NW) begin
            expected = { b1[31:24], b0[23:16], b1[15:8], b0[7:0] };
        end else begin
            expected = w0;
        end
    end
endfunction

integer beat;
integer j;
reg       fold_d;
reg       fold_q;
reg       bad;

initial begin
    ips_fnv_reset();
    rst_n    = 1'b0;
    clk_en   = 1'b0;
    ce       = 1'b0;
    we       = 1'b0;
    top_sel  = 1'b0;
    be       = 4'b0000;
    waddr    = 8'd0;
    raddr    = 8'd0;
    wdata    = 40'd0;
    fold_d   = 1'b0;
    fold_q   = 1'b0;
    bad      = 1'b0;

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);
    clk_en = 1'b1;

    for (beat = 0; beat < NBEATS; beat = beat + 1) begin
        @(negedge ips_clk);

        // ---- observe what the access issued at the previous beat reported ----
        // fold_q is the fold window of that beat, which is the one whose edge is
        // already behind us.  The read datum visible here is the one the pipeline
        // shifted out of its first stage, i.e. the read of the beat before that;
        // inside the top_sel window every beat reads the same address, so the
        // address check below holds for any OUT_REG depth.
        fold_q = fold_d;

        if ((^rdata) === 1'bx)        bad = 1'b1;
        if ((^raddr_q) === 1'bx)      bad = 1'b1;
        if ((^hit_count) === 1'bx)    bad = 1'b1;
        if ((^guard_count) === 1'bx)  bad = 1'b1;
        if ((^addr_count) === 1'bx)   bad = 1'b1;
        if (error_sticky === 1'bx)    bad = 1'b1;

        if (fold_q) begin
            // the reported datum must be the documented content of the reported
            // address, and through the whole top_sel window the reported address
            // must be the highest implemented one, DEPTH-1
            if (rdata[31:0] !== expected(raddr_q))               bad = 1'b1;
            if (beat >= 131 && beat <= 160 && (raddr_q !== TOP8)) bad = 1'b1;
            ips_fnv_word(rdata[31:0]);
            ips_fnv_word({24'd0, rdata[39:32]});
            ips_fnv_word({24'd0, raddr_q});
        end

        // ---- drive this beat's access ----
        fold_d   = 1'b0;
        be       = 4'b0000;
        waddr    = 8'd0;
        raddr    = 8'd0;
        wdata    = 40'd0;
        top_sel  = 1'b0;
        j        = 0;
        if (beat < S_BW) begin
            ce    = 1'b1; we = 1'b1;
            be    = 4'b1111;
            waddr = beat[7:0];
            wdata = {8'hFF, wdat(beat[7:0])};
        end else if (beat < S_R1) begin
            j     = beat - S_BW;
            ce    = 1'b1; we = 1'b1;
            be    = (j < NW) ? 4'b0101 : 4'b1010;
            waddr = j % NW;
            wdata = {8'hFF, bdat(j)};
        end else if (beat < S_R2) begin
            ce    = 1'b1; we = 1'b0;
            raddr = (beat - S_R1) % DEPTH;
        end else if (beat < S_TOP) begin
            ce       = 1'b1; we = 1'b0;
            raddr    = (beat - S_R2) % DEPTH;
            fold_d   = 1'b1;
        end else if (beat < S_ALT) begin
            ce       = 1'b1; we = 1'b0;
            top_sel  = 1'b1;
            raddr    = (beat - S_TOP) % DEPTH;
            fold_d   = 1'b1;
        end else if (beat < S_ERR) begin
            ce       = 1'b1; we = 1'b0;
            top_sel  = (beat[0] == 1'b1);
            raddr    = (beat - S_ALT) % DEPTH;
            fold_d   = 1'b1;
        end else if (beat < S_IDL) begin
            ce    = 1'b0; we = 1'b1;
        end else begin
            ce    = 1'b0; we = 1'b0;
        end
    end

    // ---- observe the last beat, then the settled counters ----
    @(negedge ips_clk);
    fold_q = fold_d;

    if ((^rdata) === 1'bx)        bad = 1'b1;
    if ((^raddr_q) === 1'bx)      bad = 1'b1;
    if (error_sticky !== 1'b1)    bad = 1'b1;

    if (fold_q) begin
        if (rdata[31:0] !== expected(raddr_q)) bad = 1'b1;
        ips_fnv_word(rdata[31:0]);
        ips_fnv_word({24'd0, rdata[39:32]});
        ips_fnv_word({24'd0, raddr_q});
    end

    ips_fnv_word(rdata[31:0]);
    ips_fnv_word({24'd0, rdata[39:32]});
    ips_fnv_word({24'd0, raddr_q});
    ips_fnv_word({24'd0, hit_count});
    ips_fnv_word({24'd0, guard_count});
    ips_fnv_word({16'd0, addr_count});
    ips_fnv_word({31'd0, error_sticky});
    ips_fnv_word(NBEATS);

    ips_verdict(!bad, "ips_ram_sp_1p");
end

endmodule
