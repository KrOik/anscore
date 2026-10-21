`timescale 1ns/1ps
// tb_st_ila_core -- runs st_ila_core to completion.
module tb_st_ila_core;
reg clk = 0, rst_n = 0, clk_en = 1, start = 0;
always #5 clk = ~clk;

wire done, pass;
wire [31:0] digest;
wire [15:0] cycles;

st_ila_core dut (
    .clk(clk), .clk_en(clk_en), .rst_n(rst_n), .start(start),
    .done(done), .pass(pass), .digest(digest), .cycles(cycles)
);

integer t;
initial begin
    repeat (8) @(posedge clk); rst_n <= 1;
    repeat (4) @(posedge clk);
    start <= 1; @(posedge clk); start <= 0;
    t = 0;
    while (!done && t < 200000) begin @(posedge clk); t = t + 1; end
    if (!done) begin
        $display("W2TB ILA FAIL timeout");
    end else if (done === 1'b1 && pass === 1'b1 && (^digest !== 1'bx)) begin
        $display("W2TB ILA PASS D=%08X C=%d", digest, cycles);
    end else begin
        $display("W2TB ILA FAIL D=%08X pass=%b", digest, pass);
    end
    $finish;
end
endmodule
