`timescale 1ns/1ps
module tb_raster_osd;
reg clk=0;always #5 clk=~clk;
reg rst_n=0;reg [2:0] tick=0,start=0,stop=0,wv=0,cv=0;
reg [2:0] wi=0;reg [31:0] wd=0;
wire [2:0] ready,run,done,err,wr,cr,pending,ov;
integer cycle=0,n,k;
always @(negedge clk)cycle=cycle+1;
genvar g;
generate for(g=0;g<3;g=g+1)begin: lanes
 wire pv,de,hs,vs,sof,eol,last,rv;wire [23:0] rgb;wire [31:0] frame,ver,rf,rc,rp;
 wire [12:0] pixel_ver,crc_ver;wire [7:0] pe,re;
 wire [31:0] lane_wd=(wi==0)?wd+g*32'h10101:wd;
 raster_osd_output dut(.clk(clk),.rst_n(rst_n),.pixel_tick(tick[g]),.start_valid(start[g]),
 .stop(stop[g]),.abort(1'b0),.done_ready(1'b1),.start_ready(ready[g]),.running(run[g]),
 .done_valid(done[g]),.frame_error(err[g]),
 .h_active(16'd4+g),.h_front(16'd1),.h_sync(16'd1),.h_back(16'd2),
 .v_active(16'd3),.v_front(16'd1),.v_sync(16'd1),.v_back(16'd1),
 .h_positive(1'b1),.v_positive(1'b0),.write_valid(wv[g]),.write_ready(wr[g]),
 .write_index(wi),.write_data(lane_wd),.write_strb(4'hf),.commit_valid(cv[g]),
 .commit_ready(cr[g]),.pending(pending[g]),.config_version(ver),
 .pixel_valid(pv),.rgb(rgb),.out_de(de),.out_hsync(hs),.out_vsync(vs),
 .out_sof(sof),.out_eol(eol),.out_last(last),.out_frame(frame),.out_version(pixel_ver),
 .out_error(pe),.crc_valid(rv),.crc_frame(rf),.crc_value(rc),.crc_pixels(rp),.crc_error(re),.crc_version(crc_ver),.overflow(ov[g]));
 always @(posedge clk)if(rst_n)begin
  if(dut.source_valid)$display("IN %0d %0d",g,cycle);
  if(pv)$display("OUT %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d %0d",g,cycle,rgb,de,hs,vs,sof,eol,last,frame,pixel_ver,pe);
  if(rv)$display("CRC %0d %0d %0d %0d %0d %0d",g,rf,rc,rp,re,crc_ver);
 end
end endgenerate
initial begin
 repeat(3)@(negedge clk);rst_n=1;
 for(k=0;k<8;k=k+1)begin
  wi=k;wv=7;
  case(k)
   0:wd=32'h123456;1:wd=32'h654321;2:wd=32'habcdef;
   3:wd=32'h00400080;4:wd=32'h103;default:wd=0;
  endcase
  cv=k==7?7:0;@(negedge clk);
 end
 wv=0;cv=0;start=7;@(negedge clk);start=0;
 for(n=0;n<1400;n=n+1)begin
  tick[0]=1;tick[1]=n%2==0;tick[2]=n%3==0;
  wv=0;cv=0;
  if(n==100)begin wi=0;wd=32'hf0a050;wv=1;cv=1;end
  @(negedge clk);
 end
 stop=7;wv=0;cv=0;
 for(n=1400;n<1700;n=n+1)begin
  tick[0]=1;tick[1]=n%2==0;tick[2]=n%3==0;@(negedge clk);
 end
 if(run||ov||err||pending)$fatal(1,"scanout did not stop cleanly");
 $display("PASS raster OSD integration");$finish;
end
endmodule
