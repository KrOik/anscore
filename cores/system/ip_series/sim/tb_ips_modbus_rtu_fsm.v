`timescale 1ns / 1ps
// tb_ips_modbus_rtu_fsm : production-line testbench for the RTU slave framer.
//
// No bus simulator and no board: the 3.5-character inter-frame silence is
// measured against an explicit `tick' input and the byte pipe is driven one byte
// per slot, so every frame boundary, CRC step and response byte is a property of
// the stimulus and models/ips_modbus_rtu_fsm.py replays it beat for beat.
//
// Time base: a slot is two beats and a tick is presented on the first beat of a
// slot only (deterministic divisor, never an internal divider).  A byte is
// presented on the second beat, i.e. on a non-tick beat, which exercises the
// contract "a byte is consumed on any enabled cycle with rx_valid high".  Tags:
//   T_NOTICK  the slot presents no tick  -> the silence timer freezes
//   T_STALL   clk_en is low all slot     -> the byte is lost, time does not move
//   T_ONICK   the byte is presented on the tick beat itself, so it races the
//             frame-close test and must win (the frame merges)
//
// Pattern suite (defaults T35 40, MIN_LEN 4, FUNC_LEN 8, READ 03, WRITE 06,
// EXC_FUNC 01, EXC_DATA 03, POLY A001, SEED FFFF, slave address 0x11).  Frame
// sizes below are bytes on the wire, CRC included, which is what rx_len counts:
//   260 quiet slots               -> silence saturates at 8'hFF while idle
//   8-byte 03 / 06 frames         -> acknowledged, frame_count steps
//   8-byte 10 / 04 frames         -> illegal-function exception 8'h01
//   9 / 7 / 4-byte 03 frames      -> illegal-data exception 8'h03
//   3-byte truncated frame        -> short frame, short_count steps
//   address 00                    -> broadcast executed, no response
//   address 22, then slv 12       -> not_addr_count steps, no response
//   6-byte frame with forced CRC  -> crc_err_count steps
//   frame split by 50 tick-free slots       -> one merged 8-byte frame, acked
//   frame with one stalled byte slot        -> 6 bytes folded, CRC mismatch
//   frame started inside the response window -> leading bytes lost
//   byte on the close slot (T_ONICK)         -> close blocked, frame merged
//   260-byte frame                -> rx_len saturates at 8'hFF
// Malformed input is deliberate in the last five cases and in every forced-CRC /
// wrong-length / truncated frame.
//
// Folded per beat: the four error/reply counters, then rx_addr/rx_func with the
// exception and frame counters, then the live tx pipe (tx_valid, tx_byte,
// tx_idx, state), then crc_state/silence/rx_len.  Observed with === / !== only;
// no expected stream is written here (docs/IP_CORE_SOP.md trap T1).
module tb_ips_modbus_rtu_fsm;

