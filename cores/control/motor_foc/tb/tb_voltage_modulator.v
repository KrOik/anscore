`timescale 1ns/1ps
module tb_voltage_modulator;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,sv=0,mr=0,accepted=0;
reg [79:0] vectors[0:1023];reg [79:0] v=0;reg [2047:0] filename;
wire sr,mv;wire [15:0] u,wv,w,p;wire [1:0] error;wire [3:0] flags;wire [31:0] id;
voltage_modulator dut(clk,rst_n,sv,sr,v[11:0],v[23:12],v[31:24],v[47:32],v[79:48],mv,mr,u,wv,w,p,error,flags,id);
integer sent=0,received=0,cycle=0,previous=0;reg [31:0] rng=32'h2509abcd;
reg stalled=0;reg [101:0] held;
always @(negedge clk)if(rst_n)begin
 rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};mr=received<128||rng[2:0]!=0;
 if(!sv||accepted)begin sv=sent<1024&&(sent<128||rng[5:3]!=0);if(sent<1024)v=vectors[sent];end
end
always @(posedge clk)if(rst_n)begin
 cycle=cycle+1;accepted=sv&&sr;if(accepted)sent=sent+1;
 if(stalled&&(!mv||{u,wv,w,p,error,flags,id}!==held))$fatal(1,"modulator stall");
 stalled=mv&&!mr;held={u,wv,w,p,error,flags,id};
 if(mv&&mr)begin
  if(received>0&&received<128&&cycle!=previous+1)$fatal(1,"modulator II not1");previous=cycle;
  $display("DUTY %0d %0d %0d %0d %0d %0d %0d",id,u,wv,w,p,error,flags);received=received+1;
 end
end
initial begin
 if(!$value$plusargs("fixture=%s",filename))$fatal(1,"fixture");$readmemh(filename,vectors);
 repeat(3)@(negedge clk);rst_n=1;wait(received==1024);@(negedge clk);
 $display("PASS inverse Park SVPWM duties");$finish;
end
initial begin #1000000;$fatal(1,"timeout");end
endmodule
