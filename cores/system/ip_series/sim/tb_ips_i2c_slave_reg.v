`timescale 1ns / 1ps
// tb_ips_i2c_slave_reg : production-line bench for the I2C slave register file.
//
// There is no bus simulator in this flow, so the two wires are bit-banged here:
// the scl level and the open-drain sda drive are assigned every negedge from a
// fixed half-bit period H, i.e. from a deterministic divisor of the test clock.
// models/ips_i2c_slave_reg.py replays exactly the same symbol sequence cycle by
// cycle, so the golden digest is period-exact rather than merely functional.
//
// Symbol layout (all lengths in enabled clock cycles):
//   bit      : sda=v for H cycles with scl low, then v for H cycles with scl high
//   start    : (sda=1,scl=1) x 3, then (sda=0,scl=1) -> fall while SCL high
//   restart  : (1,0) x 2, (1,1) x 2, (0,1) x 1
//   stop     : (0,0) x H, (0,1) x 2, (1,1) x 1 -> rise while SCL high
//   idle     : (1,1) x 6
// Violations exercised: un-matched slave address (NACK + error counter) and a
// premature STOP in the middle of the address byte.
module tb_ips_i2c_slave_reg;

`include "ips_tb_common.vh"

localparam integer H    = 4;
localparam integer NTR  = 224;
localparam [31:0]  SEED = 32'h51E2B17C;
localparam [6:0]   SADR = 7'h34;

reg                 rst_n;
reg                 clk_en;
reg                 tb_scl;
reg                 tb_dl;
reg  [31:0]         state;
reg  [7:0]          pbyte, d0, d1, d2, d3, d4;
reg                 smp;
wire                sda;

wire [2:0]          o_state;
wire [7:0]          ptr;
wire [7:0]          o_rdata;
wire [7:0]          o_last;
wire [3:0]          o_err_nam;
wire [3:0]          o_err_fmt;
wire [7:0]          o_txn;
wire                o_ack;
wire                o_lo;

pullup (sda);
// the bench master is open drain as well: it only ever sinks the line.
assign sda = tb_dl ? 1'b0 : 1'bz;

