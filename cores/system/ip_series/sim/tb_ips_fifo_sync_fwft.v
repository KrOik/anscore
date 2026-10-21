`timescale 1ns / 1ps
// tb_ips_fifo_sync_fwft : production-line testbench for the FWFT FIFO.
//
// BEATS deterministic beats: a write-only stretch that fills the FIFO and then
// keeps writing past full (overflow path), a read-only stretch that drains it
// and keeps reading past empty (underflow path), then a concurrent read/write
// phase driven from the shared LCG contract.  Watermarks are reprogrammed mid
// run.  level and rdata are sampled wider than the ports so a widened DATA_W or
// DEPTH reaches the digest; checks use === / !== only (trap T6).  The expected
// stream is computed independently by models/ips_fifo_sync_fwft.py (trap T1).
module tb_ips_fifo_sync_fwft;

`include "ips_tb_common.vh"

localparam integer BEATS = 500;
localparam [31:0]  SEED  = 32'h13572468;

reg         rst_n;
reg         clk_en;
reg         wr_req;
reg         rd_req;
reg [11:0]  wdata;
reg [7:0]   wm_hi;
reg [7:0]   wm_lo;
reg [31:0]  state;

wire [11:0] rdata;
wire        full;
wire        empty;
wire [7:0]  level;
wire        flag_hi;
wire        flag_lo;
wire        ov_flag;
wire        uf_flag;
wire [3:0]  ov_count;
wire [3:0]  uf_count;

// No #() override: the TB exercises the declared default geometry.
ips_fifo_sync_fwft dut (
    .clk      (ips_clk),
    .clk_en   (clk_en),
    .rst_n    (rst_n),
    .wr_req   (wr_req),
    .wdata    (wdata),
    .rd_req   (rd_req),
    .wm_hi    (wm_hi),
    .wm_lo    (wm_lo),
    .rdata    (rdata),
    .full     (full),
    .empty    (empty),
    .level    (level),
    .flag_hi  (flag_hi),
    .flag_lo  (flag_lo),
    .ov_flag  (ov_flag),
    .uf_flag  (uf_flag),
    .ov_count (ov_count),
    .uf_count (uf_count)
);

always @(posedge ips_clk) begin
    if (clk_en === 1'b1) begin
        ips_cycle = ips_cycle + 32'd1;
    end
end

function [7:0] wmhi_at;
    input integer n;
    begin
        wmhi_at = (n < 150) ? 8'd12 : 8'd5;
    end
endfunction

function [7:0] wmlo_at;
    input integer n;
    begin
        wmlo_at = (n < 260) ? 8'd1 : 8'd3;
    end
endfunction

task drive_beat;
    input integer n;
    begin
        state = state * 32'd1664525 + 32'd1013904223;
        wdata = state[11:0];
        if (n < 130) begin
            wr_req = 1'b1;
            rd_req = 1'b0;
        end else if (n < 230) begin
            wr_req = 1'b0;
            rd_req = 1'b1;
        end else begin
            wr_req = ~state[3];
            rd_req = ~state[1];
        end
        wm_hi = wmhi_at(n);
        wm_lo = wmlo_at(n);
    end
endtask

integer i;
reg     bad;

initial begin
    ips_fnv_reset();
    rst_n  = 1'b0;
    clk_en = 1'b0;
    wr_req = 1'b0;
    rd_req = 1'b0;
    wdata  = 12'd0;
    wm_hi  = 8'd12;
    wm_lo  = 8'd1;
    state  = SEED;
    bad    = 1'b0;

    repeat (3) @(negedge ips_clk);
    rst_n = 1'b1;
    repeat (2) @(negedge ips_clk);

    clk_en = 1'b1;
    drive_beat(0);

    for (i = 0; i < BEATS; i = i + 1) begin
        @(negedge ips_clk);

        if (^{level, rdata, ov_count, uf_count} === 1'bx)          bad = 1'b1;
        if (full === 1'bx || empty === 1'bx || flag_hi === 1'bx ||
            flag_lo === 1'bx || ov_flag === 1'bx || uf_flag === 1'bx) bad = 1'b1;
        if (full === 1'b1 && empty === 1'b1)                       bad = 1'b1;
        if (empty === 1'b1 && level !== 8'h00)                     bad = 1'b1;
        if (empty === 1'b0 && level === 8'h00)                     bad = 1'b1;
        if (ov_flag === 1'b0 && ov_count !== 4'h0)                 bad = 1'b1;
        if (uf_flag === 1'b0 && uf_count !== 4'h0)                 bad = 1'b1;

        ips_fnv_word({24'd0, level});
        ips_fnv_word({20'd0, rdata});
        ips_fnv_word({26'd0, full, empty, flag_hi, flag_lo, ov_flag, uf_flag});
        ips_fnv_word({24'd0, ov_count, uf_count});

        drive_beat(i + 1);
    end

    clk_en = 1'b0;
    wr_req = 1'b0;
    rd_req = 1'b0;

    repeat (3) @(negedge ips_clk);
    ips_fnv_word(BEATS);

    ips_verdict(!bad, "ips_fifo_sync_fwft");
end

endmodule
