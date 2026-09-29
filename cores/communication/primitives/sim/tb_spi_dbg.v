`timescale 1ns/1ps
module tb_spi_dbg;
reg clk = 1'b0, rst_n = 1'b0;
reg [3:0] ce_div = 0;
wire ce = (ce_div == 4'd15);
always #5 clk = ~clk;
always @(posedge clk) ce_div <= ce_div + 1;

reg start = 0;
reg [5:0] nbits = 6'd8;
reg [31:0] txw = 32'h000000A5;
wire [31:0] rxw;
wire busy, done, sclk, mosi, miso, csn;
wire [31:0] capdata; wire [5:0] capbits; wire capvalid;

spi_master #(.CPOL(0),.CPHA(0),.SCLK_DIV(4)) m (
    .clk(clk),.rst_n(rst_n),.clk_en(ce||!rst_n),
    .start(start),.nbits(nbits),.tx_data(txw),
    .rx_data(rxw),.busy(busy),.done(done),
    .sclk(sclk),.mosi(mosi),.miso(miso),.cs_n(csn));
spi_slave_model #(.SEED(8'hB7)) s (
    .clk(clk),.rst_n(rst_n),
    .sclk(sclk),.mosi(mosi),.miso(miso),.cs_n(csn),
    .cap_data(capdata),.cap_bits(capbits),.cap_valid(capvalid),.cap_ack(1'b0));

task do_xfer;
    input [5:0] nb;
    input [31:0] tx;
    begin
        nbits = nb; txw = tx;
        start <= 1; wait(busy); @(posedge clk); start <= 0;
        wait(done);
        $display("nbits=%0d rx=%08x cap=%08x capbits=%0d", nb, rxw, capdata, capbits);
    end
endtask

initial begin
    repeat(10) @(posedge clk); rst_n <= 1;
    repeat(100) @(posedge clk);
    do_xfer(6'd8,  32'h000000A5);
    do_xfer(6'd16, 32'h00003C5A);
    do_xfer(6'd32, 32'hC0FFEE11);
    repeat(100) @(posedge clk);
    $finish;
end
endmodule
