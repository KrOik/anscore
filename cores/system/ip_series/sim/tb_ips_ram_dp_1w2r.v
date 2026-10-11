`timescale 1ns / 1ps
// tb_ips_ram_dp_1w2r : production-line testbench for the banked 1W2R RAM.
//
// 208 deterministic beats, one enabled clock per beat, walk the two read ports of
// the shipped geometry (WIDTH = 32, ADDR_BITS = 4 so DEPTH = 16, OUT_REG = 1)
// through the cases that define this core:
//   P0  0..15    write sweep: every cell gets its documented content
//   P1  16..31   port 0 reads 0..15                      (single stream)
//   P2  32..47   port 0 reads up, port 1 reads down      (two independent streams)
//   P3  48..63   both ports on the top override          (highest address read back)
//   P4  64..79   port 0 on top, port 1 on the guard cell (mixed override)
//   P5  80..95   write/read collision: port 0 reads the very cell the writer
//                updates, port 1 reads an untouched payload cell
//   P6  96..111  all three logical ports on one cell     (conflict_sticky case)
//   P7  112..127 dual read-back of the whole array
//   P8  128..143 port 0 only, port 1 idle                (stream independence)
//   P9  144..159 port 1 only, port 0 idle
//   P10 160..175 clk_en = 0 with live stimulus           (must change nothing)
//   P11 176..191 dual read-back again                    (proves P10 was inert)
//   P12 192..207 idle
// Reads of cell 12 (the collision cell) are folded but not compared against a
// documented constant, because its content is the collision sequence; every other
// valid slot must report the documented content of the address travelling with it,
// and every empty slot must report zero, all with === so an X on either read port
// fails the run (docs/IP_CORE_SOP.md trap T6).  Both read data wires are declared
// a byte wider than the core's ports, so a bit the declared WIDTH no longer
// covers shows up in the folded headroom byte instead of being truncated away.
// Fold windows start three beats into a phase, so the access a beat reports lies
// inside the same phase for any OUT_REG depth.  The expected stream is NOT written
// here: models/ips_ram_dp_1w2r.py computes it independently and the gate compares
// the two digests (trap T1).
module tb_ips_ram_dp_1w2r;

`include "ips_tb_common.vh"

localparam integer DEPTH  = 16;
localparam integer TOPA   = DEPTH - 1;
localparam integer NPAY   = 12;
localparam [7:0]   CELLP  = 8'd12;
localparam [7:0]   TOP8   = DEPTH - 1;
localparam integer S_P0   = 0;
localparam integer S_P1   = 16;
localparam integer S_P2   = 32;
localparam integer S_P3   = 48;
localparam integer S_P4   = 64;
localparam integer S_P5   = 80;
localparam integer S_P6   = 96;
localparam integer S_P7   = 112;
localparam integer S_P8   = 128;
localparam integer S_P9   = 144;
localparam integer S_P10  = 160;
localparam integer S_P11  = 176;
localparam integer S_P12  = 192;
localparam integer NBEATS = 208;

reg                 rst_n;
reg                 clk_en;
reg                 wr_en;
reg                 r0_en;
reg                 r0_top;
reg                 r1_en;
reg                 r1_top;
reg  [7:0]          waddr;
reg  [7:0]          r0_addr;
reg  [7:0]          r1_addr;
reg  [39:0]         wdata;

wire [39:0]         r0_data;
wire [7:0]          r0_addr_q;
wire                r0_valid;
wire [39:0]         r1_data;
wire [7:0]          r1_addr_q;
wire                r1_valid;
wire [7:0]          hit_count;
wire [7:0]          guard_count;
wire [15:0]         read_count;
wire [7:0]          write_count;
wire [7:0]          collide_count;
wire                conflict_sticky;

