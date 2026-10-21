`timescale 1ns/1ps
module tb_isp_config_registers;
 reg clk=0,rst=0,qv=0,qw=0,rr=0,ready=0;always #5 clk=~clk;
 reg [7:0] addr=0;reg [31:0] data=0;reg [3:0] strobe=15;
 wire qr,rv,re,cv,pending;wire [31:0] rd,version;wire [511:0] words;
 isp_config_registers dut(clk,rst,qv,qw,addr,data,strobe,qr,rv,re,rd,rr,cv,ready,words,version,pending);
 reg [31:0] expected[0:15];reg [511:0] snapshot;integer applied=0;
 always @(posedge clk)if(rst&&cv&&ready)applied=applied+1;
 task transaction(input bit write,input integer address,input [31:0] value,input [3:0] bytes,input bit err,input [31:0] readback);
 reg [32:0] saved;
 begin
  @(negedge clk);qv=1;qw=write;addr=address;data=value;strobe=bytes;
  do @(posedge clk);while(!qr);@(negedge clk);qv=0;
  wait(rv);saved={re,rd};
  repeat(7)begin @(negedge clk);if(!rv||{re,rd}!==saved)$fatal(1,"CSR response unstable");end
  if(re!=err||(!write&&!err&&rd!==readback))$fatal(1,"CSR mismatch addr=%h error=%b expected=%b value=%h expected=%h",address,re,err,rd,readback);
  rr=1;@(negedge clk);rr=0;
 end endtask
 initial begin
  repeat(4)@(negedge clk);rst=1;
  transaction(0,8,0,0,0,32'h49535031);
  transaction(1,4,1,15,1,0); // zero dimensions/period rejected
  transaction(1,32,1,1,1,0);transaction(1,33,1,15,1,0);
  transaction(1,128,1,15,1,0);transaction(0,12,0,0,1,0);
  for(integer i=0;i<16;i=i+1)expected[i]=0;
  expected[0]={16'd7,16'd7};expected[1]=3;expected[2]=1666667;expected[3]=71;expected[4]=4;
  expected[8]={16'd256,16'd256};expected[9]=256;
  expected[10]=1024;expected[12]=1024;expected[14]=1024;
  for(integer i=0;i<16;i=i+1)begin
   transaction(1,32+i*4,expected[i],15,0,0);
   transaction(0,32+i*4,0,0,0,expected[i]);
   snapshot[i*32+:32]=expected[i];
  end
  transaction(1,4,1,15,0,0);
  if(!pending||cv||version!=0||words!=0)$fatal(1,"configuration applied while unsafe");
  transaction(1,32,123,15,1,0);transaction(1,4,1,15,1,0);
  @(negedge clk);ready=1;@(negedge clk);ready=0;
  wait(cv);repeat(20)begin @(negedge clk);if(!cv||words!==snapshot||version!=1)$fatal(1,"active config not atomic/held");end
  transaction(1,36,9,15,1,0);
  for(integer i=0;i<16;i=i+1)transaction(0,128+i*4,0,0,0,expected[i]);
  @(negedge clk);ready=1;@(negedge clk);ready=0;
  if(pending||cv||applied!=1)$fatal(1,"config handshake accounting");
  transaction(1,44,99,15,0,0); // next seed, active must remain unchanged
  if(words!==snapshot)$fatal(1,"shadow write changed active");
  ready=1;transaction(1,4,1,15,0,0);
  if(version!=2||applied!=2||words[127:96]!=99||pending)$fatal(1,"immediate commit duplicated or lost");
  // Semantic limits reject a whole transaction without changing active.
  transaction(1,48,256,15,0,0);transaction(1,4,1,15,1,0);
  if(version!=2)$fatal(1,"invalid flags applied");
  $display("PASS ISP CSR atomic configuration, held responses, deferred/immediate apply and invalid accesses");$finish;
 end
 initial begin #200000;$fatal(1,"timeout");end
endmodule
