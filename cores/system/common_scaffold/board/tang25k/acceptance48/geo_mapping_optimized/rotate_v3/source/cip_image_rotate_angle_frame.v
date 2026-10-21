// Centered inverse rotation using validated signed Q16.16 cosine/sine.
module cip_image_rotate_angle_frame #(
 parameter DATA_W=24,TAG_W=8,MAX_WIDTH=64,MAX_HEIGHT=64,PIXEL_W=8
)(
 input wire clk,rst_n,clk_en,
 input wire cmd_valid,output wire cmd_ready,input wire [TAG_W-1:0] cmd_tag,
 input wire [15:0] cfg_width,cfg_height,cfg_dst_width,cfg_dst_height,
 input wire cfg_bilinear,input wire signed [31:0] cfg_cos,cfg_sin,
 output wire rsp_valid,input wire rsp_ready,output reg [TAG_W-1:0] rsp_tag,
 output reg [1:0] rsp_error,
 input wire [DATA_W-1:0] s_data,input wire s_valid,s_sof,s_eol,output wire s_ready,
 output wire [DATA_W-1:0] m_data,output wire m_valid,m_sof,m_eol,m_last,input wire m_ready
);
localparam IDLE=0,START=1,RUN=2,RESPONSE=3;
localparam LANES=DATA_W/(PIXEL_W>0?PIXEL_W:1);
localparam SUPPORTED=PIXEL_W>=1 && PIXEL_W<=16 && DATA_W>=PIXEL_W && DATA_W<=32 &&
 DATA_W==PIXEL_W*LANES && MAX_WIDTH>=1 && MAX_WIDTH<=65535 && MAX_HEIGHT>=1 && MAX_HEIGHT<=65535 &&
 (64'd1*MAX_WIDTH*MAX_HEIGHT)<=1048576;
reg [1:0] state;
reg [15:0] sw,sh,dw,dh;
reg filter_mode;
reg signed [31:0] cosine,sine,offset_x,offset_y;
wire signed [63:0] c_sq=$signed(cfg_cos)*$signed(cfg_cos);
wire signed [63:0] s_sq=$signed(cfg_sin)*$signed(cfg_sin);
wire [64:0] norm={1'b0,c_sq}+{1'b0,s_sq};
wire signed [63:0] source_cx=$signed({48'd0,cfg_width})-64'sd1;
wire signed [63:0] source_cy=$signed({48'd0,cfg_height})-64'sd1;
wire signed [63:0] target_cx=$signed({48'd0,cfg_dst_width})-64'sd1;
wire signed [63:0] target_cy=$signed({48'd0,cfg_dst_height})-64'sd1;
wire signed [63:0] twice_x=(source_cx<<<16)-$signed(cfg_cos)*target_cx-$signed(cfg_sin)*target_cy;
wire signed [63:0] twice_y=(source_cy<<<16)+$signed(cfg_sin)*target_cx-$signed(cfg_cos)*target_cy;
wire signed [63:0] tx=twice_x>>>1,ty=twice_y>>>1;
wire angle_bad=cfg_cos < -32'sd65536 || cfg_cos>32'sd65536 || cfg_sin < -32'sd65536 || cfg_sin>32'sd65536 ||
 norm<65'd4294836224 || norm>65'd4295098368 ||
 tx < -64'sd2147483648 || tx>64'sd2147483647 || ty < -64'sd2147483648 || ty>64'sd2147483647;
wire core_ready,core_rv,core_sr,core_mv,core_ms,core_me,core_last;
wire [3:0] core_error;
wire [DATA_W-1:0] core_data;
wire bad_config=!SUPPORTED || angle_bad || cfg_width==0 || cfg_height==0 ||
 cfg_width>MAX_WIDTH || cfg_height>MAX_HEIGHT || cfg_dst_width==0 || cfg_dst_height==0;
assign cmd_ready=rst_n && state==IDLE;
assign rsp_valid=rst_n && state==RESPONSE;
assign s_ready=rst_n && state==RUN && core_sr;
assign m_valid=rst_n && state==RUN && core_mv;
assign m_data=core_data;
assign m_sof=m_valid && core_ms;
assign m_eol=m_valid && core_me;
assign m_last=m_valid && core_last;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=IDLE;sw<=0;sh<=0;dw<=0;dh<=0;filter_mode<=0;cosine<=0;sine<=0;offset_x<=0;offset_y<=0;rsp_tag<=0;rsp_error<=0;end
 else if(clk_en)begin
  case(state)
   IDLE:if(cmd_valid && cmd_ready)begin
    rsp_tag<=cmd_tag;rsp_error<=0;
    if(bad_config)begin state<=RESPONSE;rsp_error<=2;end
    else begin state<=START;sw<=cfg_width;sh<=cfg_height;dw<=cfg_dst_width;dh<=cfg_dst_height;filter_mode<=cfg_bilinear;cosine<=cfg_cos;sine<=cfg_sin;offset_x<=tx[31:0];offset_y<=ty[31:0];end
   end
   START:if(core_ready)state<=RUN;
   RUN:if(core_rv)begin
    rsp_error<=core_error==0?2'd0:((core_error==1 || core_error==2)?2'd2:2'd3);
    state<=RESPONSE;
   end
   RESPONSE:if(rsp_ready)state<=IDLE;
   default:begin state<=RESPONSE;rsp_error<=3;end
  endcase
 end
end
generate if(SUPPORTED)begin:enabled
 img_geo_frame_buffered #(.PIXEL_W(PIXEL_W),.LANES(LANES),.TAG_W(TAG_W),.MAX_WIDTH(MAX_WIDTH),.MAX_HEIGHT(MAX_HEIGHT)) core(
 .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cfg_valid(state==START),.cfg_ready(core_ready),.cfg_tag(rsp_tag),
 .cfg_mode(4'd7),.cfg_filter({1'b0,filter_mode}),.cfg_src_width(sw),.cfg_src_height(sh),.cfg_dst_width(dw),.cfg_dst_height(dh),
 .cfg_h00(cosine),.cfg_h01(sine),.cfg_h02(offset_x),.cfg_h10(-sine),.cfg_h11(cosine),.cfg_h12(offset_y),
 .cfg_h20(32'sd0),.cfg_h21(32'sd0),.cfg_h22(32'sd65536),.busy(),
 .rsp_valid(core_rv),.rsp_ready(state==RUN),.rsp_tag(),.rsp_error(core_error),.rsp_pixels(),
 .s_valid(s_valid && state==RUN),.s_ready(core_sr),.s_data(s_data),.s_sof(s_sof),.s_eol(s_eol),
 .m_valid(core_mv),.m_ready(m_ready && state==RUN),.m_data(core_data),.m_error(),.m_sof(core_ms),.m_eol(core_me),.m_eof(core_last));
end else begin:unsupported
 assign core_ready=0;assign core_rv=0;assign core_sr=0;assign core_mv=0;assign core_ms=0;assign core_me=0;assign core_last=0;assign core_data=0;assign core_error=0;
end endgenerate
endmodule
