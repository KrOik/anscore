`timescale 1ns/1ps
module tb_lockin4;
 parameter SIN_FILE="",COS_FILE="";
 reg clk=0,rst=0,cv=0,sv=0,mr=0;
 reg [31:0] tuning=0,period=1000,id=0;reg [3:0] log2=8;
 reg [63:0] offsets=0,gains={4{16'd32768}},samples=0;reg [255:0] timestamps=0;
 wire cr,sr,mv;wire [63:0] oi,oq,amplitude,first,last;wire [71:0] phase;
 wire [31:0] out_id;wire [4:0] error;
 lockin4 #(.SIN_FILE(SIN_FILE),.COS_FILE(COS_FILE)) dut(clk,rst,cv,cr,tuning,period,id,log2,offsets,gains,
  sv,sr,samples,timestamps,mv,mr,oi,oq,amplitude,phase,first,last,out_id,error);
 always #5 clk=~clk;
 reg [63:0] vectors[0:255];reg [2047:0] directory;integer c,n,k;
 reg [31:0] rng=32'h0606abcd;
 task command(input integer case_id,input integer bin);
 begin
  @(negedge clk);id=case_id;tuning=bin<<24;cv=1;
  do @(posedge clk);while(!cr);
  @(negedge clk);cv=0;tuning=32'hffffffff;id=999;
 end endtask
 task sample(input [63:0] value,input [63:0] timestamp,input bit desync,input bit cadence);
 begin
  @(negedge clk);sv=1;samples=value;
  for(k=0;k<4;k=k+1)timestamps[k*64+:64]=timestamp;
  if(desync)timestamps[64+:64]=timestamp+1;
  if(cadence)for(k=0;k<4;k=k+1)timestamps[k*64+:64]=timestamp+1;
  do @(posedge clk);while(!sr);
  @(negedge clk);sv=0;samples=0;timestamps=0;
 end endtask
 task response(input integer case_id,input [4:0] expected_error);
 reg [428:0] saved;
 begin
  wait(mv);saved={oi,oq,amplitude,phase,first,last,out_id,error};
  if(error!==expected_error||out_id!=case_id)$fatal(1,"lockin errors/id %d/%d",error,out_id);
  repeat(11)begin @(negedge clk);if(!mv||{oi,oq,amplitude,phase,first,last,out_id,error}!==saved||sr||cr)$fatal(1,"lockin held result");end
  for(integer lane=0;lane<4;lane=lane+1)
   $display("LOCKIN case=%0d lane=%0d i=%0d q=%0d amplitude=%0d phase=%0d first=%0d last=%0d error=%0d",
    case_id,lane,$signed(oi[lane*16+:16]),$signed(oq[lane*16+:16]),amplitude[lane*16+:16],$signed(phase[lane*18+:18]),first,last,error);
  mr=1;@(negedge clk);mr=0;
 end endtask
 initial begin
  if(!$value$plusargs("memdir=%s",directory))$fatal(1,"memory directory");
  repeat(4)@(negedge clk);rst=1;
  for(c=0;c<3;c=c+1)begin
   case(c)
    0:$readmemh({directory,"/samples0.mem"},vectors);
    1:$readmemh({directory,"/samples1.mem"},vectors);
    2:$readmemh({directory,"/samples2.mem"},vectors);
   endcase
   command(c,c==0?1:c==1?3:7);
   for(n=0;n<256;n=n+1)begin
    rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};repeat(rng[1:0])@(negedge clk);
    sample(vectors[n],64'd100000+c*1000000+n*1000,0,0);
   end
   response(c,0);
  end
  // Explicit channel/cadence alarms,then zero-signal clean recovery.
  command(3,1);
  for(n=0;n<256;n=n+1)sample(0,64'd4000000+n*1000,n==10,n==20);
  response(3,3);
  command(4,1);for(n=0;n<256;n=n+1)sample(0,64'd5000000+n*1000,0,0);response(4,0);
  log2=0;command(5,1);response(5,16);
  log2=8;offsets={4{16'd1234}};command(6,1);
  // Applied calibration is latched with command,not read from changing pins.
  offsets=0;
  for(n=0;n<256;n=n+1)sample({4{16'd1234}},64'd6000000+n*1000,0,0);
  response(6,0);
  offsets={4{16'h8000}};gains={4{16'hffff}};command(7,1);
  offsets=0;gains={4{16'd32768}};
  for(n=0;n<256;n=n+1)sample({4{16'd32767}},64'd7000000+n*1000,0,0);
  response(7,4);
  command(8,1);sample(64'h123456789abcdef0,8000000,0,0);
  rst=0;@(negedge clk);rst=1;
  command(9,1);for(n=0;n<256;n=n+1)sample(0,64'd9000000+n*1000,0,0);response(9,0);
  $display("PASS lockin4 coherent tones,stall holds,timestamps,alarms,recovery,invalidconfig");$finish;
 end
 initial begin #1000000;$fatal(1,"lockin timeout");end
endmodule
