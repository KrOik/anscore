`timescale 1ns/1ps
module tb;
reg clk=0;always #10 clk=~clk;wire tx,done;
jpeg_uart_25k #(.CLK_HZ(50000000),.BAUD(115200),.BOOT_CYCLES(32))dut(.clk(clk),.uart_rx_pin(1'b1),.uart_tx(tx),.dbg_uart(done));
integer f,count=0;reg[7:0]b;
initial begin f=$fopen("uart.hex","w");forever begin
@(negedge tx);repeat(651)@(posedge clk);
for(integer i=0;i<8;i=i+1)begin b[i]=tx;repeat(434)@(posedge clk);end
if(tx!==1)$fatal(1,"bad UART stop");$fdisplay(f,"%02x",b);count=count+1;
end end
initial begin wait(done);repeat(1000)@(posedge clk);if(count!=999)$fatal(1,"count %d",count);$fclose(f);$display("ACTUAL50 JPEG UART PASS");$finish;end
initial begin #300000000;$fatal(1,"timeout");end
endmodule
