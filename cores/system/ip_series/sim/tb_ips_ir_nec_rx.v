`timescale 1ns / 1ps
// tb_ips_ir_nec_rx : production-line testbench for the NEC infrared receiver.
//
// The waveform is built in the tick domain before a single edge is applied: the
// plan is a list of (level, ticks, tag) segments and the walk below spreads each
// segment over exactly that many clock ticks, whatever the tick pattern is doing
// in between.  Every width the core measures is therefore a property of the
// stimulus, not of the DUT, and models/ips_ir_nec_rx.py replays the same plan.
//
// Tick base: a tick is presented on three beats out of every four (i % 4 != 3),
// which is the deterministic divisor the SOP asks for instead of an internal
// clock divider.  Level changes always land on a tick beat.  Every frame in the
// plan is closed by a stop burst, the segment that ends its 32nd bit space.
//
// Pattern suite (targets are the core defaults: leader 48/24, repeat 12,
// bit burst 3, bit spaces 6 and 12, tolerance 2):
//   0x5AA517E8 nominal                    -> published frame, counters move
//   0x5A5A17E8 nominal width, bad inverse -> crc_sticky + crc_count
//   0x3CC3F00F at every lower boundary    -> 46 / 22 / 1 / 4 / 10, still accepted
//   space 9 then space 15 at a bit stage  -> outside both windows, timing error
//   leader space 9                        -> neither start nor repeat, timing error
//   63-tick space mid frame               -> width counter saturates, timing error
//   20-tick burst from idle               -> invalid leader, timing error
//   repeat code at 12 and at 10 ticks     -> repeat_valid + repeat_count
//   0x12ED34CB nominal                    -> published frame, addr/cmd latched
// Malformed input cases: a burst glitch injected on every non-tick beat of an
// idle segment (must be invisible), 12 ticks withdrawn inside an idle segment,
// and clk_en held low for four ticks of an idle segment.
//
// Folded per beat: rx_word, then status + live measurement state (state,
// bit_index, width), then addr/cmd + error counters, then frame/repeat counters.
// Observed with === / !== only; no expected stream is written here
// (docs/IP_CORE_SOP.md trap T1).
module tb_ips_ir_nec_rx;

`include "ips_tb_common.vh"

localparam integer MAXSEG = 512;
localparam integer MAXB   = 8192;
localparam [1:0] T_NONE   = 2'd0;
localparam [1:0] T_GAP    = 2'd1;
localparam [1:0] T_STALL  = 2'd2;
localparam [1:0] T_GLITCH = 2'd3;
localparam integer GAP_N  = 12;
localparam integer ST_A   = 4;
localparam integer ST_L   = 4;
localparam [2:0] S_TAIL_C  = 3'd4;

reg         rst_n;
reg         clk_en;
reg         tick;
reg         ir_in;

wire [31:0] rx_word;
wire [7:0]  addr;
wire [7:0]  cmd;
wire        frame_valid;
wire        repeat_valid;
wire [2:0]  state;
wire [5:0]  bit_index;
wire [5:0]  width;
wire        timing_sticky;
wire        crc_sticky;
wire [7:0]  timing_count;
wire [7:0]  crc_count;
wire [7:0]  frame_count;
wire [7:0]  repeat_count;

reg        lvl_tab  [0:MAXSEG - 1];
integer    len_tab  [0:MAXSEG - 1];
reg [1:0]  tag_tab  [0:MAXSEG - 1];
reg        ir_b     [0:MAXB - 1];
reg        tick_b   [0:MAXB - 1];
reg        en_b     [0:MAXB - 1];

integer    nseg;
integer    nbeats;
integer    i;
reg [31:0] w1;
reg [31:0] w2;
reg [31:0] w3;
reg [31:0] w4;
reg [31:0] pw2;
reg        bad;
reg        dump;