ips_i2c_slave_reg dut (
    .clk        (ips_clk),
    .clk_en     (clk_en),
    .rst_n      (rst_n),
    .scl        (tb_scl),
    .sda        (sda),
    .o_state    (o_state),
    .ptr        (ptr),
    .o_rdata    (o_rdata),
    .o_last     (o_last),
    .o_err_nam  (o_err_nam),
    .o_err_fmt  (o_err_fmt),
    .o_txn      (o_txn),
    .o_ack      (o_ack),
    .o_lo       (o_lo)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

integer t, j, kind;
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
    input        v;
    input        c;
    input integer n;
    begin
        for (j = 0; j < n; j = j + 1) begin
            @(negedge ips_clk);
            tb_dl  = ~v;
            tb_scl = c;
        end
    end
endtask

task bit_sym;
    input v;
    begin
        ph(v, 1'b0, H);
        ph(v, 1'b1, H);
    end
endtask

task start_sym;
    begin
        ph(1'b1, 1'b1, 3);
        ph(1'b0, 1'b1, 1);
    end
endtask

task restart_sym;
    begin
        ph(1'b1, 1'b0, 2);
        ph(1'b1, 1'b1, 2);
        ph(1'b0, 1'b1, 1);
    end
endtask

task stop_sym;
    begin
        ph(1'b0, 1'b0, H);
        ph(1'b0, 1'b1, 2);
        ph(1'b1, 1'b1, 1);
    end
endtask

task idle_sym;
    begin
        ph(1'b1, 1'b1, 6);
    end
endtask

task byte_sym;
    input [7:0] v;
    integer i;
    begin
        for (i = 7; i >= 0; i = i - 1) begin
            bit_sym(v[i]);
        end
    end
endtask

// ninth clock of a received byte: the slave owns sda, so the bench releases the
// line and checks that the acknowledge level matches the address comparison.
task recv_ack;
    input expect_ack;
    begin
        ph(1'b1, 1'b0, H);
        ph(1'b1, 1'b1, 2);
        @(negedge ips_clk);
        smp = sda;
        ph(1'b1, 1'b1, 1);
        if (smp !== (expect_ack ? 1'b0 : 1'b1)) begin
            if (dump) begin
                $display("ACKBAD t=%0d smp=%b exp=%b state=%0d bits_done", t, smp, expect_ack, o_state);
            end
            bad = 1'b1;
        end
    end
endtask

// during a read the slave owns sda, so the bench releases it for all eight
// clocks and only drives the acknowledge that follows.
task read_byte;
    integer i;
    begin
        for (i = 7; i >= 0; i = i - 1) begin
            bit_sym(1'b1);
        end
    end
endtask

task addr_phase;
    input [7:0] ab;
    input       expect_ack;
    begin
        byte_sym(ab);
        recv_ack(expect_ack);
    end
endtask

initial begin
    ips_fnv_reset();
    rst_n   = 1'b0;
    clk_en  = 1'b0;
    tb_scl  = 1'b1;
    tb_dl   = 1'b0;
    state   = SEED;
    bad     = 1'b0;
    pbyte   = 8'h00;
    d0      = 8'h00;
    d1      = 8'h00;
    d2      = 8'h00;
    d3      = 8'h00;
    d4      = 8'h00;
    smp     = 1'b1;
    dump    = ($test$plusargs("dump") != 0);

    repeat (4) @(posedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(posedge ips_clk);
    clk_en = 1'b1;

    ph(1'b1, 1'b1, 8);

    for (t = 0; t < NTR; t = t + 1) begin
        state  = state * 32'd1664525 + 32'd1013904223;
        pbyte  = state[7:0] | 8'h0C;
        d0     = state[15:8];
        d1     = state[23:16];
        d2     = state[31:24];
        d3     = d0 + d1;
        d4     = d2 ^ 8'h5A;
        kind   = t % 8;

        if (kind == 0) begin
            start_sym;
            addr_phase({SADR, 1'b0}, 1'b1);
            byte_sym(pbyte); recv_ack(1'b1);
            byte_sym(d0);    recv_ack(1'b1);
            byte_sym(d1);    recv_ack(1'b1);
            stop_sym;  idle_sym;
        end
        else if (kind == 1) begin
            start_sym;
            addr_phase({SADR, 1'b0}, 1'b1);
            byte_sym(pbyte); recv_ack(1'b1);
            restart_sym;
            addr_phase({SADR, 1'b1}, 1'b1);
            read_byte;  bit_sym(1'b0);      // slave byte, master ACK
            read_byte;  bit_sym(1'b0);
            read_byte;  bit_sym(1'b1);      // last byte, master NACK
            stop_sym;  idle_sym;
        end
        else if (kind == 2) begin
            // write at pointer 0x0C: only visible through the file-index mask
            start_sym;
            addr_phase({SADR, 1'b0}, 1'b1);
            byte_sym(8'h0C); recv_ack(1'b1);
            byte_sym(d0);    recv_ack(1'b1);
            stop_sym;  idle_sym;
        end
        else if (kind == 3) begin
            // store at 0x05, then read back at 0x04: aliasing of bit 1 matters
            start_sym;
            addr_phase({SADR, 1'b0}, 1'b1);
            byte_sym(8'h05); recv_ack(1'b1);
            byte_sym(d1);    recv_ack(1'b1);
            restart_sym;
            addr_phase({SADR, 1'b0}, 1'b1);
            byte_sym(8'h04); recv_ack(1'b1);
            restart_sym;
            addr_phase({SADR, 1'b1}, 1'b1);
            read_byte;  bit_sym(1'b1);
            stop_sym;  idle_sym;
        end
        else if (kind == 4) begin
            // protocol violation: no slave owns this address, expect NACK
            start_sym;
            addr_phase({SADR, 1'b0} + 8'h08, 1'b0);
            byte_sym(d0);    bit_sym(1'b1);
            stop_sym;  idle_sym;
        end
        else if (kind == 5) begin
            // protocol violation: premature STOP inside the address byte
            start_sym;
            bit_sym(pbyte[7]);
            bit_sym(pbyte[6]);
            bit_sym(pbyte[5]);
            stop_sym;  idle_sym;
        end
        else if (kind == 6) begin
            start_sym;
            addr_phase({SADR, 1'b0}, 1'b1);
            byte_sym(pbyte); recv_ack(1'b1);
            byte_sym(d0);    recv_ack(1'b1);
            byte_sym(d1);    recv_ack(1'b1);
            byte_sym(d2);    recv_ack(1'b1);
            byte_sym(d3);    recv_ack(1'b1);
            byte_sym(d4);    recv_ack(1'b1);
            stop_sym;  idle_sym;
        end
        else begin
            // read one byte, repeated start into a write, then read at a fixed
            // pointer: exercises bit 3 of the file-index mask
            start_sym;
            addr_phase({SADR, 1'b1}, 1'b1);
            read_byte;  bit_sym(1'b0);
            restart_sym;
            addr_phase({SADR, 1'b0}, 1'b1);
            byte_sym(8'h04); recv_ack(1'b1);
            restart_sym;
            addr_phase({SADR, 1'b1}, 1'b1);
            read_byte;  bit_sym(1'b1);
            stop_sym;  idle_sym;
        end

        if (o_state !== 3'd0) begin
            if (dump) begin
                $display("STATEBAD t=%0d kind=%0d st=%0d bits_seen ptr=%02h rdata=%02h last=%02h nam=%h fmt=%h txn=%02h",
                         t, kind, o_state, ptr, o_rdata, o_last, o_err_nam, o_err_fmt, o_txn);
            end
            bad = 1'b1;
        end
        if ((^{o_state, ptr, o_rdata, o_last, o_err_nam, o_err_fmt, o_txn, o_ack, o_lo})
            !== 1'b0 &&
            (^{o_state, ptr, o_rdata, o_last, o_err_nam, o_err_fmt, o_txn, o_ack, o_lo})
            !== 1'b1) begin
            bad = 1'b1;
        end

        fold({27'd0, o_state, o_ack, o_lo});
        fold({24'd0, ptr});
        fold({24'd0, o_rdata});
        fold({24'd0, o_last});
        fold({24'd0, o_err_nam, o_err_fmt});
        fold({24'd0, o_txn});
    end

    ips_verdict(!bad, "ips_i2c_slave_reg");
end

endmodule
