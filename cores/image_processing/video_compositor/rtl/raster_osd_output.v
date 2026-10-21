// Single-clock digital scanout reference. No PHY/clock generator.
module raster_osd_output(
 input wire clk,rst_n,pixel_tick,start_valid,stop,abort,done_ready,
 output wire start_ready,running,done_valid,frame_error,
 input wire [15:0] h_active,h_front,h_sync,h_back,v_active,v_front,v_sync,v_back,
 input wire h_positive,v_positive,
 input wire write_valid,output wire write_ready,input wire [2:0] write_index,
 input wire [31:0] write_data,input wire [3:0] write_strb,
 input wire commit_valid,output wire commit_ready,pending,
 output wire [31:0] config_version,
 output wire pixel_valid,output wire [23:0] rgb,
 output wire out_de,out_hsync,out_vsync,out_sof,out_eol,out_last,
 output wire [31:0] out_frame,output wire [12:0] out_version,
 output wire [7:0] out_error,
 output wire crc_valid,output wire [31:0] crc_frame,crc_value,crc_pixels,
 output wire [7:0] crc_error,output reg [12:0] crc_version,output reg overflow,
 output wire [31:0] source_frame
);
wire tr,hs,vs,de,sof,eol,eof,fe;wire [15:0] x,y;wire [7:0] timing_error;
wire source_valid=running&&pixel_tick;
reg [5:0] occupied;reg [31:0] frame,expected;
assign source_frame=frame;
wire [255:0] active;
assign start_ready=tr&&!(|occupied);
wire launch=start_valid&&start_ready;
video_timing_generator timer(.clk(clk),.rst_n(rst_n),.ce(1'b1),.pixel_tick(pixel_tick),
 .start_valid(launch),.stop(stop),.abort(abort),.start_ready(tr),
 .cfg_h_active(h_active),.cfg_h_front(h_front),.cfg_h_sync(h_sync),.cfg_h_back(h_back),
 .cfg_v_active(v_active),.cfg_v_front(v_front),.cfg_v_sync(v_sync),.cfg_v_back(v_back),
 .cfg_hsync_positive(h_positive),.cfg_vsync_positive(v_positive),
 .running(running),.done_valid(done_valid),.done_ready(done_ready),
 .frame_error(frame_error),.error_code(timing_error),.h_count(x),.v_count(y),
 .hsync(hs),.vsync(vs),.de(de),.sof(sof),.eol(eol),.eof(eof),.frame_end(fe));
sys_atomic_config #(.WORDS(8)) config_bank(clk,rst_n,write_valid,write_ready,
 write_index,write_data,write_strb,commit_valid,commit_ready,
 ((!running&&tr)||(source_valid&&fe)),active,config_version,pending);
// word0 RGB base; word1/2 solid overlays; word3 alpha0[8:0],alpha1[24:16];
// word4 enables[1:0],key enables[3:2],mode[9:8]; word5/6 keys; word7 reserved.
wire [1:0] mode=active[137:136];
wire [23:0] coordinate={x[7:0],y[7:0],frame[7:0]};
wire [23:0] base=mode==1?(active[23:0]^coordinate):
 mode==2?{3{x[7:0]+y[7:0]}}:active[23:0];
wire sr;wire [23:0] composed;wire [15:0] tag;
dual_osd_stream compositor(clk,rst_n,source_valid,sr,base,active[55:32],active[87:64],
 active[183:160],active[215:192],active[104:96],active[120:112],active[129:128],active[131:130],
 sof,eol,eof,{config_version[12:0],vs,hs,de},frame,8'd0,
 pixel_valid,1'b1,composed,out_sof,out_eol,out_last,tag,out_frame,out_error);
assign out_de=tag[0];assign out_hsync=tag[1];assign out_vsync=tag[2];
assign out_version=tag[15:3];assign rgb=out_de?composed:24'd0;
video_frame_crc monitor(clk,rst_n,pixel_valid&&out_de,1'b1,out_sof,out_last,
 rgb,out_frame,expected,out_error,crc_valid,crc_frame,crc_value,crc_pixels,crc_error);
always @(posedge clk)begin
 if(!rst_n)begin occupied<=0;frame<=0;expected<=0;overflow<=0;crc_version<=0;end
 else begin
  occupied<={occupied[4:0],source_valid};
  if(launch)begin frame<=0;expected<=h_active*v_active;overflow<=0;end
  if(source_valid&&fe)frame<=frame+1;
  if(source_valid&&!sr)overflow<=1;
  if(pixel_valid&&out_de&&out_last)crc_version<=out_version;
 end
end
endmodule
