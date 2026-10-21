`timescale 1ns / 1ps
// tb_ips_mdio_master : production-line bench for the Clause 22 MDIO master.
//
// There is no board and no bus simulator in this flow, so mdio is a real
// tri-state net (a pull-up plus the open-drain drivers of the core and of the
// reference PHY modelled here) and mdc is produced by the core from a tick pin
// that this bench generates from a fixed half-period TK, i.e. from a
// deterministic divisor of the test clock.  models/ips_mdio_master.py replays
// the identical per-cycle pin vector (tick, start, rnw, phy_addr, wdata) plus
// the same PHY bit-time schedule, so the golden digest is period-exact.
//
// Bit-time index of the frame (a bit-time is one MDC period; the bench counts
// mdc falls from the start pulse, the core counts its own ticks):
//   0..31 preamble, 32..33 ST, 34..35 OP, 36..40 PA, 41 turnaround Z,
//   42.. turnaround wait, 43+d..58+d data, then one released hand-back bit-time.
// bits[b] holds the line LEVEL seen during bit-time b, so the preamble reads
// all ones (released) and a driven 0 reads 0.  The reference PHY sinks the line
// at bit-time 42+d (turnaround) and then shifts pw out MSB first over
// 43+d..58+d; d is the bench's turnaround-delay knob.
// Violations exercised: a turnaround that arrives after TMO_LIMIT (timeout), a
// PHY that never answers at all (timeout), a start pulse injected while a frame
// is in flight (must be ignored) and a PHY that drives its own word while the
// master writes (bus contention, which the master's read-back shifter sees).
module tb_ips_mdio_master;

`include "ips_tb_common.vh"

localparam integer TK   = 3;
localparam integer NTB  = 64;
localparam integer NTR  = 224;
localparam [31:0]  SEED = 32'h6D2F7A13;

reg                 rst_n;
reg                 clk_en;
reg                 tb_tick;
reg                 tb_start;
reg                 tb_rnw;
reg  [4:0]          tb_pa;
reg  [17:0]         tb_wd;
reg                 tb_dl;
reg  [31:0]         state;
reg  [7:0]          d0, d1;
reg  [4:0]          pab;
reg  [4:0]          pax;
reg  [15:0]         pw;
reg  [5:0]          bt;
reg  [5:0]          bi;
reg  [63:0]         bits;
reg  [16:0]         slip;
reg                 ph_data;
reg                 ph_ack;
reg  [7:0]          ph_ta;
reg  [7:0]          ph_d0;
reg  [7:0]          dd8;
reg  [3:0]          to0;
integer             idx;
integer             dly;
wire                mdio;
wire                mdc;

wire [17:0]         o_rdata;
wire [17:0]         o_sh;
wire [2:0]          o_state;
wire [5:0]          o_bc;
wire [6:0]          o_pos;
wire [2:0]          o_waits;
wire [8:0]          o_cmd;
wire [7:0]          o_txn;
wire [3:0]          o_err_to;
wire                o_own;
wire                o_busy;
wire                o_lo;

pullup (mdio);
// the reference PHY is open drain as well: it only ever sinks the line.
assign mdio = tb_dl ? 1'b0 : 1'bz;

