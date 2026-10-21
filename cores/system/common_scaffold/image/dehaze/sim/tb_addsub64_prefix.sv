`timescale 1ns/1ps
module tb_addsub64_prefix;
reg [63:0] a,b;
reg sub;
wire [63:0] result;
reg [63:0] seed=64'h917baec431234567,x,y;
integer cases=0,i,j;
img_dh_addsub64_prefix dut(.a(a),.b(b),.sub(sub),.result(result));
function [63:0] rng(input [63:0] r);
reg [63:0] v;begin v=r^(r<<13);v=v^(v>>7);rng=v^(v<<17);end endfunction
task check(input [63:0] av,bv,input sv);
reg [63:0] expected;begin
 a=av;b=bv;sub=sv;expected=sv ? av-bv : av+bv;#1;
 if(result!==expected)$fatal(1,"prefix mismatch a=%h b=%h sub=%b got=%h expected=%h",a,b,sub,result,expected);
 cases=cases+1;
end endtask
initial begin
 for(j=0;j<2;j=j+1)begin
  check(0,0,j);check(-64'd1,0,j);check(0,-64'd1,j);check(-64'd1,-64'd1,j);
  for(i=0;i<64;i=i+1)begin
   x=(64'd1<<i)-1;y=(64'd1<<i);
   check(x,1,j);check(1,x,j);check(y,1,j);check(1,y,j);check(~x,x,j);check(~y,y,j);
  end
  for(i=0;i<65536;i=i+1)check({16'hffff,16'h0000,i[15:0],16'hffff},{16'h0000,16'hffff,~i[15:0],16'h0001},j);
 end
 for(i=0;i<8192;i=i+1)begin seed=rng(seed);x=seed;seed=rng(seed);y=seed;check(x,y,0);check(x,y,1);end
 $display("PREFIX64_TEST PASS cases=%0d exhaustive_low16=131072 random=16384 carry_boundaries=768",cases);$finish;
end
endmodule