// No #() override here: the testbench exercises the core's declared default
// geometry, which is the configuration the manifest records.
ips_ram_dp_1w2r dut (
    .clk            (ips_clk),
    .clk_en         (clk_en),
    .rst_n          (rst_n),
    .wr_en          (wr_en),
    .waddr          (waddr),
    .wdata          (wdata),
    .r0_en          (r0_en),
    .r0_addr        (r0_addr),
    .r0_top         (r0_top),
    .r1_en          (r1_en),
    .r1_addr        (r1_addr),
    .r1_top         (r1_top),
    .r0_data        (r0_data),
    .r0_addr_q      (r0_addr_q),
    .r0_valid       (r0_valid),
    .r1_data        (r1_data),
    .r1_addr_q      (r1_addr_q),
    .r1_valid       (r1_valid),
    .hit_count      (hit_count),
    .guard_count    (guard_count),
    .read_count     (read_count),
    .write_count    (write_count),
    .collide_count  (collide_count),
    .conflict_sticky(conflict_sticky)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

// Documented content of a cell that is written once, in P0.  Cells 13, 14 and 15
// are the pattern cells: neither, guard-only (matches above bit 8) and exactly
// MATCH_CONST.  Cell 12 keeps its P0 value until the collision phases rewrite it.
function [31:0] cell_init;
    input [7:0]  a;
    reg   [31:0] v;
    begin
        v = ({24'd0, a} * 32'h0101_0101) ^ 32'h9E37_79B9;
        if (a == 8'd15) begin
            v = 32'hA5A5_5A5A;
        end else if (a == 8'd14) begin
            v = 32'hA5A5_5A5B;
        end else if (a == 8'd13) begin
            v = 32'hA5A5_5B5A;
        end else if (a == 8'd12) begin
            v = 32'h0C0C_0C0C;
        end
        cell_init = v;
    end
endfunction

// Datum the collision phases write into cell 12, k = 0 .. 31.
function [31:0] cdat;
    input [7:0]  k;
    begin
        cdat = ({24'd0, k} * 32'h0101_0101) ^ 32'h85EB_CA6B;
    end
endfunction

integer beat;
integer j;
integer k;
integer pstart;
reg       fold_d;
reg       fold_q;
reg       bad;

initial begin
    ips_fnv_reset();
    rst_n           = 1'b0;
    clk_en          = 1'b0;
    wr_en           = 1'b0;
    r0_en           = 1'b0;
    r0_top          = 1'b0;
    r1_en           = 1'b0;
    r1_top          = 1'b0;
    waddr           = 8'd0;
    r0_addr         = 8'd0;
    r1_addr         = 8'd0;
    wdata           = 40'd0;
    fold_d          = 1'b0;
    fold_q          = 1'b0;
    bad             = 1'b0;

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);
    clk_en = 1'b1;

    for (beat = 0; beat < NBEATS; beat = beat + 1) begin
        @(negedge ips_clk);

        // ---- observe what the access issued at the previous beat reported ----
        fold_q = fold_d;

        if ((^r0_data) === 1'bx)        bad = 1'b1;
        if ((^r1_data) === 1'bx)        bad = 1'b1;
        if ((^r0_addr_q) === 1'bx)      bad = 1'b1;
        if ((^r1_addr_q) === 1'bx)      bad = 1'b1;
        if (r0_valid === 1'bx)          bad = 1'b1;
        if (r1_valid === 1'bx)          bad = 1'b1;
        if ((^hit_count) === 1'bx)      bad = 1'b1;
        if ((^guard_count) === 1'bx)    bad = 1'b1;
        if ((^read_count) === 1'bx)     bad = 1'b1;
        if ((^write_count) === 1'bx)    bad = 1'b1;
        if ((^collide_count) === 1'bx)  bad = 1'b1;
        if (conflict_sticky === 1'bx)   bad = 1'b1;

        if (fold_q) begin
            // a valid slot must hold the documented content of the address that
            // travels with it; an empty slot must read back as zero
            if (r0_valid === 1'b1) begin
                if ((r0_addr_q != CELLP) &&
                    (r0_data[31:0] !== cell_init(r0_addr_q)))        bad = 1'b1;
            end else begin
                if (r0_addr_q !== 8'h00)                             bad = 1'b1;
                if (r0_data !== 40'd0)                               bad = 1'b1;
            end
            if (r1_valid === 1'b1) begin
                if ((r1_addr_q != CELLP) &&
                    (r1_data[31:0] !== cell_init(r1_addr_q)))        bad = 1'b1;
            end else begin
                if (r1_addr_q !== 8'h00)                             bad = 1'b1;
                if (r1_data !== 40'd0)                               bad = 1'b1;
            end
            // through the two override phases the reported address must be the
            // highest implemented one, whatever the pipeline depth is
            if (beat >= 51 && beat < S_P4) begin
                if (r0_addr_q !== TOP8)                              bad = 1'b1;
                if (r1_addr_q !== TOP8)                              bad = 1'b1;
            end
            if (beat >= 67 && beat < S_P5) begin
                if (r0_addr_q !== TOP8)                              bad = 1'b1;
            end
            ips_fnv_word(r0_data[31:0]);
            ips_fnv_word({24'd0, r0_data[39:32]});
            ips_fnv_word({24'd0, r0_addr_q});
            ips_fnv_word({31'd0, r0_valid});
            ips_fnv_word(r1_data[31:0]);
            ips_fnv_word({24'd0, r1_data[39:32]});
            ips_fnv_word({24'd0, r1_addr_q});
            ips_fnv_word({31'd0, r1_valid});
        end

        // ---- drive this beat's access ----
        fold_d  = 1'b0;
        pstart  = S_P0;
        wr_en   = 1'b0;
        r0_en   = 1'b0;
        r0_top  = 1'b0;
        r1_en   = 1'b0;
        r1_top  = 1'b0;
        waddr   = 8'd0;
        r0_addr = 8'd0;
        r1_addr = 8'd0;
        wdata   = 40'd0;
        j       = 0;
        k       = 0;
        if (beat < S_P1) begin
            pstart  = S_P0;
            wr_en   = 1'b1;
            waddr   = beat[7:0];
            wdata   = {8'hFF, cell_init(beat[7:0])};
        end else if (beat < S_P2) begin
            pstart  = S_P1;
            r0_en   = 1'b1;
            r0_addr = beat - S_P1;
        end else if (beat < S_P3) begin
            pstart  = S_P2;
            j       = beat - S_P2;
            r0_en   = 1'b1;
            r1_en   = 1'b1;
            r0_addr = j;
            r1_addr = TOPA - j;
        end else if (beat < S_P4) begin
            pstart  = S_P3;
            r0_en   = 1'b1;
            r1_en   = 1'b1;
            r0_top  = 1'b1;
            r1_top  = 1'b1;
        end else if (beat < S_P5) begin
            pstart  = S_P4;
            r0_en   = 1'b1;
            r1_en   = 1'b1;
            r0_top  = 1'b1;
            r1_addr = 8'd14;
        end else if (beat < S_P6) begin
            pstart  = S_P5;
            k       = beat - S_P5;
            wr_en   = 1'b1;
            waddr   = CELLP;
            wdata   = {8'hFF, cdat(k)};
            r0_en   = 1'b1;
            r0_addr = CELLP;
            r1_en   = 1'b1;
            r1_addr = (TOPA - k) % NPAY;
        end else if (beat < S_P7) begin
            pstart  = S_P6;
            k       = beat - S_P6;
            wr_en   = 1'b1;
            waddr   = CELLP;
            wdata   = {8'hFF, cdat(16 + k)};
            r0_en   = 1'b1;
            r0_addr = CELLP;
            r1_en   = 1'b1;
            r1_addr = CELLP;
        end else if (beat < S_P8) begin
            pstart  = S_P7;
            j       = beat - S_P7;
            r0_en   = 1'b1;
            r1_en   = 1'b1;
            r0_addr = j;
            r1_addr = TOPA - j;
        end else if (beat < S_P9) begin
            pstart  = S_P8;
            r0_en   = 1'b1;
            r0_addr = beat - S_P8;
        end else if (beat < S_P10) begin
            pstart  = S_P9;
            r1_en   = 1'b1;
            r1_addr = beat - S_P9;
        end else if (beat < S_P11) begin
            pstart  = S_P10;
            clk_en  = 1'b0;
            k       = beat - S_P10;
            wr_en   = 1'b1;
            waddr   = k;
            wdata   = {8'hFF, cdat(k)};
            r0_en   = 1'b1;
            r0_addr = TOPA - k;
            r1_en   = 1'b1;
            r1_addr = k % NPAY;
        end else if (beat < S_P12) begin
            pstart  = S_P11;
            clk_en  = 1'b1;
            j       = beat - S_P11;
            r0_en   = 1'b1;
            r1_en   = 1'b1;
            r0_addr = j;
            r1_addr = TOPA - j;
        end else begin
            pstart  = S_P12;
            clk_en  = 1'b1;
        end
        fold_d = (pstart != S_P0) && (pstart != S_P12) && (beat >= (pstart + 3));
    end

    // ---- observe the last beat, then the settled counters ----
    @(negedge ips_clk);
    fold_q = fold_d;

    if ((^r0_data) === 1'bx)        bad = 1'b1;
    if ((^r1_data) === 1'bx)        bad = 1'b1;
    if (conflict_sticky !== 1'b1)   bad = 1'b1;
    if (clk_en !== 1'b1)            bad = 1'b1;

    if (fold_q) begin
        ips_fnv_word(r0_data[31:0]);
        ips_fnv_word({24'd0, r0_data[39:32]});
        ips_fnv_word({24'd0, r0_addr_q});
        ips_fnv_word({31'd0, r0_valid});
        ips_fnv_word(r1_data[31:0]);
        ips_fnv_word({24'd0, r1_data[39:32]});
        ips_fnv_word({24'd0, r1_addr_q});
        ips_fnv_word({31'd0, r1_valid});
    end

    ips_fnv_word(r0_data[31:0]);
    ips_fnv_word({24'd0, r0_data[39:32]});
    ips_fnv_word({24'd0, r0_addr_q});
    ips_fnv_word({31'd0, r0_valid});
    ips_fnv_word(r1_data[31:0]);
    ips_fnv_word({24'd0, r1_data[39:32]});
    ips_fnv_word({24'd0, r1_addr_q});
    ips_fnv_word({31'd0, r1_valid});
    ips_fnv_word({24'd0, hit_count});
    ips_fnv_word({24'd0, guard_count});
    ips_fnv_word({16'd0, read_count});
    ips_fnv_word({24'd0, write_count});
    ips_fnv_word({24'd0, collide_count});
    ips_fnv_word({31'd0, conflict_sticky});
    ips_fnv_word(NBEATS);

    ips_verdict(!bad, "ips_ram_dp_1w2r");
end

endmodule
