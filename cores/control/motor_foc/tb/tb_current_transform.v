`timescale 1ns/1ps
module tb_current_transform;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,sv=0,mr=0,accepted=0;wire sr,mv,sf,af;
reg [70:0] vectors[0:1023];reg [70:0] v=0;reg [2047:0] filename;
wire signed [11:0] d,q,a,b;wire [11:0] residual;wire [3:0] flags;wire [31:0] id;
integer sent=0,received=0;reg [31:0] rng=32'h12342509;
current_transform dut(clk,rst_n,sv,sr,v[9:0],v[19:10],v[29:20],v[37:30],v[45:38],v[46],{8'd0,v[70:47]},mv,mr,d,q,a,b,residual,flags,sf,af,id);
always @(negedge clk)if(rst_n)begin
 rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};mr=received<128||rng[2:0]!=0;
 if(!sv||accepted)begin sv=sent<1024&&(sent<128||rng[5:3]!=0);if(sent<1024)v=vectors[sent];end
end
reg stalled=0;reg [97:0] held;integer last_cycle=0,cycle=0;
always @(posedge clk)if(rst_n)begin
 cycle=cycle+1;accepted=sv&&sr;if(accepted)sent=sent+1;
 if(stalled&&(!mv||{d,q,a,b,residual,flags,sf,af,id}!==held))$fatal(1,"transform stall");
 stalled=mv&&!mr;held={d,q,a,b,residual,flags,sf,af,id};
 if(mv&&mr)begin
  if(received>0&&received<128&&cycle!=last_cycle+1)$fatal(1,"transform II not1");last_cycle=cycle;
  $display("TRANSFORM %0d %0d %0d %0d %0d %0d %0d %0d %0d",id,d,q,a,b,residual,flags,sf,af);
  received=received+1;
 end
end
initial begin
 if(!$value$plusargs("fixture=%s",filename))$fatal(1,"fixture");$readmemh(filename,vectors);
 repeat(3)@(negedge clk);rst_n=1;wait(received==1024);@(negedge clk);
 $display("PASS current transform");$finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
