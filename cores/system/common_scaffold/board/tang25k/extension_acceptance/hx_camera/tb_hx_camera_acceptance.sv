
`timescale 1ns/1ps
module tb;
reg clk=0;always #10 clk=~clk;
wire uart_tx,dbg_uart;hx_camera_acceptance dut(.clk(clk),.uart_rx_pin(1'b1),.uart_tx(uart_tx),.dbg_uart(dbg_uart));
reg[191:0]got=0;reg[7:0]v;integer i,j;
initial begin
 for(i=0;i<24;i=i+1)begin
 @(negedge uart_tx);repeat(651)@(posedge clk);
 for(j=0;j<8;j=j+1)begin v[j]=uart_tx;repeat(434)@(posedge clk);end
 if(!uart_tx)$fatal(1,"UART stop");got={got[183:0],v};
 end
 if(got!=="PASS HX_CAMERA N=3 C=2\r\n")$fatal(1,"UART mismatch %s stage%0d hxidx%0d peerpos%0d peererr%0d hxerr%0d cameraerror%0d",got,dut.stage,dut.hx_index,dut.cp.pos,dut.peer_error,dut.hx_error,dut.camera_code);
 if(!dut.peer_complete||!dut.hx_complete||dut.failed)$fatal(1,"terminal checks");
 $display("PASS UART_DECODE HX_CAMERA words3 camera2 bytes24");$finish;
end
initial begin #200000000;$fatal(1,"watchdog stage%0d",dut.stage);end
endmodule
