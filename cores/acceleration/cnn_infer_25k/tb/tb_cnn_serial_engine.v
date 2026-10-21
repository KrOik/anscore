`timescale 1ns/1ps
module tb_cnn_serial_engine;
 reg clk=0,rst=0,lv=0,start=0,tr=0,dr=0;
 reg [1:0] region=0;reg [15:0] address=0;reg [31:0] data=0;
 wire lr,le,sr,tv,dv;wire [2:0] stage;wire [15:0] index;
 wire signed [31:0] value;wire [3:0] error;wire [31:0] cycles;
 cnn_serial_engine dut(clk,rst,lv,lr,region,address,data,le,start,sr,tv,tr,stage,index,value,dv,dr,error,cycles);
 always #5 clk=~clk;
 reg [7:0] w1[0:35],w2[0:287],wf[0:3919],pixels[0:783];
 reg [31:0] b1[0:3],b2[0:7],bf[0:9];
 reg [2047:0] directory,path;integer fd,run=-1,i,n,taps=0;
 reg [31:0] rng=32'h25051234;reg held=0;reg [50:0] saved;
 always @(negedge clk)begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};tr=rng[0]||rng[3];end
 always @(posedge clk)if(rst)begin
  if($test$plusargs("trace")&&run==0&&dut.state==12&&dut.pool_position<2&&dut.layer==0)
   $display("POOL_TRACE p=%0d c=%0d sub=%0d addr=%0d q=%0d max=%0d",dut.pool_position,dut.channel,dut.subpixel,dut.read_fmap,dut.fmap_q,dut.pool_max);
  if(held&&(!tv||{stage,index,value}!==saved))$fatal(1,"CNN tap changed under backpressure");
  held<=tv&&!tr;saved<={stage,index,value};
  if(tv&&tr)begin taps=taps+1;$fwrite(fd,"%0d %0d %0d %0d\n",run,stage,index,value);end
 end else held<=0;
 task load(input [1:0] r,input integer a,input [31:0] v,input bit expected_error);
 begin
  @(negedge clk);lv=1;region=r;address=a;data=v;
  do @(posedge clk);while(!lr);
  @(negedge clk);lv=0;
  if(le!==expected_error)$fatal(1,"loader error r=%0d a=%0d",r,a);
 end endtask
 task launch;
 begin @(negedge clk);start=1;do @(posedge clk);while(!sr);@(negedge clk);start=0;end endtask
 task finish(input [3:0] expected);
 reg [35:0] saved_done;
 begin
  wait(dv);saved_done={error,cycles};
  if(error!==expected)$fatal(1,"CNN completion error %0d vs%0d",error,expected);
  repeat(5)begin @(negedge clk);if(!dv||{error,cycles}!==saved_done||lr||sr)$fatal(1,"done not held");end
  $display("CNN_DONE run=%0d cycles=%0d error=%0d taps=%0d",run,cycles,error,taps);
  dr=1;@(negedge clk);dr=0;
 end endtask
 initial begin
  if(!$value$plusargs("memdir=%s",directory)||!$value$plusargs("output=%s",path))$fatal(1,"missing path");
  fd=$fopen(path,"w");
  $readmemh({directory,"/conv1.mem"},w1);$readmemh({directory,"/conv2.mem"},w2);$readmemh({directory,"/dense.mem"},wf);
  $readmemh({directory,"/bias1.mem"},b1);$readmemh({directory,"/bias2.mem"},b2);$readmemh({directory,"/bias3.mem"},bf);
  repeat(4)@(negedge clk);rst=1;
  launch();finish(1);
  load(0,5,0,1);load(3,0,0,1);
  for(i=0;i<36;i=i+1)load(1,i,w1[i],0);
  for(i=0;i<288;i=i+1)load(1,36+i,w2[i],0);
  for(i=0;i<3920;i=i+1)load(1,324+i,wf[i],0);
  for(i=0;i<4;i=i+1)load(2,i,b1[i],0);
  for(i=0;i<8;i=i+1)load(2,4+i,b2[i],0);
  for(i=0;i<10;i=i+1)load(2,12+i,bf[i],0);
  for(n=0;n<3;n=n+1)begin
   run=n;taps=0;
   case(n)
    0:$readmemh({directory,"/ramp_input.mem"},pixels);
    1:$readmemh({directory,"/checker_input.mem"},pixels);
    2:$readmemh({directory,"/impulse_input.mem"},pixels);
   endcase
   for(i=0;i<784;i=i+1)load(0,i,pixels[i],0);
   launch();finish(0);
   if(taps!=10597)$fatal(1,"tap count %0d",taps);
  end
  // Pooling overwrites the input RAM; stale input must not be silently reused.
  run=3;launch();finish(1);
  // Deliberately overflow an early dot; completion must not deadlock.
  for(i=0;i<22;i=i+1)load(2,i,i==0?32'h7fffffff:0,0);
  for(i=0;i<784;i=i+1)load(0,i,127,0);
  run=4;launch();finish(7);
  $fclose(fd);$display("PASS complete CNN3inputs,alllayers,weightreuse,heldtaps,loader/error guards");$finish;
 end
 initial begin #20000000;$fatal(1,"CNN timeout");end
endmodule
