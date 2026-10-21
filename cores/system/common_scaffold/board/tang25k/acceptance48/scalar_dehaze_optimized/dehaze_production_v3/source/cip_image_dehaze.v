// Functional full-frame DCP adapter. See adapter runner for exact arithmetic ABI.
module cip_image_dehaze #(parameter DATA_W=24,TAG_W=8,MAX_WIDTH=32,MAX_HEIGHT=32,MAX_RADIUS=3,
 parameter AIRLIGHT_PERMILLE=1,GUIDED_EPSILON=100)(
    input wire clk, rst_n, clk_en,
    input wire cmd_valid,
    output wire cmd_ready,
    input wire [TAG_W-1:0] cmd_tag,
    output wire rsp_valid,
    input wire rsp_ready,
    output reg [TAG_W-1:0] rsp_tag,
    output reg [1:0] rsp_error,
    input wire [15:0] cfg_src_width, cfg_src_height,
    input wire [15:0] cfg_dst_width, cfg_dst_height,
    input wire [3:0] cfg_mode,
    input wire [31:0] cfg_param0, cfg_param1,
    input wire [31:0] cfg_frame_base, cfg_frame_stride,
    input wire [31:0] cfg_aux_base,
    input wire coeff_valid,
    output wire coeff_ready,
    input wire [15:0] coeff_addr,
    input wire [31:0] coeff_data,
    input wire [DATA_W-1:0] aux_data,
    input wire aux_valid, aux_sof, aux_eol,
    output wire aux_ready,
    output wire mem_req_valid, mem_req_write,
    output wire [31:0] mem_req_addr, mem_req_wdata,
    output wire [3:0] mem_req_wstrb,
    input wire mem_req_ready, mem_rsp_valid,
    input wire [31:0] mem_rsp_rdata,
    input wire mem_rsp_error,
    output wire mem_rsp_ready,
    input wire s_sof, s_eol,
    output wire m_sof, m_eol,
    input wire [DATA_W-1:0] s_data,
    input wire s_valid,
    output wire s_ready,
    output wire [DATA_W-1:0] m_data,
    output wire m_valid,
    input wire m_ready
);
localparam IDLE=0,START=1,RUN=2,RESPONSE=3;
localparam SUPPORTED=DATA_W>=24 && DATA_W<=32 && MAX_WIDTH>=1 && MAX_WIDTH<=512 && MAX_HEIGHT>=1 && MAX_HEIGHT<=512 && MAX_RADIUS>=0 && MAX_RADIUS<=7 && AIRLIGHT_PERMILLE>=1 && AIRLIGHT_PERMILLE<=1000 && GUIDED_EPSILON>=1 && GUIDED_EPSILON<=65535;
reg [1:0] state; reg [15:0] width,height,omega,t0; reg [23:0] airlight;
reg [2:0] radius,gradius;reg [1:0] mode;reg high_error;
wire cr,sr,mv,ms,me,rv;wire [23:0] md;wire [3:0] err;
wire bad=!SUPPORTED || cfg_src_width==0 || cfg_src_height==0 || cfg_src_width>MAX_WIDTH || cfg_src_height>MAX_HEIGHT || cfg_dst_width!=cfg_src_width || cfg_dst_height!=cfg_src_height || cfg_param0[15:0]>32768 || cfg_param0[31:16]==0 || cfg_param0[31:16]>32768 || cfg_param1[31:30]!=0 || cfg_param1[26:24]>MAX_RADIUS || (cfg_mode[1] && cfg_param1[29:27]>MAX_RADIUS) || cfg_frame_base!=0 || cfg_frame_stride!=0 || cfg_aux_base!=0;
assign cmd_ready=rst_n && state==IDLE;assign rsp_valid=rst_n && state==RESPONSE;
assign s_ready=rst_n && state==RUN && sr;assign m_valid=rst_n && state==RUN && mv;assign m_data=md;
assign m_sof=m_valid && ms;assign m_eol=m_valid && me;
assign coeff_ready=0;assign aux_ready=0;assign mem_req_valid=0;assign mem_req_write=0;assign mem_req_addr=0;assign mem_req_wdata=0;assign mem_req_wstrb=0;assign mem_rsp_ready=0;
reg [TAG_W-1:0] tag;reg [1:0] error;
assign rsp_tag=tag;assign rsp_error=error;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=IDLE;width<=0;height<=0;omega<=0;t0<=1;airlight<=0;radius<=0;gradius<=0;mode<=0;high_error<=0;tag<=0;error<=0;end
 else if(clk_en)case(state)
 IDLE:if(cmd_valid)begin tag<=cmd_tag;error<=0;high_error<=0;
 if(cfg_mode>3)begin state<=RESPONSE;error<=1;end
 else if(bad)begin state<=RESPONSE;error<=2;end
 else begin state<=START;width<=cfg_src_width;height<=cfg_src_height;omega<=cfg_param0[15:0];t0<=cfg_param0[31:16];airlight<=cfg_param1[23:0];radius<=cfg_param1[26:24];gradius<=cfg_param1[29:27];mode<=cfg_mode[1:0];end end
 START:if(cr)state<=RUN;
 RUN:begin if(s_valid && s_ready && (s_data>>24)!=0)high_error<=1;
 if(rv)begin state<=RESPONSE;error<=err==0?(high_error?2:0):(err==2?2:3);end end
 RESPONSE:if(rsp_ready)state<=IDLE;
 default:state<=IDLE;
 endcase
end
generate if(SUPPORTED)begin:enabled
img_dh_dehaze_frame #(.MAX_WIDTH(MAX_WIDTH),.MAX_HEIGHT(MAX_HEIGHT),.MAX_RADIUS(MAX_RADIUS),.TAG_WIDTH(TAG_W)) core(
 .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cmd_valid(state==START),.cmd_ready(cr),.cmd_width(width),.cmd_height(height),.cmd_dark_radius({1'b0,radius}),
 .cmd_auto_airlight(mode[0]),.cmd_airlight_rgb(airlight),.cmd_airlight_permille(10'(AIRLIGHT_PERMILLE)),.cmd_omega(omega),.cmd_t0(t0),
 .cmd_guided_enable(mode[1]),.cmd_guided_radius({1'b0,gradius}),.cmd_guided_epsilon(32'(GUIDED_EPSILON)),.cmd_tag(tag),
 .s_data(s_data[23:0]),.s_valid(s_valid && state==RUN),.s_sof(s_sof),.s_eol(s_eol),.s_ready(sr),
 .m_data(md),.m_valid(mv),.m_sof(ms),.m_eol(me),.m_eof(),.m_ready(m_ready && state==RUN),.m_tag(),
 .rsp_valid(rv),.rsp_ready(state==RUN),.rsp_error(err),.rsp_tag(),.rsp_airlight_rgb(),.busy());
end else begin assign cr=0;assign sr=0;assign mv=0;assign ms=0;assign me=0;assign md=0;assign rv=0;assign err=0;end endgenerate
endmodule