`include "ips_tb_common.vh"

localparam integer MAXS   = 2048;
localparam integer MAXB   = 4096;
localparam [1:0] T_NONE   = 2'd0;
localparam [1:0] T_NOTICK = 2'd1;
localparam [1:0] T_STALL  = 2'd2;
localparam [1:0] T_ONICK  = 2'd3;
localparam [2:0] S_RX_C   = 3'd1;
localparam [2:0] S_ANS_C  = 3'd2;
localparam [15:0] TB_SEED = 16'hFFFF;
localparam [15:0] TB_POLY = 16'hA001;

reg        rst_n;
reg        clk_en;
reg        tick;
reg        rx_valid;
reg [7:0]  rx_byte;
reg [7:0]  slv_addr;

wire [7:0]  rx_addr;
wire [7:0]  rx_func;
wire [7:0]  rx_len;
wire [15:0] crc_state;
wire [7:0]  silence;
wire [2:0]  state;
wire        tx_valid;
wire [7:0]  tx_byte;
wire [2:0]  tx_idx;
wire [7:0]  crc_err_count;
wire [7:0]  short_count;
wire [7:0]  not_addr_count;
wire [7:0]  broadcast_count;
wire [7:0]  exc_count;
wire [7:0]  frame_count;

reg        s_has [0:MAXS - 1];
reg [7:0]  s_bty [0:MAXS - 1];
reg [1:0]  s_tag [0:MAXS - 1];
reg [7:0]  s_adr [0:MAXS - 1];

reg        tick_b [0:MAXB - 1];
reg        rv_b   [0:MAXB - 1];
reg        en_b   [0:MAXB - 1];
reg [7:0]  rb_b   [0:MAXB - 1];
reg [7:0]  sa_b   [0:MAXB - 1];

integer    nslot;
integer    nbeats;
integer    i;
reg [7:0]  cur_addr;
reg [15:0] acc;
reg [31:0] w1;
reg [31:0] w2;
reg [31:0] w3;
reg [31:0] w4;
reg [31:0] pw1;
reg [31:0] pw2;
reg [31:0] pw3;
reg [31:0] pw4;
reg [2:0]  pstate;
reg        bad;
reg        dump;

ips_modbus_rtu_fsm dut (
    .clk             (ips_clk),
    .clk_en          (clk_en),
    .rst_n           (rst_n),
    .tick            (tick),
    .rx_valid        (rx_valid),
    .rx_byte         (rx_byte),
    .slv_addr        (slv_addr),
    .rx_addr         (rx_addr),
    .rx_func         (rx_func),
    .rx_len          (rx_len),
    .crc_state       (crc_state),
    .silence         (silence),
    .state           (state),
    .tx_valid        (tx_valid),
    .tx_byte         (tx_byte),
    .tx_idx          (tx_idx),
    .crc_err_count   (crc_err_count),
    .short_count     (short_count),
    .not_addr_count  (not_addr_count),
    .broadcast_count (broadcast_count),
    .exc_count       (exc_count),
    .frame_count     (frame_count)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

// Reference CRC16/Modbus step, used only to build well-formed stimulus bytes.
function [15:0] tcrc;
    input [15:0] c;
    input [7:0]  d;
    integer      k;
    reg [15:0]   x;
    begin
        x = c ^ {8'h00, d};
        for (k = 0; k < 8; k = k + 1) begin
            if (x[0]) begin
                x = {1'b0, x[15:1]} ^ TB_POLY;
            end else begin
                x = {1'b0, x[15:1]};
            end
        end
        tcrc = x;
    end
endfunction

task push;
    input        has;
    input [7:0]  b;
    input [1:0]  tag;
    begin
        if (nslot >= MAXS) begin
            $display("OVERRUN nslot=%0d", nslot);
            $finish;
        end
        s_has[nslot] = has;
        s_bty[nslot] = b;
        s_tag[nslot] = tag;
        s_adr[nslot] = cur_addr;
        nslot        = nslot + 1;
    end
endtask

task quiet;
    input integer n;
    integer      k;
    begin
        for (k = 0; k < n; k = k + 1) push(1'b0, 8'h00, T_NONE);
    end
endtask

task quiet_t;
    input integer n;
    input [1:0]   tag;
    integer      k;
    begin
        for (k = 0; k < n; k = k + 1) push(1'b0, 8'h00, tag);
    end
endtask

task fbegin;
    begin
        acc = TB_SEED;
    end
endtask

// one frame byte, tagged, folded into the reference CRC
task fbs;
    input [7:0]  b;
    input [1:0]  tag;
    begin
        push(1'b1, b, tag);
        acc = tcrc(acc, b);
    end
endtask

task fb;
    input [7:0] b;
    begin
        fbs(b, T_NONE);
    end
endtask

// A complete frame of n bytes ON THE WIRE, i.e. rx_len ends at n: address,
// function, n-4 data bytes and the two CRC bytes.  A supported function is only
// acknowledged when n is exactly FUNC_LEN, and n below MIN_LEN is a short frame.
task rqt;
    input [7:0]  a;
    input [7:0]  f;
    input integer n;
    integer      k;
    reg [7:0]    d;
    begin
        fbegin;
        fb(a);
        if (n > 1) fb(f);
        d = 8'h40;
        for (k = 2; k < (n - 2); k = k + 1) begin
            fb(d);
            d = d + 8'h03;
        end
        fend;
    end
endtask

// append the two CRC bytes of the payload pushed so far, low byte first
task fend;
    begin
        push(1'b1, acc[7:0], T_NONE);
        push(1'b1, acc[15:8], T_NONE);
    end
endtask

task fend_bad;
    input [15:0] cw;
    begin
        push(1'b1, cw[7:0], T_NONE);
        push(1'b1, cw[15:8], T_NONE);
    end
endtask

initial begin
    ips_fnv_reset();
    rst_n     = 1'b0;
    clk_en    = 1'b0;
    tick      = 1'b0;
    rx_valid  = 1'b0;
    rx_byte   = 8'h00;
    slv_addr  = 8'h11;
    cur_addr  = 8'h11;
    acc       = TB_SEED;
    bad       = 1'b0;
    dump      = $test$plusargs("DUMP");
    nslot     = 0;
    pw1       = 32'h0;
    pw2       = 32'h0;
    pw3       = 32'h0;
    pw4       = 32'h0;
    pstate    = 3'd0;

    // ---- stimulus plan ----------------------------------------------------
    quiet(260);                                   // silence saturates when idle

    rqt(8'h11, 8'h03, 8);  quiet(45);              // acknowledged read
    rqt(8'h11, 8'h06, 8);  quiet(45);              // acknowledged write
    rqt(8'h11, 8'h10, 8);  quiet(45);              // illegal function
    rqt(8'h11, 8'h04, 8);  quiet(45);              // illegal function (04)
    rqt(8'h11, 8'h03, 9);  quiet(45);              // illegal data (9 bytes)
    rqt(8'h11, 8'h03, 7);  quiet(45);              // illegal data (7 bytes)
    rqt(8'h11, 8'h03, 4);  quiet(45);              // illegal data (4 bytes)
    // truncated frame: address, function and only the low CRC byte -> short
    fbegin; fb(8'h11); fb(8'h03); push(1'b1, acc[7:0], T_NONE); quiet(45);
    rqt(8'h00, 8'h03, 8);  quiet(45);              // broadcast, no response
    rqt(8'h22, 8'h03, 8);  quiet(45);              // other node, dropped

    cur_addr = 8'h12;
    rqt(8'h11, 8'h03, 8);  quiet(45);              // now not addressed to us
    rqt(8'h12, 8'h06, 8);  quiet(45);              // addressed again, acked
    cur_addr = 8'h11;

    // six wire bytes, correct length gate, wrong CRC on the wire
    fbegin; fb(8'h11); fb(8'h03); fb(8'h40); fb(8'h43); fend_bad(16'hBEEF);
    quiet(45);

    // split a valid frame across 50 tick-free slots: the timer freezes and the
    // two halves merge into one 10-byte frame (CRC still folds to zero)
    fbegin;
    fb(8'h11); fb(8'h03); fb(8'h40); fb(8'h43);
    quiet_t(50, T_NOTICK);
    fb(8'h46); fb(8'h49);
    fend;
    quiet(45);

    // a byte slot the core never sees because clk_en is held low for it, so the
    // CRC on the wire no longer matches the seven bytes it folded
    fbegin;
    fb(8'h11); fb(8'h03); fb(8'h40);
    fbs(8'h43, T_STALL);
    fb(8'h46);
    fend;
    quiet(45);

    // 40 quiet slots close the frame, its response then swallows the first two
    // bytes of the next frame (single-buffered slave behaviour)
    rqt(8'h11, 8'h03, 8);
    quiet(40);
    rqt(8'h11, 8'h03, 8);
    quiet(45);

    // a byte presented on the tick beat of the close slot blocks the close
    rqt(8'h11, 8'h03, 8);
    quiet(39);
    fbs(8'h5A, T_ONICK);
    quiet(45);

    rqt(8'h11, 8'h03, 260); quiet(45);             // rx_len saturates

    rqt(8'h11, 8'h06, 8);  quiet(45);              // final acknowledged write
    quiet(20);

    // ---- spread the plan over beats ---------------------------------------
    begin : build
        integer s;
        integer ia;
        reg     en;
        reg     tk;
        for (s = 0; s < nslot; s = s + 1) begin
            ia = 2 * s;
            if (ia + 1 >= MAXB) begin
                $display("OVERRUN s=%0d nslot=%0d", s, nslot);
                $finish;
            end
            en             = (s_tag[s] != T_STALL);
            tk             = (s_tag[s] != T_NOTICK);
            tick_b[ia]     = tk;
            tick_b[ia + 1] = 1'b0;
            en_b[ia]       = en;
            en_b[ia + 1]   = en;
            rv_b[ia]       = s_has[s] && (s_tag[s] == T_ONICK);
            rv_b[ia + 1]   = s_has[s] && (s_tag[s] != T_ONICK);
            rb_b[ia]       = s_bty[s];
            rb_b[ia + 1]   = s_bty[s];
            sa_b[ia]       = s_adr[s];
            sa_b[ia + 1]   = s_adr[s];
        end
        nbeats = 2 * nslot;
    end

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);

    if (nslot >= MAXS || nbeats >= MAXB || nbeats < 200) bad = 1'b1;

    for (i = 0; i < nbeats; i = i + 1) begin
        @(negedge ips_clk);
        rx_valid = rv_b[i];
        rx_byte  = rb_b[i];
        tick     = tick_b[i];
        slv_addr = sa_b[i];
        clk_en   = en_b[i];

        @(negedge ips_clk);
        clk_en = 1'b0;

        w1 = {crc_err_count, short_count, not_addr_count, broadcast_count};
        w2 = {exc_count, frame_count, rx_addr, rx_func};
        w3 = {17'd0, tx_valid, tx_byte, tx_idx, state};
        w4 = {crc_state, silence, rx_len};

        if ((^rx_addr === 1'bx) || (^rx_func === 1'bx) || (^rx_len === 1'bx))   bad = 1'b1;
        if ((^crc_state === 1'bx) || (^silence === 1'bx) || (^state === 1'bx))  bad = 1'b1;
        if ((tx_valid === 1'bx) || (^tx_byte === 1'bx) || (^tx_idx === 1'bx))    bad = 1'b1;
        if ((^crc_err_count === 1'bx) || (^short_count === 1'bx))                bad = 1'b1;
        if ((^not_addr_count === 1'bx) || (^broadcast_count === 1'bx))           bad = 1'b1;
        if ((^exc_count === 1'bx) || (^frame_count === 1'bx))                    bad = 1'b1;
        // structural invariants of the written contract
        if (state > S_ANS_C)                                                      bad = 1'b1;
        if (tx_idx > 3'd4)                                                        bad = 1'b1;
        if ((tx_valid === 1'b1) && (state !== S_ANS_C))                           bad = 1'b1;
        if ((tx_valid === 1'b0) && (state === S_ANS_C) && (pstate !== S_RX_C))     bad = 1'b1;
        if ((i > 0) && (en_b[i] === 1'b0) && ((w1 !== pw1) || (w2 !== pw2) ||
            (w3 !== pw3) || (w4 !== pw4)))                                        bad = 1'b1;
        if ((i > 0) && (en_b[i] === 1'b1) && (tick_b[i] === 1'b0) &&
            (rv_b[i] === 1'b0) && (pstate !== S_ANS_C) &&
            ((w1 !== pw1) || (w2 !== pw2) || (w3 !== pw3) || (w4 !== pw4)))       bad = 1'b1;
        if ((state === S_RX_C) && (rx_len === 8'h00))                             bad = 1'b1;

        ips_fnv_word(w1);
        ips_fnv_word(w2);
        ips_fnv_word(w3);
        ips_fnv_word(w4);
        pw1    = w1;
        pw2    = w2;
        pw3    = w3;
        pw4    = w4;
        pstate = state;
        if (dump && ((i % 128) == 127)) $display("DBG %0d %h %h %h %h", i, w1, w2, w3, w4);
    end

    ips_fnv_word(nbeats);
    ips_verdict(!bad, "ips_modbus_rtu_fsm");
end

endmodule