ips_mdio_master dut (
    .clk        (ips_clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .tick       (tb_tick),
    .start      (tb_start),
    .rnw        (tb_rnw),
    .phy_addr   (tb_pa),
    .wdata      (tb_wd[15:0]),
    .mdio       (mdio),
    .mdc        (mdc),
    .o_state    (o_state),
    .o_bc       (o_bc),
    .o_pos      (o_pos),
    .o_waits    (o_waits),
    .o_rdata    (o_rdata),
    .o_sh       (o_sh),
    .o_cmd      (o_cmd),
    .o_txn      (o_txn),
    .o_err_to   (o_err_to),
    .o_own      (o_own),
    .o_busy     (o_busy),
    .o_lo       (o_lo)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

integer t, j, k, kind;
reg     bad;
reg     dump;
reg     c1, c2, c3, c4, c5;

task fold;
    input [31:0] w;
    begin
        if (dump) begin
            $display("W %08h", w);
        end
        ips_fnv_word(w);
    end
endtask

// the reference PHY sink request for bit-time b (1 = pulling the line low)
function drive_phy;
    input [5:0] b;
    begin
        if (ph_data && (({2'd0, b} >= ph_d0) && ({2'd0, b} < (ph_d0 + 8'd16)))) begin
            idx       = {2'd0, b} - ph_d0;
            drive_phy = (pw[15 - idx] === 1'b0);
        end
        else if (ph_ack && ({2'd0, b} == ph_ta)) begin
            drive_phy = 1'b1;
        end
        else begin
            drive_phy = 1'b0;
        end
    end
endfunction

// bit-time watcher in the clock domain, so the model can replay it exactly
reg mdc_d;
always @(negedge ips_clk) begin
    if ((rst_n === 1'b1) && (clk_en === 1'b1)) begin
        if ((mdc_d === 1'b1) && (mdc === 1'b0)) begin
            bt    = bt + 6'd1;
            tb_dl = drive_phy(bt);
        end
        else if ((mdc_d === 1'b0) && (mdc === 1'b1)) begin
            bits[bi] = (mdio === 1'b1);
            bi       = bi + 6'd1;
            slip     = {slip[15:0], (mdio === 1'b1)};
        end
        mdc_d = mdc;
    end
end

task ph;
    input tk;
    input st;
    input [4:0] a;
    input integer n;
    begin
        for (k = 0; k < n; k = k + 1) begin
            @(negedge ips_clk);
            tb_tick  = tk;
            tb_start = st;
            tb_pa    = a;
        end
    end
endtask

// one MDC half period: one tick cycle, then TK-1 idle cycles
task halfk;
    input tk;
    input st;
    input [4:0] a;
    begin
        ph(tk, st, a, 1);
        ph(1'b0, st, a, TK - 1);
    end
endtask

task set_req;
    input r;
    input [4:0] a;
    input [15:0] d;
    input s;
    begin
        @(negedge ips_clk);
        tb_rnw  = r;
        tb_wd   = {2'd0, d};
        tb_tick = 1'b0;
        tb_start = s;
        tb_pa   = a;
    end
endtask

task phy_cfg;
    input integer dd;
    input dat;
    input ack;
    begin
        dd8     = dd;
        ph_data = dat;
        ph_ack  = ack;
        ph_ta   = 8'd42 + dd8;
        ph_d0   = 8'd43 + dd8;
    end
endtask

task xact;
    input  r;
    input  [4:0] a;
    input  [15:0] d;
    input  dat;
    input  ack;
    input  inj;
    input  [4:0] a2;
    begin
        bt    = 6'd0;
        bi    = 6'd0;
        bits  = 64'h0;
        slip  = 17'h0;
        tb_dl = 1'b0;
        phy_cfg(dly, dat, ack);
        set_req(r, a, d, 1'b1);
        halfk(1'b1, 1'b1, a);
        halfk(1'b1, 1'b1, a);
        set_req(r, a, d, 1'b0);
        for (j = 0; j < 2 * NTB - 4; j = j + 1) begin
            if (inj && ((j == 20) || (j == 21))) begin
                halfk(1'b1, 1'b1, a2);
            end
            else begin
                halfk(1'b1, 1'b0, a);
            end
        end
        ph(1'b0, 1'b0, a, 16);
    end
endtask

initial begin
    ips_fnv_reset();
    rst_n    = 1'b0;
    clk_en   = 1'b0;
    tb_tick  = 1'b0;
    tb_start = 1'b0;
    tb_rnw   = 1'b0;
    tb_pa    = 5'd0;
    tb_wd    = 18'h00000;
    tb_dl    = 1'b0;
    state    = SEED;
    bad      = 1'b0;
    bt       = 6'd0;
    bi       = 6'd0;
    bits     = 64'h0;
    slip     = 17'h0;
    mdc_d    = 1'b0;
    ph_data  = 1'b0;
    ph_ack   = 1'b0;
    ph_ta    = 8'd42;
    ph_d0    = 8'd43;
    dd8      = 8'd0;
    d0       = 8'h00;
    d1       = 8'h00;
    pab      = 5'd0;
    pax      = 5'd0;
    pw       = 16'h0000;
    to0      = 4'h0;
    idx      = 0;
    dly      = 0;
    dump     = ($test$plusargs("dump") != 0);

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);
    clk_en = 1'b1;

    ph(1'b0, 1'b0, 5'd0, 8);

    for (t = 0; t < NTR; t = t + 1) begin
        state = state * 32'd1664525 + 32'd1013904223;
        d0    = state[15:8];
        d1    = state[23:16];
        pab   = state[7:3];
        pax   = pab;
        pw    = {d0, d1};
        kind  = t % 8;
        to0   = o_err_to;

        case (kind)
            0: begin                             // read, turnaround present
                dly = 0;
                xact(1'b1, pab, 16'h0000, 1'b1, 1'b1, 1'b0, 5'd0);
            end
            1: begin                             // read, one wait bit-time
                dly = 1;
                xact(1'b1, pab, 16'h0000, 1'b1, 1'b1, 1'b0, 5'd0);
            end
            2: begin                             // read, turnaround arrives late
                dly = 3;
                xact(1'b1, pab, 16'h0000, 1'b0, 1'b1, 1'b0, 5'd0);
            end
            3: begin                             // write, PHY keeps off the bus
                dly = 0;
                pax = 5'd13;
                xact(1'b0, 5'd13, {8'h00, d1}, 1'b0, 1'b0, 1'b0, 5'd0);
            end
            4: begin                             // read, two wait bit-times
                dly = 2;
                xact(1'b1, pab, 16'h0000, 1'b1, 1'b1, 1'b0, 5'd0);
            end
            5: begin                             // read with an ignored re-start
                dly = 0;
                xact(1'b1, pab, 16'h0000, 1'b1, 1'b1, 1'b1, 5'd21);
            end
            6: begin                             // read, PHY never answers
                dly = 99;
                xact(1'b1, pab, 16'h0000, 1'b0, 1'b0, 1'b0, 5'd0);
            end
            default: begin                       // write while the PHY drives
                dly = 1;
                xact(1'b0, pab, 16'hFFFF, 1'b1, 1'b0, 1'b0, 5'd0);
            end
        endcase

        c1 = (o_busy === 1'b0);
        c2 = (o_own === 1'b0);
        c3 = ((o_lo === 1'b0) && (tb_dl === 1'b0)) ? (mdio === 1'b1) : 1'b1;
        c4 = (o_rdata[15:0] === slip[16:1]);
        // bits[b] is the line level during bit-time b, so a field that is sent
        // MSB first appears bit-reversed in the vector.
        c5 = (bits[31:0] === 32'hFFFFFFFF)
             && (bits[33:32] === 2'b10)
             && (bits[40:36] === {pax[0], pax[1], pax[2], pax[3], pax[4]});
        if (kind == 0 || kind == 1 || kind == 4 || kind == 5) begin
            c5 = c5 && (o_rdata[15:0] === pw);
        end
        if (kind == 3) begin
            c5 = c5 && (o_rdata[15:0] === {8'h00, d1});
        end
        if (kind == 5) begin
            c5 = c5 && (o_cmd[4:0] === pab) && (o_txn !== (o_txn - 8'd1));
        end
        if (kind == 6) begin
            c5 = c5 && (o_err_to === (to0 + 4'd1));
        end
        if (kind == 7) begin
            c5 = c5 && (o_rdata[15:0] === {1'b1, pw[15:1]});
        end

        if (!c1 || !c2 || !c3 || !c4 || !c5) begin
            if (dump) begin
                $display("CHKBAD t=%0d kind=%0d c1=%b c2=%b c3=%b c4=%b c5=%b st=%0d pos=%0d bc=%0d w=%0d rdata=%04h slip=%04h bits=%04h txn=%02h err=%h cmd=%03h",
                         t, kind, c1, c2, c3, c4, c5, o_state, o_pos, o_bc,
                         o_waits, o_rdata[15:0], slip[16:1], bits[31:16],
                         o_txn, o_err_to, o_cmd);
            end
            bad = 1'b1;
        end
        if ((^{o_state, o_bc, o_pos, o_waits, o_rdata[15:0], o_sh[15:0], o_cmd,
              o_txn, o_err_to, o_own, o_busy, o_lo}) !== 1'b0 &&
            (^{o_state, o_bc, o_pos, o_waits, o_rdata[15:0], o_sh[15:0], o_cmd,
              o_txn, o_err_to, o_own, o_busy, o_lo}) !== 1'b1) begin
            bad = 1'b1;
        end

        fold({27'd0, o_state, o_own, o_lo});
        fold({16'd0, o_rdata[15:0]});
        fold({16'd0, o_sh[15:0]});
        fold({23'd0, o_bc, o_waits});
        fold({25'd0, o_pos});
        fold({24'd0, o_txn});
        fold({28'd0, o_err_to});
        fold({22'd0, o_cmd, o_busy});
    end

    ips_verdict(!bad, "ips_mdio_master");
end

endmodule
