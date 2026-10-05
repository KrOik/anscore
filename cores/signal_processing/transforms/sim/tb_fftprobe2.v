`timescale 1ns/1ps
module tb_fftprobe;
reg clk = 0; always #18.5 clk = ~clk;
wire tx;
integer fd;
fft_probe_top dut(.clk(clk), .uart_tx(), .dbg_uart(tx));
integer nb = 0;
reg [7:0] b;
always @(negedge tx) begin
    #(18518/2);
    b = 0;
    begin : bits
        integer k;
        for (k=0;k<10;k=k+1) begin b[k]=tx; #18518; end
        $fwrite(fd, "%02x\n", {b[8],b[7],b[6],b[5],b[4],b[3],b[2],b[1]});
        nb = nb + 1;
    end
end
initial begin
    fd = $fopen("sim/fftprobe_sim_bytes.txt","w");
    #1200000000;
    $fclose(fd);
    $display("bytes=%0d", nb);
    $finish;
end
endmodule
