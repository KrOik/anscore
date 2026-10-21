`timescale 1ns/1ps
module tb_fifo_dbg2;
reg clk = 1'b0, rst_n = 1'b0, rdclk = 1'b0;
always #5 clk = ~clk;
always @(posedge clk) rdclk <= ~rdclk;
wire full, empty;
wire [7:0] dout;
fifo_async #(.DW(8),.AW(4)) f (
    .wr_clk(clk),.wr_rst_n(rst_n),.wr_en(1'b1),.din(8'hAA),.full(full),
    .rd_clk(rdclk),.rd_rst_n(rst_n),.rd_en(1'b0),.dout(dout),.empty(empty));
always @(posedge clk) $display("%0t rst=%b wptr=%0d gray=%b rptr_w2=%b full=%b",
   $time, rst_n, f.wptr_bin, f.wptr_gray, f.rptr_gray_w2, full);
initial begin
    repeat(3) @(posedge clk); rst_n <= 1;
    repeat(30) @(posedge clk); $finish;
end
endmodule
