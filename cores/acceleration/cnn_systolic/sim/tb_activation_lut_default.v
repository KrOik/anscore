`timescale 1ns/1ps
// Oracle for the shipped default table: unsigned saturation, not sigmoid.
module tb_activation_lut_default #(parameter POSITIVE=1);
reg clk=0,in_valid=0;
reg [12:0] val_in=0;
wire out_valid;
wire [7:0] confidence_out;
always #5 clk=~clk;
`ifdef MAPPED_NETLIST
activation_lut dut(.*);
`else
activation_lut #(.CONV_POSITIVE(POSITIVE)) dut(.*);
`endif
reg [7:0] expected;
integer address,checked=0;
task sample;
 input valid;
 input [12:0] addr;
 begin
  @(negedge clk);in_valid=valid;val_in=addr;
  if(valid) expected=addr>255 ? 255 : addr;
  @(posedge clk);#1;
  if(out_valid!==valid || confidence_out!==expected)
   $fatal(1,"lookup mismatch addr=%0d valid=%b got=%h expected=%h",addr,valid,confidence_out,expected);
  checked=checked+1;
 end
endtask
initial begin
 for(address=0;address<8192;address=address+1) begin
  sample(1,address);
  if(address%17==0) sample(0,8191-address);
 end
 $display("PASS default activation LUT POSITIVE=%0d addresses=8192 cycles=%0d",POSITIVE,checked);
 $finish;
end
initial begin #200000;$fatal(1,"timeout");end
endmodule
