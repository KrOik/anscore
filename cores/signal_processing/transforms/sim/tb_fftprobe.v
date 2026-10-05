`timescale 1ns/1ps
module tb_fftprobe;
reg clk = 0; always #18.5 clk = ~clk;
wire tx;
fft_probe_top dut(.clk(clk), .uart_tx(), .dbg_uart(tx));
// decode uart bytes
reg [7:0] sh; integer bc;
integer nb = 0;
reg [7:0] bytes [0:4095];
always @(negedge tx) begin : rx
    integer k;
    begin
        #(18518*5/10);                 // mid start bit
        for (k = 0; k < 10; k = k + 1) begin
            sh[k] = tx;
            #18518;
        end
        if (nb < 4096) begin bytes[nb] = {sh[8],sh[7],sh[6],sh[5],sh[4],sh[3],sh[2],sh[1]}; nb = nb + 1; end
    end
end
initial begin
    #600000000;                        // 600us sim
    $display("bytes received: %0d", nb);
    $finish;
end
endmodule
