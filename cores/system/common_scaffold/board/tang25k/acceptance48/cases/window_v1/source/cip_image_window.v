// Functional bounded serialized 3x3 windows frame adapter; see FUNCTIONAL_IMAGE_ABI.md.
module cip_image_window #(parameter DATA_W=24, parameter TAG_W=8, parameter MAX_WIDTH=64, parameter MAX_HEIGHT=64)(
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
// Each cropped output window is nine DATA_W words, row-major top-left first.
// cfg_dst_width/height count windows. SOF marks first word; EOL last word of row.
localparam IDLE=0,START=1,RUN=2,RESPONSE=3;
localparam SUPPORTED=DATA_W>=1 && DATA_W<=32 && MAX_WIDTH>=3 && MAX_WIDTH<=65535 && MAX_HEIGHT>=3 && MAX_HEIGHT<=65535;
reg [1:0] state;
reg [15:0] width,height;
reg packet_valid,packet_sof,packet_eol;
reg [9*DATA_W-1:0] packet;
reg [3:0] index;
wire core_ready,core_rv,core_sr,core_mv,core_ms,core_me;
wire [3:0] core_error;
wire [9*DATA_W-1:0] taps;
wire take_window=state==RUN && !packet_valid;
wire bad=!SUPPORTED || cfg_src_width<3 || cfg_src_height<3 || cfg_src_width>MAX_WIDTH || cfg_src_height>MAX_HEIGHT ||
 cfg_dst_width!=cfg_src_width-2 || cfg_dst_height!=cfg_src_height-2 || cfg_param0!=0 || cfg_param1!=0 ||
 cfg_frame_base!=0 || cfg_frame_stride!=0 || cfg_aux_base!=0;
assign cmd_ready=rst_n && state==IDLE;
assign rsp_valid=rst_n && state==RESPONSE;
assign s_ready=rst_n && state==RUN && core_sr;
assign m_valid=rst_n && state==RUN && packet_valid;
assign m_data=packet >> (index*DATA_W);
assign m_sof=m_valid && packet_sof && index==0;
assign m_eol=m_valid && packet_eol && index==8;
assign coeff_ready=0;assign aux_ready=0;assign mem_req_valid=0;assign mem_req_write=0;
assign mem_req_addr=0;assign mem_req_wdata=0;assign mem_req_wstrb=0;assign mem_rsp_ready=0;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=IDLE;width<=0;height<=0;rsp_tag<=0;rsp_error<=0;packet_valid<=0;packet<=0;packet_sof<=0;packet_eol<=0;index<=0;end
 else if(clk_en)begin
  if(core_mv && take_window)begin packet<=taps;packet_valid<=1;packet_sof<=core_ms;packet_eol<=core_me;index<=0;end
  if(m_valid && m_ready)begin
   if(index==8)begin packet_valid<=0;index<=0;end else index<=index+1'b1;
  end
  case(state)
   IDLE:if(cmd_valid)begin
    rsp_tag<=cmd_tag;rsp_error<=0;packet_valid<=0;index<=0;
    if(cfg_mode!=0)begin state<=RESPONSE;rsp_error<=1;end
    else if(bad)begin state<=RESPONSE;rsp_error<=2;end
    else begin state<=START;width<=cfg_src_width;height<=cfg_src_height;end
   end
   START:if(core_ready)state<=RUN;
   RUN:if(core_rv && !packet_valid)begin
    rsp_error<=core_error==0?2'd0:((core_error==1 || core_error==2)?2'd2:2'd3);state<=RESPONSE;
   end
   RESPONSE:if(rsp_ready)state<=IDLE;
   default:begin state<=RESPONSE;rsp_error<=3;end
  endcase
 end
end
generate if(SUPPORTED)begin:enabled
 img_window3x3_valid_draft #(.PIXEL_W(DATA_W),.MAX_WIDTH(MAX_WIDTH)) core(
 .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cfg_valid(state==START),.cfg_ready(core_ready),.cfg_width(width),.cfg_height(height),
 .rsp_valid(core_rv),.rsp_ready(state==RUN && !packet_valid),.rsp_error(core_error),
 .s_data(s_data),.s_valid(s_valid && state==RUN),.s_sof(s_sof),.s_eol(s_eol),.s_ready(core_sr),
 .m_taps(taps),.m_center(),.m_x(),.m_y(),.m_valid(core_mv),.m_sof(core_ms),.m_eol(core_me),.m_eof(),.m_ready(take_window));
end else begin:unsupported
 assign core_ready=0;assign core_rv=0;assign core_sr=0;assign core_mv=0;assign core_ms=0;assign core_me=0;assign core_error=0;assign taps=0;
end endgenerate
endmodule
