`timescale 1ns / 1ps
// tb_ips_spi_slave_reg : production-line bench for the SPI mode 0-3 slave.
//
// There is no bus simulator in this flow, so the four wires are bit-banged here
// from a fixed half-period SP, i.e. from a deterministic divisor of the test
// clock, and miso is a real tri-state net (pullup plus the core's own driver).
// models/ips_spi_slave_reg.py replays exactly the same per-cycle pin vector
// (mosi, sclk, ss_n, sample-marker), so the golden digest is period-exact rather
// than merely functional.
//
// Symbol layout, in enabled clock cycles, for the default mode 0 (idle clock
// low, sample on the rising edge, launch on the falling edge):
//   bit      : mosi=v, sclk=0, ss_n=0 for SP cycles, then sclk=1 for SP cycles.
//              The third cycle of the high half also samples the miso pin.
//   cs low   : ss_n=0 for 4 cycles with sclk low (the CS-edge alignment event).
//   cs high  : sclk=0 for 3 cycles, then ss_n=1 for 3 cycles.
//   idle     : mosi=1, sclk=0, ss_n=1 for 6 cycles.
//   no-cs    : SP/SP clock pulses while ss_n stays high (protocol violation).
// Violations exercised: a frame aborted mid-byte by the CS rise (o_err_short and
// o_rem) and sampling edges seen with ss_n inactive (o_err_no_cs).
module tb_ips_spi_slave_reg;

`include "ips_tb_common.vh"

localparam integer SP   = 4;
localparam integer NTR  = 224;
localparam [31:0]  SEED = 32'h3A9C77D5;

reg                 rst_n;
reg                 clk_en;
reg                 tb_mosi;
reg                 tb_sclk;
reg                 tb_ss;
reg  [31:0]         state;
reg  [7:0]          cmd, d0, d1, d2, d3;
reg  [15:0]         mrx;
reg  [3:0]          sc0, nc0;
reg  [7:0]          xf0, pt0, rx0b;
reg                 smp;
wire                miso;

wire [15:0]         o_rx;
wire [15:0]         o_tx;
wire [7:0]          ptr;
wire [2:0]          o_state;
wire [3:0]          o_err_no_cs;
wire [3:0]          o_err_short;
wire [7:0]          o_xfer;
wire [3:0]          o_rem;
wire                o_drive;
wire                o_txb;
wire                o_rw;

pullup (miso);

