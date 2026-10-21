`timescale 1ns/1ps
module tb_max_pool2d_stream #(parameter LANES=9,WIDTH=7);
reg clk=0,clk_en=0,rst_n=0,new_line_1=0,input_valid=0;
always #5 clk=~clk;
reg [LANES*WIDTH-1:0] data=0;
wire [WIDTH-1:0] y_out;
wire new_line_out_1,output_valid;
max_pool2d #(.PE_ROW_NUM(LANES),.DATA_WIDTH(WIDTH)) dut(.*);
reg [31:0] rng=32'h8abc1234;
reg [WIDTH-1:0] maximum,s1=0,s2=0;
reg v1=0,v2=0,n1=0,n2=0;
integer t,k,checked=0;
task random_step;
 begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};end
endtask
initial begin
 for(t=0;t<2000;t=t+1) begin
  @(negedge clk);
  random_step;
  rst_n=(t!=0 && t!=731 && t!=1501);
  clk_en=(t<LANES+3 || rng[2:0]!=0);
  input_valid=(t<LANES+3 || rng[4:3]!=0);
  new_line_1=(t%19==1);
  for(k=0;k<LANES;k=k+1) begin random_step;data[k*WIDTH+:WIDTH]=rng;end
  if(t>=1 && t<=LANES) begin data=0;data[(t-1)*WIDTH+:WIDTH]={WIDTH{1'b1}};end
  if(t==LANES+1) data=0;
  if(t==LANES+2) data={LANES*WIDTH{1'b1}};
  maximum=0;
  for(k=0;k<LANES;k=k+1) if(data[k*WIDTH+:WIDTH]>maximum) maximum=data[k*WIDTH+:WIDTH];
  @(posedge clk);
  if(!rst_n) begin s1=0;s2=0;v1=0;v2=0;n1=0;n2=0;end
  else if(clk_en) begin s2=s1;s1=maximum;v2=v1;v1=input_valid;n2=n1;n1=new_line_1;end
  #1;
  if(y_out!==s2 || output_valid!==v2 || new_line_out_1!==n2)
   $fatal(1,"pool mismatch tick=%0d got=%h expected=%h valid=%b/%b line=%b/%b",t,y_out,s2,output_valid,v2,new_line_out_1,n2);
  checked=checked+1;
 end
 $display("PASS max pool LANES=%0d WIDTH=%0d cycles=%0d",LANES,WIDTH,checked);
 $finish;
end
initial begin #100000;$fatal(1,"timeout");end
endmodule
