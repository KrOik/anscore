`timescale 1ns/1ps
// Requires the isolated selectable-ROM candidate; validates nonlinear tables.
module tb_activation_lut_custom #(parameter IW=6,OW=8);
reg clk=0,in_valid=0;
reg [IW-1:0] val_in=0;
always #5 clk=~clk;
wire va,vl;
wire [OW-1:0] qa,ql;
`ifdef MAPPED_NETLIST
activation_lut mapped(.clk(clk),.in_valid(in_valid),.val_in(val_in),.out_valid(va),.confidence_out(qa));
assign vl=va;
assign ql=qa;
`else
activation_lut #(.INPUT_WIDTH(IW),.OUTPUT_WIDTH(OW),.LUT_FILE("custom.mem"),.ROM_STYLE("auto")) a(
 .clk(clk),.in_valid(in_valid),.val_in(val_in),.out_valid(va),.confidence_out(qa));
activation_lut #(.INPUT_WIDTH(IW),.OUTPUT_WIDTH(OW),.LUT_FILE("custom.mem"),.ROM_STYLE("logic")) l(
 .clk(clk),.in_valid(in_valid),.val_in(val_in),.out_valid(vl),.confidence_out(ql));
`endif
reg [OW-1:0] expected;
integer address,pass_index,checked=0;
task sample;
 input valid;
 input integer addr;
 begin
  @(negedge clk);in_valid=valid;val_in=addr;
  if(valid) expected=((addr*addr*13)^(addr<<3)^(addr>>2)^32'h539a);
  @(posedge clk);#1;
  if(va!==valid || vl!==valid || qa!==expected || ql!==expected)
   $fatal(1,"custom LUT address=%0d valid=%b auto=%h logic=%h expected=%h",addr,valid,qa,ql,expected);
  checked=checked+1;
 end
endtask
initial begin
 for(pass_index=0;pass_index<2;pass_index=pass_index+1)
  for(address=0;address<(1<<IW);address=address+1) begin
   sample(1,pass_index ? (1<<IW)-1-address : address);
   if(address%3==0) sample(0,address);
  end
`ifdef MAPPED_NETLIST
 $display("PASS mapped custom activation IW=%0d OW=%0d cycles=%0d",IW,OW,checked);
`else
 $display("PASS custom activation auto/logic IW=%0d OW=%0d cycles=%0d",IW,OW,checked);
`endif
 $finish;
end
initial begin #100000;$fatal(1,"timeout");end
endmodule
