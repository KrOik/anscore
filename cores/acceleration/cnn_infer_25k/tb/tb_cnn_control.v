`timescale 1ns/1ps
module tb_cnn_control;
 reg clk=0,rst=0,qv=0,qw=0,rr=0;
 reg [7:0] address=0;reg [31:0] data=0;reg [3:0] strobe=15;
 wire qr,rv,re;wire [31:0] rd;wire [7:0] probe;
 cnn_control #(.BUILD_ID(64'h2505abcd12345678)) dut(clk,rst,qv,qw,address,data,strobe,qr,rv,re,rd,rr,probe);
 always #5 clk=~clk;
 reg [7:0] w1[0:35],w2[0:287],wf[0:3919],pixels[0:783];
 reg [31:0] b1[0:3],b2[0:7],bf[0:9],read_value;
 reg [2047:0] directory,path;integer fd,i,n,tries;reg finished;
 task csr(input bit write,input integer a,input [31:0] v,input bit err);
 reg [32:0] held;
 begin
  @(negedge clk);qv=1;qw=write;address=a;data=v;
  do @(posedge clk);while(!qr);
  @(negedge clk);qv=0;data=32'h76543210;
  wait(rv);held={re,rd};
  repeat(3)begin @(negedge clk);if(!rv||{re,rd}!==held)$fatal(1,"CNN CSR response changed");end
  if(re!==err)$fatal(1,"CNN CSR address%h error%0d expected%0d",a,re,err);
  read_value=rd;rr=1;@(negedge clk);rr=0;
 end endtask
 initial begin
  if(!$value$plusargs("memdir=%s",directory)||!$value$plusargs("output=%s",path))$fatal(1,"missing path");
  fd=$fopen(path,"w");
  $readmemh({directory,"/conv1.mem"},w1);$readmemh({directory,"/conv2.mem"},w2);$readmemh({directory,"/dense.mem"},wf);
  $readmemh({directory,"/bias1.mem"},b1);$readmemh({directory,"/bias2.mem"},b2);$readmemh({directory,"/bias3.mem"},bf);
  repeat(4)@(negedge clk);rst=1;
  csr(0,0,0,0);if(read_value!=32'h434e4e31)$fatal(1,"CNN identifier");
  csr(0,48,0,0);if(read_value!=32'h12345678)$fatal(1,"build low");
  csr(0,52,0,0);if(read_value!=32'h2505abcd)$fatal(1,"build high");
  csr(0,40,0,1);csr(1,0,0,1);csr(0,1,0,1);
  strobe=3;csr(1,8,1,1);strobe=15;
  csr(1,8,3,1);csr(1,12,5,0);csr(1,16,0,1);
  csr(0,12,0,0);if(read_value!=5)$fatal(1,"failed load advanced cursor");
  csr(1,8,1,0);
  for(i=0;i<36;i=i+1)csr(1,16,w1[i],0);
  for(i=0;i<288;i=i+1)csr(1,16,w2[i],0);
  for(i=0;i<3920;i=i+1)csr(1,16,wf[i],0);
  csr(1,8,2,0);
  for(i=0;i<4;i=i+1)csr(1,16,b1[i],0);
  for(i=0;i<8;i=i+1)csr(1,16,b2[i],0);
  for(i=0;i<10;i=i+1)csr(1,16,bf[i],0);
  for(n=0;n<3;n=n+1)begin
   case(n)
    0:$readmemh({directory,"/ramp_input.mem"},pixels);
    1:$readmemh({directory,"/checker_input.mem"},pixels);
    2:$readmemh({directory,"/impulse_input.mem"},pixels);
   endcase
   csr(1,8,0,0);for(i=0;i<784;i=i+1)csr(1,16,pixels[i],0);
   csr(1,20,1,0);
   csr(1,16,0,1);csr(1,8,0,1);csr(1,20,1,1);csr(0,40,0,1);
   finished=0;
   for(tries=0;tries<400&&!finished;tries=tries+1)begin
    repeat(1000)@(negedge clk);csr(0,4,0,0);finished=read_value[2];
   end
   if(!finished||read_value[7:4]!=0)$fatal(1,"CNN CSR did not finish cleanly");
   csr(0,28,0,0);if(read_value!=10597)$fatal(1,"trace count");
   csr(0,24,0,0);$display("CSR_CNN_CYCLES run=%0d value=%0d",n,read_value);
   csr(1,36,10597,1);csr(1,36,0,0);
   for(i=0;i<10597;i=i+1)begin csr(0,40,0,0);$fwrite(fd,"%0d %0d %0d\n",n,i,$signed(read_value));end
   csr(0,36,0,0);if(read_value!=10596)$fatal(1,"read cursor bounds");
   csr(1,20,2,0);csr(0,40,0,1);
  end
  $fclose(fd);$display("PASS CNN CSR3inputs,complete layer RAM readback,held responses,guards,buildID");$finish;
 end
 initial begin #30000000;$fatal(1,"CNN CSR timeout");end
endmodule
