`timescale 1ns/1ps
module tb_int8_dot_stream;
 reg clk=0,rst=0,cv=0,sv=0,last=0,mr=0;
 reg [15:0] terms;reg signed [31:0] bias;
 reg signed [7:0] x,w;
 wire cr,sr,mv;wire signed [31:0] result;wire [1:0] error;
 int8_dot_stream dut(clk,rst,cv,cr,terms,bias,sv,sr,x,w,last,mv,mr,result,error);
 always #5 clk=~clk;
 integer test=0,accepted=0,cycle=0,first_cycle=0,last_cycle=0;
 reg [31:0] rng=32'h2505abcd;
 always @(posedge clk)begin
  cycle=cycle+1;
  if(rst&&sv&&sr)begin
   if(accepted==0)first_cycle=cycle;
   accepted=accepted+1;last_cycle=cycle;
  end
 end
 task random_step;
 begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};end endtask
 task command(input integer n,input signed [31:0] b);
 begin
  @(negedge clk);terms=n;bias=b;cv=1;
  do @(posedge clk);while(!cr);
  @(negedge clk);cv=0;terms=0;bias=32'h76543210;accepted=0;
 end endtask
 task sample(input signed [7:0] a,input signed [7:0] b,input bit tail);
 begin
  x=a;w=b;last=tail;sv=1;
  do @(posedge clk);while(!sr);
  @(negedge clk);sv=0;x=127;w=-128;last=0;
 end endtask
 task response(input signed [31:0] expected,input [1:0] err);
 reg [33:0] held;
 begin
  wait(mv);held={error,result};
  if(result!==expected||error!==err)$fatal(1,"dot result test=%0d got=%0d/%0d expected=%0d/%0d",test,result,error,expected,err);
  repeat(7)begin @(negedge clk);if(!mv||{error,result}!==held||cr||sr)$fatal(1,"held response changed");end
  $display("DOT_RESULT case=%0d value=%0d error=%0d",test,result,error);
  mr=1;@(negedge clk);mr=0;test=test+1;
 end endtask
 integer n,i,trial;reg signed [31:0] expected;reg signed [7:0] a,b;
 initial begin
  repeat(4)@(negedge clk);rst=1;
  for(trial=0;trial<40;trial=trial+1)begin
   n=trial==0?392:trial%17+1;expected=trial*197-2048;
   command(n,expected);
   for(i=0;i<n;i=i+1)begin
    random_step();a=rng[7:0];random_step();b=rng[15:8];
    if(trial==1)begin a=-128;b=-128;end
    if(trial>1&&rng[0])repeat(2)@(negedge clk);
    sample(a,b,i==n-1);expected=expected+a*b;
   end
   if(trial==0&&last_cycle-first_cycle!=391)$fatal(1,"dot II not1");
   response(expected,0);
  end
  command(0,0);response(0,1);
  command(393,0);response(0,1);
  command(3,0);sample(1,1,1);response(0,2);
  command(1,0);sample(1,1,0);response(0,2);
  command(1,32'h7fffffff);sample(127,127,1);response(0,3);
  command(2,32'h80000000);sample(-128,127,0);sample(0,0,1);response(0,3);
  command(4,111);sample(3,4,0);rst=0;@(negedge clk);sv=0;rst=1;
  command(1,-99);sample(-128,127,1);response(-16355,0);
  $display("PASS INT8 dot II1,47responses,gaps,bias,framing,overflow,reset/recovery");$finish;
 end
 initial begin #1000000;$fatal(1,"timeout");end
endmodule
