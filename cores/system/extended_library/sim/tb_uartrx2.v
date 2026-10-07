`timescale 1ns/1ps
module tb_uartrx2;
    reg clk = 0, rst_n = 0;
    reg [7:0] din = 0; reg dv = 0;
    wire tx, rdy, busy;
    always #18.5 clk = ~clk;
    uart_tx #(.CLK_FRE(27), .BAUD_RATE(115200)) u (
        .clk(clk), .rst_n(rst_n), .tx_data(din), .tx_data_valid(dv),
        .tx_data_ready(rdy), .tx_pin(tx), .tx_busy(busy));
    integer i;
    initial begin
        rst_n = 0; repeat(100) @(posedge clk); rst_n = 1; repeat(10) @(posedge clk);
        din = 8'hA5; dv = 1; @(posedge clk); dv = 0;
        // trace tx waveform: print value every 117 clks starting from negedge
        @(negedge tx);
        $display("start edge at %0t", $time);
        for (i = 0; i < 11; i = i + 1) begin
            repeat (234) @(posedge clk);
            $display("bit %0d sample=%b t=%0t", i, tx, $time);
        end
        $finish;
    end
endmodule
