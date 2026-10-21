`timescale 1ns/1ps
module tb_video_line_packet_codec;
 parameter THROUGH_FABRIC=0;
 reg clk=0,rst_n=0;always #5 clk=~clk;
 reg[15:0] width=1,height=1;reg[6:0] id=0;
 reg[23:0] data=0;reg sof=0,eol=0,valid=0;wire ready;
 wire[23:0] pd,od;wire[2:0] pk;wire[7:0] pu;wire pl,pv,pr,os,oe,ov,enc_error,dec_error;
 wire[6:0] oi;reg sink=0;
 video_line_packetizer enc(clk,rst_n,width,height,id,data,sof,eol,valid,ready,pd,pk,pu,pl,pv,pr,enc_error);
 wire[23:0] dd;wire[2:0] dk;wire[7:0] du;wire dl,dv,dr;
 wire[31:0] fabric_drops;
 generate if(THROUGH_FABRIC)begin: composed
  wire[31:0] wd;wire[3:0] wk;wire[7:0] wu;wire wl,wv;wire[3:0] wr;
  wire[31:0] frames;
  stream_width_adapter #(.IN_WIDTH(24),.OUT_WIDTH(32)) input_adapter(
   clk,rst_n,pd,pk,pu,pl,pv,pr,wd,wk,wu,wl,wv,wr[0]);
  stream_fabric4 #(.FIFO_DEPTH(1024)) fabric(clk,clk,rst_n,
   {96'd0,wd},{12'd0,wk},{24'd0,wu},{3'd0,wl},{3'd0,wv},wr,
   dd,dk,du,dl,dv,dr,frames,fabric_drops);
 end else begin: direct
  assign dd=pd;assign dk=pk;assign du=pu;assign dl=pl;assign dv=pv;assign pr=dr;
  assign fabric_drops=0;
 end endgenerate
 video_line_depacketizer dec(clk,rst_n,dd,dk,du,dl,dv,dr,od,oi,os,oe,ov,sink,dec_error);
 reg [2:0] fault_keep=7;reg [7:0] fault_user=0;reg fault_last=0,fault_valid=0;
 wire fault_ready,fault_error;
 video_line_depacketizer faulty_decoder(.clk(clk),.rst_n(rst_n),.s_data(24'd0),
 .s_keep(fault_keep),.s_user(fault_user),.s_last(fault_last),.s_valid(fault_valid),
 .s_ready(fault_ready),.m_ready(1'b1),.error(fault_error));
 reg[31:0] rng=32'h61fc9513;reg continuous=0;
 always @(negedge clk)begin rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};sink=continuous||rng[0]||rng[5];end
 reg[23:0] golden_data[0:400000];reg golden_sof[0:400000],golden_eol[0:400000];reg[6:0]golden_id[0:400000];
 integer sent=0,received=0,packets=0,stall_cycles=0,cycles=0;
 reg held=0,verify=1;reg[32:0] held_output;
 always @(posedge clk)if(!rst_n)held<=0;else begin
  cycles<=cycles+1;
  if(fabric_drops!=0)$fatal(1,"video fabric drop");
  if(held&&{od,oi,os,oe}!==held_output)$fatal(1,"video changed while stalled");
  held<=ov&&!sink;held_output<={od,oi,os,oe};
  if(ov&&!sink)stall_cycles<=stall_cycles+1;
  if(pv&&pr&&pl)packets<=packets+1;
  if(ov&&sink&&verify)begin
   if(received>=sent||od!==golden_data[received]||oi!==golden_id[received]||os!==golden_sof[received]||oe!==golden_eol[received])
    $fatal(1,"video output mismatch index=%d",received);
   received<=received+1;
  end
 end
 task pixel;
 input[23:0] value;input first_pixel,last_pixel;input[6:0] frame;
 begin
  @(negedge clk);data=value;sof=first_pixel;eol=last_pixel;valid=1;
  @(posedge clk);while(!ready)@(posedge clk);
  golden_data[sent]=value;golden_sof[sent]=first_pixel;golden_eol[sent]=last_pixel;golden_id[sent]=frame;sent=sent+1;
  @(negedge clk);valid=0;
 end endtask
 task frame;
 input integer w,h,f;integer xx,yy;
 begin
  width=w;height=h;id=f;
  for(yy=0;yy<h;yy=yy+1)for(xx=0;xx<w;xx=xx+1)begin
   pixel((f*24'h50371+yy*24'h117+xx*13)&24'hffffff,xx==0&&yy==0,xx==w-1,f);
   // Non-SOF changes must not affect the in-flight frame configuration.
   width=13;height=9;id=127;
  end
 end endtask
 task reset_control;
 begin @(negedge clk);rst_n=0;valid=0;fault_valid=0;
  repeat(3)@(negedge clk);rst_n=1;end
 endtask
 task raw_pixel;
 input first_pixel,last_pixel;
 begin @(negedge clk);valid=1;sof=first_pixel;eol=last_pixel;
  @(posedge clk);while(!ready)@(posedge clk);
  @(negedge clk);valid=0;end
 endtask
 task fault_word;
 input[2:0] keep;input[7:0] user;input last;
 begin @(negedge clk);fault_keep=keep;fault_user=user;fault_last=last;fault_valid=1;
  @(posedge clk);while(!fault_ready)@(posedge clk);
  @(negedge clk);fault_valid=0;end
 endtask
 integer start_cycles,start_received;
 initial begin
  #1;rst_n=1;#1;rst_n=0;repeat(3)@(negedge clk);rst_n=1;
  frame(1,1,1);frame(3,2,2);frame(320,240,3);frame(640,480,4);
  wait(received==sent);@(negedge clk);
  if(enc_error||dec_error||packets!=723||stall_cycles==0)$fatal(1,"legal frame errors/counters %d",packets);
  $display("PASS video full-frame randomized backpressure pixels=%0d line_packets=%0d stalls=%0d",received,packets,stall_cycles);
  // A truly continuous source/sink establishes codec II=1 independently.
  if(!THROUGH_FABRIC)begin
  continuous=1;repeat(4)@(negedge clk);width=128;height=1;id=5;
  start_cycles=cycles;start_received=received;
  @(negedge clk);valid=1;
  for(integer i=0;i<128;i=i+1)begin
   data=i;sof=i==0;eol=i==127;
   golden_data[sent]=i;golden_sof[sent]=i==0;golden_eol[sent]=i==127;golden_id[sent]=5;sent=sent+1;
   if(!ready)$fatal(1,"II1 ready bubble");@(negedge clk);
  end
  valid=0;wait(received==sent);@(negedge clk);
  if(cycles-start_cycles>132||enc_error||dec_error)$fatal(1,"II1 failure");
  end
  // Missing SOF and early EOL must flag errors; no silent recovery claim.
  verify=0;@(negedge clk);valid=1;sof=0;eol=1;data=0;
  @(negedge clk);valid=0;repeat(3)@(negedge clk);
  if(!enc_error)$fatal(1,"missing SOF ignored");
  reset_control; width=3;height=2;raw_pixel(1,1);if(!enc_error)$fatal(1,"early EOL ignored");
  reset_control; width=1;height=1;raw_pixel(1,0);if(!enc_error)$fatal(1,"missing EOL ignored");
  reset_control; width=0;height=1;raw_pixel(1,1);if(!enc_error)$fatal(1,"zero width ignored");
  reset_control; width=3;height=2;raw_pixel(1,0);raw_pixel(1,0);if(!enc_error)$fatal(1,"overlapping SOF ignored");
  reset_control;fault_word(3'b011,0,1);if(!fault_error)$fatal(1,"short RGB keep ignored");
  reset_control;fault_word(7,8'h12,0);fault_word(7,8'h14,1);if(!fault_error)$fatal(1,"changing metadata ignored");
  if(!THROUGH_FABRIC)$display("PASS video codec II1=128 pixels, frame-config latching, malformed-frame detection");
  else $display("PASS video composed fabric complete frames, metadata and pixel golden, zero drops");
  $finish;
 end
 initial begin #100000000;$fatal(1,"timeout");end
endmodule