ips_ir_nec_rx dut (
    .clk           (ips_clk),
    .clk_en        (clk_en),
    .rst_n         (rst_n),
    .tick          (tick),
    .ir_in         (ir_in),
    .rx_word       (rx_word),
    .addr          (addr),
    .cmd           (cmd),
    .frame_valid   (frame_valid),
    .repeat_valid  (repeat_valid),
    .state         (state),
    .bit_index     (bit_index),
    .width         (width),
    .timing_sticky (timing_sticky),
    .crc_sticky    (crc_sticky),
    .timing_count  (timing_count),
    .crc_count     (crc_count),
    .frame_count   (frame_count),
    .repeat_count  (repeat_count)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

task push;
    input        lvl;
    input integer len;
    input [1:0]  tag;
    begin
        lvl_tab[nseg] = lvl;
        len_tab[nseg] = len;
        tag_tab[nseg] = tag;
        nseg = nseg + 1;
    end
endtask

task nec_frame;
    input [31:0] w;
    input integer lead;
    input integer lsp;
    input integer mk;
    input integer s0;
    input integer s1;
    input integer stop;
    integer b;
    begin
        push(1'b0, lead, T_NONE);
        push(1'b1, lsp, T_NONE);
        for (b = 31; b > (31 - stop); b = b - 1) begin
            push(1'b0, mk, T_NONE);
            push(1'b1, w[b] ? s1 : s0, T_NONE);
        end
        push(1'b0, mk, T_NONE);
    end
endtask

initial begin
    ips_fnv_reset();
    rst_n  = 1'b0;
    clk_en = 1'b0;
    tick   = 1'b0;
    ir_in  = 1'b1;
    bad    = 1'b0;
    dump   = $test$plusargs("DUMP");
    nseg   = 0;

    // ---- stimulus plan ----------------------------------------------------
    push(1'b1, 40, T_NONE);
    nec_frame(32'h5AA517E8, 48, 24, 3, 6, 12, 32);
    push(1'b1, 40, T_GLITCH);
    nec_frame(32'h5A5A17E8, 48, 24, 3, 6, 12, 32);
    push(1'b1, 40, T_GAP);
    nec_frame(32'h3CC3F00F, 46, 22, 1, 4, 10, 32);
    push(1'b1, 40, T_STALL);
    nec_frame(32'h5AA517E8, 48, 24, 3, 6, 9, 2);
    push(1'b1, 30, T_NONE);
    push(1'b0, 48, T_NONE);
    push(1'b1, 12, T_NONE);
    push(1'b0, 3, T_NONE);
    push(1'b1, 30, T_NONE);
    push(1'b0, 46, T_NONE);
    push(1'b1, 10, T_NONE);
    push(1'b0, 3, T_NONE);
    push(1'b1, 40, T_NONE);
    nec_frame(32'h3CC3F00F, 48, 24, 3, 6, 15, 2);
    push(1'b1, 40, T_NONE);
    push(1'b0, 48, T_NONE);
    push(1'b1, 9, T_NONE);
    push(1'b0, 3, T_NONE);
    push(1'b1, 40, T_NONE);
    push(1'b0, 48, T_NONE);
    push(1'b1, 24, T_NONE);
    push(1'b0, 3, T_NONE);
    push(1'b1, 63, T_NONE);
    push(1'b0, 3, T_NONE);
    push(1'b1, 40, T_NONE);
    push(1'b0, 20, T_NONE);
    push(1'b1, 40, T_NONE);
    nec_frame(32'h12ED34CB, 48, 24, 3, 6, 12, 32);
    push(1'b1, 40, T_NONE);

    // ---- spread the plan over beats ---------------------------------------
    begin : build
        integer nb;
        integer s;
        integer k;
        reg     lvl;
        reg     wt;
        nb  = 0;
        s   = 0;
        k   = 0;
        lvl = lvl_tab[0];
        while (s < nseg) begin
            wt = ((nb % 4) != 3);
            ir_b[nb]   = lvl ^ ((tag_tab[s] == T_GLITCH) && !wt);
            tick_b[nb] = wt && !((tag_tab[s] == T_GAP) && (k < GAP_N));
            en_b[nb]   = !((tag_tab[s] == T_STALL) && (k >= ST_A) && (k < ST_A + ST_L));
            if (wt) begin
                if ((k + 1) >= len_tab[s]) begin
                    s = s + 1;
                    k = 0;
                    if (s < nseg) lvl = lvl_tab[s];
                end else begin
                    k = k + 1;
                end
            end
            nb = nb + 1;
            if (nb >= MAXB) begin
                $display("OVERRUN s=%0d k=%0d len=%0d nseg=%0d", s, k, len_tab[s], nseg);
                $finish;
            end
        end
        nbeats = nb;
    end

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);

    if (nseg >= MAXSEG || nbeats >= MAXB || nbeats < 200) bad = 1'b1;

    for (i = 0; i < nbeats; i = i + 1) begin
        @(negedge ips_clk);
        ir_in  = ir_b[i];
        tick   = tick_b[i];
        clk_en = en_b[i];

        @(negedge ips_clk);
        clk_en = 1'b0;

        if ((^rx_word === 1'bx) || (^addr === 1'bx) || (^cmd === 1'bx))            bad = 1'b1;
        if ((^state === 1'bx) || (^bit_index === 1'bx) || (^width === 1'bx))       bad = 1'b1;
        if ((^timing_count === 1'bx) || (^crc_count === 1'bx))                     bad = 1'b1;
        if ((^frame_count === 1'bx) || (^repeat_count === 1'bx))                   bad = 1'b1;
        if ((frame_valid === 1'bx) || (repeat_valid === 1'bx))                     bad = 1'b1;
        if ((timing_sticky === 1'bx) || (crc_sticky === 1'bx))                     bad = 1'b1;
        // structural invariants of the written contract
        if ((i > 0) && (tick_b[i] === 1'b0) && (en_b[i] === 1'b1) && (w2 !== pw2)) bad = 1'b1;
        if ((i > 0) && (en_b[i] === 1'b0) && (w2 !== pw2))                         bad = 1'b1;
        if ((frame_valid === 1'b1) && (addr !== rx_word[31:24]))                   bad = 1'b1;
        if ((frame_valid === 1'b1) && (cmd !== rx_word[15:8]))                     bad = 1'b1;
        if ((frame_valid === 1'b1) && (state !== S_TAIL_C))                      bad = 1'b1;
        if ((repeat_valid === 1'b1) && (state !== S_TAIL_C))                     bad = 1'b1;
        if ((timing_sticky === 1'b0) && (timing_count !== 8'h00))                  bad = 1'b1;
        if ((crc_sticky === 1'b0) && (crc_count !== 8'h00))                        bad = 1'b1;
        if (bit_index > 6'd32)                                                     bad = 1'b1;

        w1 = rx_word;
        w2 = {13'd0, timing_sticky, crc_sticky, frame_valid, repeat_valid, state,
              bit_index, width};
        w3 = {addr, cmd, timing_count, crc_count};
        w4 = {16'd0, frame_count, repeat_count};
        ips_fnv_word(w1);
        ips_fnv_word(w2);
        ips_fnv_word(w3);
        ips_fnv_word(w4);
        pw2 = w2;
        if (dump && ((i % 64) == 63)) $display("DBG %0d %h %h %h %h", i, w1, w2, w3, w4);
    end

    ips_fnv_word(nbeats);
    ips_verdict(!bad, "ips_ir_nec_rx");
end

endmodule
