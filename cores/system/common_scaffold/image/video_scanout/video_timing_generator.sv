// Runtime programmable single-clock timing. pixel_tick is independent of ce.
module video_timing_generator #(parameter MAX_ACTIVE=4096,MAX_TOTAL=8192)(
input wire clk,rst_n,ce,pixel_tick,start_valid,stop,abort,output wire start_ready,
input wire[15:0]cfg_h_active,cfg_h_front,cfg_h_sync,cfg_h_back,
input wire[15:0]cfg_v_active,cfg_v_front,cfg_v_sync,cfg_v_back,
input wire cfg_hsync_positive,cfg_vsync_positive,
output reg running,output reg done_valid,input wire done_ready,
output reg frame_error,output reg[7:0]error_code,
output reg[15:0]h_count,v_count,output wire hsync,vsync,de,sof,eol,eof,frame_end);
reg[15:0]ha,va,hs,he,vs,ve,ht,vt;reg hp,vp,pending,armed;
wire[17:0]ch={2'b0,cfg_h_active}+{2'b0,cfg_h_front}+{2'b0,cfg_h_sync}+{2'b0,cfg_h_back};
wire[17:0]cv={2'b0,cfg_v_active}+{2'b0,cfg_v_front}+{2'b0,cfg_v_sync}+{2'b0,cfg_v_back};
assign start_ready=!running&&!done_valid&&!armed;
assign de=running&&h_count<ha&&v_count<va;
assign sof=de&&h_count==0&&v_count==0;assign eol=de&&h_count==ha-1;
assign eof=eol&&v_count==va-1;assign frame_end=running&&h_count==ht-1&&v_count==vt-1;
assign hsync=(running&&h_count>=hs&&h_count<he)?hp:!hp;
assign vsync=(running&&v_count>=vs&&v_count<ve)?vp:!vp;
always @(posedge clk)begin
if(!rst_n)begin running<=0;done_valid<=0;frame_error<=0;error_code<=0;h_count<=0;v_count<=0;ha<=0;va<=0;hs<=0;he<=0;vs<=0;ve<=0;ht<=0;vt<=0;hp<=0;vp<=0;pending<=0;armed<=0;end
else begin
if(ce&&done_valid&&done_ready)done_valid<=0;
if(ce&&start_valid&&start_ready)begin
frame_error<=0;error_code<=0;h_count<=0;v_count<=0;pending<=0;
ha<=cfg_h_active;va<=cfg_v_active;hs<=cfg_h_active+cfg_h_front;he<=cfg_h_active+cfg_h_front+cfg_h_sync;
vs<=cfg_v_active+cfg_v_front;ve<=cfg_v_active+cfg_v_front+cfg_v_sync;ht<=ch[15:0];vt<=cv[15:0];hp<=cfg_hsync_positive;vp<=cfg_vsync_positive;
if(MAX_ACTIVE<1||MAX_ACTIVE>4096||MAX_TOTAL<1||MAX_TOTAL>65535||cfg_h_active==0||cfg_v_active==0||cfg_h_active>MAX_ACTIVE||cfg_v_active>MAX_ACTIVE||cfg_h_sync==0||cfg_v_sync==0||ch>MAX_TOTAL||cv>MAX_TOTAL)begin done_valid<=1;frame_error<=1;error_code<=1;end
else armed<=1;
end
if(armed)begin
if(ce&&(stop||abort))begin armed<=0;done_valid<=1;if(abort)begin frame_error<=1;error_code<=3;end end
else if(pixel_tick)begin armed<=0;running<=1;end
end
if(running)begin
if(ce&&(stop||abort))begin pending<=1;if(abort)begin frame_error<=1;error_code<=3;end end
if(pixel_tick)begin
if(h_count==ht-1)begin h_count<=0;
if(v_count==vt-1)begin v_count<=0;if(pending||(ce&&(stop||abort)))begin running<=0;done_valid<=1;end end
else v_count<=v_count+1;
end else h_count<=h_count+1;
end end
end end
endmodule
