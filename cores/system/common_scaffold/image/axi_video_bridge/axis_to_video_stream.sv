// AXI input capture runs on every clock. ce applies only to pixel/status side.
module axis_to_video_stream #(parameter WIDTH=16,HEIGHT=12,DATA_WIDTH=24)(
input wire clk,rst_n,ce,start_valid,abort,input wire[15:0]cfg_width,cfg_height,
output wire start_ready,input wire[DATA_WIDTH-1:0]s_axis_tdata,input wire s_axis_tvalid,
output wire s_axis_tready,input wire s_axis_tuser,s_axis_tlast,
output reg[DATA_WIDTH-1:0]m_pixel,output reg m_valid,input wire m_ready,
output reg m_sof,m_eol,m_last,output wire done_valid,input wire done_ready,
output reg frame_error,output reg[7:0]error_code);
localparam IDLE=0,RUN=1,DRAIN=2,DONE=3;
reg[1:0]state;reg[15:0]w,h,x,y;reg full;
reg[DATA_WIDTH-1:0]data;reg user_,last_;
assign start_ready=state==IDLE;
// Refill and advance concurrently. Never accept a beat beyond the final frame pixel.
assign s_axis_tready=state==RUN&&(!full||(ce&&(!m_valid||m_ready)&&!(x==w-1&&y==h-1)));
assign done_valid=state==DONE;
always @(posedge clk)begin
if(!rst_n)begin state<=IDLE;w<=0;h<=0;x<=0;y<=0;full<=0;data<=0;user_<=0;last_<=0;m_pixel<=0;m_valid<=0;m_sof<=0;m_eol<=0;m_last<=0;frame_error<=0;error_code<=0;end
else begin
 // This buffer prevents CE-disabled AXI handshakes from losing or duplicating data.
 if(s_axis_tvalid&&s_axis_tready)begin data<=s_axis_tdata;user_<=s_axis_tuser;last_<=s_axis_tlast;full<=1;end
 if(ce)begin
 if(m_valid&&m_ready)m_valid<=0;
 if(abort&&state!=IDLE&&state!=DONE)begin state<=DRAIN;full<=0;frame_error<=1;error_code<=3;end
 else case(state)
 IDLE:if(start_valid)begin w<=cfg_width;h<=cfg_height;x<=0;y<=0;full<=0;frame_error<=0;error_code<=0;
 if(WIDTH<1||WIDTH>4096||HEIGHT<1||HEIGHT>4096||DATA_WIDTH<1||DATA_WIDTH>64||cfg_width==0||cfg_height==0||cfg_width>WIDTH||cfg_height>HEIGHT)begin state<=DONE;frame_error<=1;error_code<=1;end else state<=RUN;end
 RUN:if(full&&(!m_valid||m_ready))begin full<=s_axis_tvalid&&s_axis_tready;
 if(user_!=(x==0&&y==0)||last_!=(x==w-1))begin state<=DRAIN;frame_error<=1;error_code<=2;end
 else begin m_pixel<=data;m_sof<=user_;m_eol<=last_;m_last<=x==w-1&&y==h-1;m_valid<=1;
 if(x==w-1)begin x<=0;y<=y+1;if(y==h-1)state<=DRAIN;end else x<=x+1;end end
 DRAIN:begin full<=0;if(!m_valid)state<=DONE;end
 DONE:if(done_ready)state<=IDLE;
 endcase end
end end
endmodule
