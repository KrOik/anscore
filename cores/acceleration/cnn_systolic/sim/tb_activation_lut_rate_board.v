`timescale 1ns/1ps
module tb_activation_lut_rate_board #(parameter STYLE="logic", BAUD=2700000, BLOCKS=33);
reg clk=0;always #5 clk=~clk;
wire uart_tx,dbg_uart;
activation_lut_rate_board #(.ROM_STYLE(STYLE),.UART_BAUD(BAUD)) dut(.*);
localparam CYCLE=27000000/BAUD;
integer block_number,index,bit_number,address;
reg [7:0] got,expected;
initial begin
 wait(dut.rst_n);
 for(block_number=0;block_number<BLOCKS;block_number=block_number+1)
  for(index=0;index<262;index=index+1) begin
   @(negedge dbg_uart);repeat(CYCLE+CYCLE/2) @(posedge clk);
   for(bit_number=0;bit_number<8;bit_number=bit_number+1) begin
    got[bit_number]=dbg_uart;repeat(CYCLE) @(posedge clk);
   end
   case(index)
    0:expected="A";1:expected="L";2:expected="T";3:expected="1";
    4:expected=block_number%32;5:expected=0;
    default:begin address=(block_number%32)*256+index-6;expected=address>255 ? 255 : address;end
   endcase
   if(dbg_uart!==1 || got!==expected)
    $fatal(1,"ALT1 block=%0d byte=%0d got=%h expected=%h",block_number,index,got,expected);
  end
 $display("PASS ALT1 STYLE=%s BAUD=%0d blocks=%0d raw_bytes=%0d",STYLE,BAUD,BLOCKS,BLOCKS*256);
 $finish;
end
initial begin #30000000;$fatal(1,"timeout");end
endmodule
