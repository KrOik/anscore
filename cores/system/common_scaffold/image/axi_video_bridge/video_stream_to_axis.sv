// AXI output handshake is independent of ce. ce applies only to pixel/status side.
module video_stream_to_axis #(parameter WIDTH=16,HEIGHT=12,DATA_WIDTH=24)(
input wire clk,rst_n,ce,start_valid,abort,input wire[15:0]cfg_width,cfg_height,
output wire start_ready,input wire[DATA_WIDTH-1:0]s_pixel,input wire s_valid,s_sof,s_eol,s_last,
output wire s_ready,output reg[DATA_WIDTH-1:0]m_axis_tdata,output reg m_axis_tvalid,
input wire m_axis_tready,output reg m_axis_tuser,m_axis_tlast,
output wire done_valid,input wire done_ready,output reg frame_error,output reg[7:0]error_code);
localparam IDLE=0,RUN=1,DRAIN=2,DONE=3;
reg[1:0]state;reg[15:0]w,h,x,y;
assign start_ready=state==IDLE;assign s_ready=state==RUN&&(!m_axis_tvalid||m_axis_tready);
assign done_valid=state==DONE;
always @(posedge clk)begin
if(!rst_n)begin state<=IDLE;w<=0;h<=0;x<=0;y<=0;m_axis_tdata<=0;m_axis_tvalid<=0;m_axis_tuser<=0;m_axis_tlast<=0;frame_error<=0;error_code<=0;end
else begin
 // Once exposed, AXI VALID is retired on every real AXI handshake, even ce=0.
 if(m_axis_tvalid&&m_axis_tready)m_axis_tvalid<=0;
 if(ce)begin
 if(abort&&state!=IDLE&&state!=DONE)begin state<=DRAIN;frame_error<=1;error_code<=3;end
 else case(state)
 IDLE:if(start_valid)begin w<=cfg_width;h<=cfg_height;x<=0;y<=0;frame_error<=0;error_code<=0;
 if(WIDTH<1||WIDTH>4096||HEIGHT<1||HEIGHT>4096||DATA_WIDTH<1||DATA_WIDTH>64||cfg_width==0||cfg_height==0||cfg_width>WIDTH||cfg_height>HEIGHT)begin state<=DONE;frame_error<=1;error_code<=1;end else state<=RUN;end
 RUN:if(s_valid&&s_ready)begin
 if(s_sof!=(x==0&&y==0)||s_eol!=(x==w-1)||s_last!=(x==w-1&&y==h-1))begin state<=DRAIN;frame_error<=1;error_code<=2;end
 else begin m_axis_tdata<=s_pixel;m_axis_tuser<=s_sof;m_axis_tlast<=s_eol;m_axis_tvalid<=1;
 if(x==w-1)begin x<=0;y<=y+1;if(y==h-1)state<=DRAIN;end else x<=x+1;end end
 DRAIN:if(!m_axis_tvalid)state<=DONE;
 DONE:if(done_ready)state<=IDLE;
 endcase end
end end
endmodule
