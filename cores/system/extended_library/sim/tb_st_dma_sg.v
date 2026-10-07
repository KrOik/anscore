`timescale 1ns/1ps
// tb_st_dma_sg -- runs st_dma_sg to completion; PASS requires done && pass
// and a defined (non-X) digest.  Byte stream dump written by the cell to
// sim/dump_dma_sg.txt is diffed against sim/golden_dma_sg.txt externally.
module tb_st_dma_sg;
reg clk = 0, rst_n = 0, clk_en = 1, start = 0;
always #5 clk = ~clk;

wire done, pass;
wire [31:0] digest;
wire [15:0] cycles;

st_dma_sg dut (
    .clk(clk), .clk_en(clk_en), .rst_n(rst_n), .start(start),
    .done(done), .pass(pass), .digest(digest), .cycles(cycles)
);

integer t;
initial begin
    repeat (8) @(posedge clk); rst_n <= 1;
    repeat (4) @(posedge clk);
    start <= 1; @(posedge clk); start <= 0;
    t = 0;
    while (!done && t < 100000) begin @(posedge clk); t = t + 1; end
    if (!done) begin
        $display("W2TB DMA FAIL timeout");
    end else if (done === 1'b1 && pass === 1'b1 && (^digest !== 1'bx)) begin
        $display("W2TB DMA PASS D=%08X C=%d", digest, cycles);
    end else begin
        $display("W2TB DMA FAIL D=%08X pass=%b", digest, pass);
    end
    $finish;
end
endmodule
