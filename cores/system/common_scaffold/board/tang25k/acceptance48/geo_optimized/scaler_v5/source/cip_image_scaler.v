// Functional bounded nearest/bilinear/bicubic scaling frame adapter; see FUNCTIONAL_IMAGE_ABI.md.
module cip_image_scaler #(parameter DATA_W=24, parameter TAG_W=8, parameter MAX_WIDTH=64, parameter MAX_HEIGHT=64, parameter PIXEL_W=8)(
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
localparam LANES=DATA_W/(PIXEL_W>0?PIXEL_W:1);
localparam SUPPORTED=PIXEL_W>=1 && PIXEL_W<=16 && DATA_W>=PIXEL_W && DATA_W<=32 &&
 DATA_W==PIXEL_W*LANES && MAX_WIDTH>=1 && MAX_WIDTH<=65535 && MAX_HEIGHT>=1 && MAX_HEIGHT<=65535 &&
 (64'd1*MAX_WIDTH*MAX_HEIGHT)<=1048576;
reg [1:0] state;
reg [15:0] sw,sh,dw,dh;
reg filter_mode,bicubic;
wire geo_ready,geo_rv,geo_sr,geo_mv,geo_ms,geo_me;
wire [3:0] geo_error;
wire [DATA_W-1:0] geo_data;
wire cubic_ready,cubic_rv,cubic_sr,cubic_mv,cubic_ms,cubic_me;
wire [1:0] cubic_error;
wire [DATA_W-1:0] cubic_data;
wire core_ready=bicubic?cubic_ready:geo_ready;
wire core_rv=bicubic?cubic_rv:geo_rv;
wire core_sr=bicubic?cubic_sr:geo_sr;
wire core_mv=bicubic?cubic_mv:geo_mv;
wire core_ms=bicubic?cubic_ms:geo_ms;
wire core_me=bicubic?cubic_me:geo_me;
wire [3:0] core_error=bicubic?{2'b0,cubic_error}:geo_error;
wire [DATA_W-1:0] core_data=bicubic?cubic_data:geo_data;
wire bad_config=!SUPPORTED || cfg_src_width==0 || cfg_src_height==0 ||
 cfg_src_width>MAX_WIDTH || cfg_src_height>MAX_HEIGHT || cfg_dst_width==0 || cfg_dst_height==0 ||
 cfg_param0!=0 || cfg_param1!=0 || cfg_frame_base!=0 || cfg_frame_stride!=0 || cfg_aux_base!=0;
assign cmd_ready=rst_n && state==IDLE;
assign rsp_valid=rst_n && state==RESPONSE;
assign s_ready=rst_n && state==RUN && core_sr;
assign m_valid=rst_n && state==RUN && core_mv;
assign m_data=core_data;
assign m_sof=m_valid && core_ms;
assign m_eol=m_valid && core_me;
assign coeff_ready=0;assign aux_ready=0;assign mem_req_valid=0;assign mem_req_write=0;
assign mem_req_addr=0;assign mem_req_wdata=0;assign mem_req_wstrb=0;assign mem_rsp_ready=0;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=IDLE;sw<=0;sh<=0;dw<=0;dh<=0;filter_mode<=0;bicubic<=0;rsp_tag<=0;rsp_error<=0;end
 else if(clk_en)begin
  case(state)
   IDLE:if(cmd_valid && cmd_ready)begin
    rsp_tag<=cmd_tag;rsp_error<=0;
    if(cfg_mode>2)begin state<=RESPONSE;rsp_error<=1;end
    else if(bad_config)begin state<=RESPONSE;rsp_error<=2;end
    else begin state<=START;sw<=cfg_src_width;sh<=cfg_src_height;dw<=cfg_dst_width;dh<=cfg_dst_height;filter_mode<=cfg_mode[0];bicubic<=cfg_mode==2;end
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
 .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cfg_valid(state==START && !bicubic),.cfg_ready(geo_ready),.cfg_tag(rsp_tag),
 .cfg_mode(4'd1),.cfg_filter({1'b0,filter_mode}),.cfg_src_width(sw),.cfg_src_height(sh),.cfg_dst_width(dw),.cfg_dst_height(dh),
 .cfg_h00(32'sd65536),.cfg_h01(32'sd0),.cfg_h02(32'sd0),.cfg_h10(32'sd0),.cfg_h11(32'sd65536),.cfg_h12(32'sd0),
 .cfg_h20(32'sd0),.cfg_h21(32'sd0),.cfg_h22(32'sd65536),.busy(),
 .rsp_valid(geo_rv),.rsp_ready(state==RUN && !bicubic),.rsp_tag(),.rsp_error(geo_error),.rsp_pixels(),
 .s_valid(s_valid && state==RUN && !bicubic),.s_ready(geo_sr),.s_data(s_data),.s_sof(s_sof),.s_eol(s_eol),
 .m_valid(geo_mv),.m_ready(m_ready && state==RUN && !bicubic),.m_data(geo_data),.m_error(),.m_sof(geo_ms),.m_eol(geo_me),.m_eof());
 cip_image_bicubic_frame #(.DATA_W(DATA_W),.TAG_W(TAG_W),.MAX_WIDTH(MAX_WIDTH),.MAX_HEIGHT(MAX_HEIGHT),.PIXEL_W(PIXEL_W)) cubic(
 .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cmd_valid(state==START && bicubic),.cmd_ready(cubic_ready),.cmd_tag(rsp_tag),
 .cfg_width(sw),.cfg_height(sh),.cfg_dst_width(dw),.cfg_dst_height(dh),
 .rsp_valid(cubic_rv),.rsp_ready(state==RUN && bicubic),.rsp_tag(),.rsp_error(cubic_error),
 .s_data(s_data),.s_valid(s_valid && state==RUN && bicubic),.s_sof(s_sof),.s_eol(s_eol),.s_ready(cubic_sr),
 .m_data(cubic_data),.m_valid(cubic_mv),.m_sof(cubic_ms),.m_eol(cubic_me),.m_last(),.m_ready(m_ready && state==RUN && bicubic));
end else begin:unsupported
 assign geo_ready=0;assign geo_rv=0;assign geo_sr=0;assign geo_mv=0;assign geo_ms=0;assign geo_me=0;assign geo_data=0;assign geo_error=0;
 assign cubic_ready=0;assign cubic_rv=0;assign cubic_sr=0;assign cubic_mv=0;assign cubic_ms=0;assign cubic_me=0;assign cubic_data=0;assign cubic_error=0;
end endgenerate
endmodule
