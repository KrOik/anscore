`timescale 1ns/1ps
module tb_parallel_osd_crc;
reg clk=0;always #5 clk=~clk;
reg rst_n=0;
reg [192:0] vectors[0:767];reg [2047:0] filename;
wire [2:0] finished;
genvar g;
generate for(g=0;g<3;g=g+1)begin: lanes
 integer sent=0,received=0,results=0;
 reg sv=0,mr=0,accepted=0;reg [192:0] v=0;
 reg [31:0] rng=32'h33445566+g*999;
 wire sr,mv,sof,eol,last;wire [23:0] pixel;wire [15:0] user;
 wire [31:0] frame;wire [7:0] error;
 wire rv;wire [31:0] rf,rc,rp;wire [7:0] re;
 assign finished[g]=(received==256&&results==8);
 dual_osd_stream dut(clk,rst_n,sv,sr,v[23:0],v[47:24],v[71:48],v[95:72],v[119:96],
 v[128:120],v[137:129],v[139:138],v[141:140],v[142],v[143],v[144],v[160:145],v[192:161],8'd0,
 mv,mr,pixel,sof,eol,last,user,frame,error);
 video_frame_crc monitor(clk,rst_n,mv,mr,sof,last,pixel,frame,32'd32,error,rv,rf,rc,rp,re);
 always @(negedge clk)if(rst_n)begin
  rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
  mr=(rng[4:2]!=0);
  if(!sv||accepted)begin sv=sent<256&&rng[1:0]!=0;if(sent<256)v=vectors[g*256+sent];end
 end
 always @(posedge clk)if(rst_n)begin
  accepted=sv&&sr;
  if(sv&&sr)sent=sent+1;
  if(mv&&mr)begin
   $display("PIX %0d %0d %0d %0d %0d %0d %0d %0d %0d",g,received,pixel,sof,eol,last,user,frame,error);
   received=received+1;
  end
  if(rv)begin $display("CRC %0d %0d %0d %0d %0d",g,rf,rc,rp,re);results=results+1;end
 end
end endgenerate
initial begin
 if(!$value$plusargs("fixture=%s",filename))$fatal(1,"fixture");
 $readmemh(filename,vectors);repeat(3)@(negedge clk);rst_n=1;
 wait(&finished);@(negedge clk);$display("PASS parallel OSD CRC");$finish;
end
initial begin #200000;$fatal(1,"timeout");end
endmodule
