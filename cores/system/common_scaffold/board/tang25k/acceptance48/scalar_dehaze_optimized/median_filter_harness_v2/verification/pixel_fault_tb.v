`timescale 1ns/1ps
module acceptance48_tb;
reg clk=0;always #10 clk=~clk;wire tx,dbg;
acceptance48_top #(.UART_DIV(8),.TIMEOUT_CYCLES(200000)) uut(.clk(clk),.uart_rx_pin(1'b1),.uart_tx(tx),.dbg_uart(dbg));
reg [7:0] value;integer i,j;reg [4095:0] golden;integer fd;reg [7:0] expected[0:44];
initial begin
 if(!$value$plusargs("golden=%s",golden))$fatal(1,"golden required");fd=$fopen(golden,"rb");for(j=0;j<45;j=j+1)expected[j]=$fgetc(fd);$fclose(fd);

 for(j=0;j<45;j=j+1)begin
  @(negedge tx);repeat(12)@(posedge clk);
  for(i=0;i<8;i=i+1)begin value[i]=tx;repeat(8)@(posedge clk);end
  if(tx!==1)$fatal(1,"UART stop bit");
  if(value!==expected[j])$fatal(1,"UART byte %0d actual=%h expected=%h",j,value,expected[j]);
 end
 repeat(100)@(posedge clk);if(!uut.finished)$fatal(1,"completion");
 $display("ACCEPTANCE48 UART GOLDEN PASS");$finish;
end
initial begin #300000000;$fatal(1,"simulation watchdog");end
endmodule