ips_spi_slave_reg dut (
    .clk          (ips_clk),
    .clk_en       (clk_en),
    .rst_n        (rst_n),
    .ss_n         (tb_ss),
    .sclk         (tb_sclk),
    .mosi         (tb_mosi),
    .miso         (miso),
    .o_rx         (o_rx),
    .o_tx         (o_tx),
    .ptr          (ptr),
    .o_state      (o_state),
    .o_err_no_cs  (o_err_no_cs),
    .o_err_short  (o_err_short),
    .o_xfer       (o_xfer),
    .o_rem        (o_rem),
    .o_drive      (o_drive),
    .o_txb        (o_txb),
    .o_rw         (o_rw)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

integer t, j, kind, i;
reg     bad;
reg     dump;

task fold;
    input [31:0] w;
    begin
        if (dump) begin
            $display("W %08h", w);
        end
        ips_fnv_word(w);
    end
endtask

task ph;
    input mv;
    input cv;
    input sv;
    input integer n;
    begin
        for (j = 0; j < n; j = j + 1) begin
            @(negedge ips_clk);
            tb_mosi = mv;
            tb_sclk = cv;
            tb_ss   = sv;
        end
    end
endtask

// one cycle that additionally samples the tri-state pin, as a real master does
// in the middle of the sampling half-period.
task phs;
    input mv;
    input samp;
    begin
        @(negedge ips_clk);
        tb_mosi = mv;
        tb_sclk = 1'b1;
        tb_ss   = 1'b0;
        smp     = miso;
        if (samp) begin
            mrx = {mrx[14:0], smp};
            if ((o_drive === 1'b1) && (smp !== o_txb)) begin
                if (dump) begin
                    $display("PINBAD t=%0d kind=%0d smp=%b txb=%b drive=%b state=%0d",
                             t, kind, smp, o_txb, o_drive, o_state);
                end
                bad = 1'b1;
            end
        end
    end
endtask

task spbit;
    input mv;
    input samp;
    begin
        ph(mv, 1'b0, 1'b0, SP);
        ph(mv, 1'b1, 1'b0, SP - 2);
        phs(mv, samp);
        ph(mv, 1'b1, 1'b0, 1);
    end
endtask

task frame_w;
    input [7:0] v;
    begin
        for (i = 7; i >= 0; i = i - 1) begin
            spbit(v[i], 1'b0);
        end
    end
endtask

// during a read the slave owns miso, so the bench leaves mosi idle high
task frame_r;
    begin
        for (i = 7; i >= 0; i = i - 1) begin
            spbit(1'b1, 1'b1);
        end
    end
endtask

task cs_low;
    begin
        ph(1'b1, 1'b0, 1'b0, 4);
    end
endtask

task cs_high;
    begin
        ph(1'b1, 1'b0, 1'b0, 3);
        ph(1'b1, 1'b0, 1'b1, 3);
    end
endtask

task idle_sym;
    begin
        ph(1'b1, 1'b0, 1'b1, 6);
    end
endtask

task noclock;
    input integer n;
    begin
        for (i = 0; i < n; i = i + 1) begin
            ph(1'b1, 1'b0, 1'b1, SP);
            ph(1'b1, 1'b1, 1'b1, SP);
        end
        ph(1'b1, 1'b0, 1'b1, 2);
    end
endtask

initial begin
    ips_fnv_reset();
    rst_n   = 1'b0;
    clk_en  = 1'b0;
    tb_mosi = 1'b1;
    tb_sclk = 1'b0;
    tb_ss   = 1'b1;
    state   = SEED;
    bad     = 1'b0;
    mrx     = 16'h0000;
    smp     = 1'b1;
    cmd     = 8'h00;
    d0      = 8'h00;
    d1      = 8'h00;
    d2      = 8'h00;
    d3      = 8'h00;
    sc0     = 4'h0;
    nc0     = 4'h0;
    xf0     = 8'h00;
    pt0     = 8'h00;
    rx0b    = 8'h00;
    dump    = ($test$plusargs("dump") != 0);

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);
    clk_en = 1'b1;

    ph(1'b1, 1'b0, 1'b1, 8);

    for (t = 0; t < NTR; t = t + 1) begin
        state = state * 32'd1664525 + 32'd1013904223;
        d0    = state[15:8];
        d1    = state[23:16];
        d2    = state[31:24];
        d3    = state[7:0] ^ 8'h5A;
        sc0   = o_err_short;
        nc0   = o_err_no_cs;
        xf0   = o_xfer;
        pt0   = ptr;
        rx0b  = o_rx[7:0];
        kind  = t % 8;

        if (kind == 0) begin
            // read three bytes from a rotating base index
            cs_low;
            frame_w(8'h80 | (d3 & 8'h07));
            frame_r;
            frame_r;
            frame_r;
            cs_high; idle_sym;
            if (o_rw !== 1'b1) begin
                if (dump) $display("RWBAD t=%0d", t);
                bad = 1'b1;
            end
        end
        else if (kind == 1) begin
            // write three bytes with pointer auto-increment, then read them back
            cs_low;
            frame_w(d3 & 8'h07);
            frame_w(d0);
            frame_w(d1);
            frame_w(d2);
            cs_high; idle_sym;
            cs_low;
            frame_w(8'h80 | (d3 & 8'h07));
            frame_r;
            frame_r;
            frame_r;
            cs_high; idle_sym;
            if (o_rw !== 1'b1) begin
                if (dump) $display("RWBAD t=%0d", t);
                bad = 1'b1;
            end
        end
        else if (kind == 2) begin
            // protocol violation: CS rises five bits into a frame
            cs_low;
            frame_w(d0);
            spbit(d1[7], 1'b0);
            spbit(d1[6], 1'b0);
            spbit(d1[5], 1'b0);
            spbit(d1[4], 1'b0);
            spbit(d1[3], 1'b0);
            cs_high; idle_sym;
            if ((o_err_short !== (sc0 + 4'd1)) || (o_rem !== 4'd5)
                || (o_xfer !== (xf0 + 8'd1))) begin
                if (dump) $display("SHORTBAD t=%0d sh=%h exp=%h rem=%h xfer=%h expx=%h",
                                   t, o_err_short, sc0 + 4'd1, o_rem, o_xfer,
                                   xf0 + 8'd1);
                bad = 1'b1;
            end
        end
        else if (kind == 3) begin
            // protocol violation: clock edges with ss_n inactive
            idle_sym;
            noclock(3);
            idle_sym;
            if ((o_err_no_cs !== (nc0 + 4'd3)) || (o_xfer !== xf0)
                || (ptr !== pt0) || (o_rx[7:0] !== rx0b)) begin
                if (dump) $display("NOCSBAD t=%0d nc=%h xfer=%h ptr=%h rx=%h",
                                   t, o_err_no_cs, o_xfer, ptr, o_rx[7:0]);
                bad = 1'b1;
            end
        end
        else if (kind == 4) begin
            // self-consistent aliasing probe: store at 0x02, read back at 0x02
            cs_low;
            frame_w(8'h02);
            frame_w(d0);
            cs_high; idle_sym;
            cs_low;
            frame_w(8'h82);
            frame_r;
            cs_high; idle_sym;
        end
        else if (kind == 5) begin
            // store at 0x05 then read at 0x04: bit 1 of the file mask matters
            cs_low;
            frame_w(8'h05);
            frame_w(d1);
            cs_high; idle_sym;
            cs_low;
            frame_w(8'h84);
            frame_r;
            cs_high; idle_sym;
        end
        else if (kind == 6) begin
            // store at 0x0C then read at 0x04: bit 3 of the file mask matters
            cs_low;
            frame_w(8'h0C);
            frame_w(d2);
            cs_high; idle_sym;
            cs_low;
            frame_w(8'h84);
            frame_r;
            cs_high; idle_sym;
        end
        else begin
            // long read at a fixed index: exercises the masked increment chain
            cs_low;
            frame_w(8'h84);
            frame_r;
            frame_r;
            frame_r;
            frame_r;
            cs_high; idle_sym;
            cs_low;
            frame_w(8'h04);
            frame_w(d3);
            frame_w(d0);
            cs_high; idle_sym;
        end

        if (o_state !== 3'd0) begin
            if (dump) begin
                $display("STATEBAD t=%0d kind=%0d st=%0d ptr=%02h rx=%02h tx=%02h mrx=%04h nc=%h sh=%h rem=%h xfer=%02h",
                         t, kind, o_state, ptr, o_rx, o_tx, mrx,
                         o_err_no_cs, o_err_short, o_rem, o_xfer);
            end
            bad = 1'b1;
        end
        if ((^{o_state, ptr, o_rx, o_tx, o_err_no_cs, o_err_short, o_xfer,
              o_rem, o_drive, o_txb, o_rw}) !== 1'b0 &&
            (^{o_state, ptr, o_rx, o_tx, o_err_no_cs, o_err_short, o_xfer,
              o_rem, o_drive, o_txb, o_rw}) !== 1'b1) begin
            bad = 1'b1;
        end

        fold({26'd0, o_state, o_rw, o_drive, o_txb});
        fold({24'd0, ptr});
        fold({16'd0, o_rx});
        fold({16'd0, o_tx});
        fold({16'd0, mrx});
        fold({20'd0, o_err_no_cs, o_err_short, o_rem});
        fold({24'd0, o_xfer});
        mrx = 16'h0000;
    end

    ips_verdict(!bad, "ips_spi_slave_reg");
end

endmodule
