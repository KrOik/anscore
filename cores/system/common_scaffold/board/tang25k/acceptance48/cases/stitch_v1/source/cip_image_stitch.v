// Functional bounded RGB translation registration and union-canvas stitch.
module cip_image_stitch #(parameter DATA_W=24, parameter TAG_W=8, parameter WIDTH=32, parameter HEIGHT=24, parameter MAX_SHIFT=2, parameter CAPTURE_TIMEOUT=65536, parameter MIN_CONFIDENCE=1)(
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
localparam IDLE=0,CAP_START=1,CAP_WAIT=2,MAP_START=3,MAP_WAIT=4,RESPONSE=5;
localparam SUPPORTED=DATA_W==24 && WIDTH>2*MAX_SHIFT && HEIGHT>2*MAX_SHIFT && MAX_SHIFT>=0 && MAX_SHIFT<=15 && (64'd1*(WIDTH+2*MAX_SHIFT)*(HEIGHT+2*MAX_SHIFT))<=65536 && CAPTURE_TIMEOUT>0;
reg [2:0] state;reg operation;reg [8:0] weight;reg [31:0] parameter1;
reg [15:0] input_index;
wire core_ready,core_rv,core_sr,core_ar,core_mv,core_ms,core_me;
wire [7:0] core_error;wire [23:0] core_data;
wire bad_config=!SUPPORTED || cfg_src_width!=WIDTH || cfg_src_height!=HEIGHT ||
 cfg_dst_width!=WIDTH+2*MAX_SHIFT || cfg_dst_height!=HEIGHT+2*MAX_SHIFT || cfg_param0>256 ||
 (cfg_mode==0 && cfg_param1[31:24]!=0) || cfg_frame_base!=0 || cfg_frame_stride!=0 || cfg_aux_base!=0;
assign cmd_ready=rst_n && state==IDLE;assign rsp_valid=rst_n && state==RESPONSE;
assign s_ready=rst_n && state==CAP_WAIT && core_sr;assign aux_ready=rst_n && state==CAP_WAIT && core_ar;
assign m_valid=rst_n && state==MAP_WAIT && core_mv;assign m_data=core_data;assign m_sof=m_valid&&core_ms;assign m_eol=m_valid&&core_me;
assign coeff_ready=0;assign mem_req_valid=0;assign mem_req_write=0;assign mem_req_addr=0;assign mem_req_wdata=0;assign mem_req_wstrb=0;assign mem_rsp_ready=0;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=IDLE;operation<=0;weight<=0;parameter1<=0;input_index<=0;rsp_tag<=0;rsp_error<=0;end
 else if(clk_en)begin
  if(s_valid && s_ready)input_index<=input_index+1;
  case(state)
   IDLE:if(cmd_valid && cmd_ready)begin
    rsp_tag<=cmd_tag;rsp_error<=0;input_index<=0;
    if(cfg_mode>1)begin state<=RESPONSE;rsp_error<=1;end
    else if(bad_config)begin state<=RESPONSE;rsp_error<=2;end
    else begin state<=CAP_START;operation<=cfg_mode[0];weight<=cfg_param0[8:0];parameter1<=cfg_param1;end
   end
   CAP_START:if(core_ready)state<=CAP_WAIT;
   CAP_WAIT:if(core_rv)begin
    if(core_error!=0)begin state<=RESPONSE;rsp_error<=2;end else state<=MAP_START;
   end
   MAP_START:if(core_ready)state<=MAP_WAIT;
   MAP_WAIT:if(core_rv)begin state<=RESPONSE;rsp_error<=core_error==0?2'd0:2'd2;end
   RESPONSE:if(rsp_ready)state<=IDLE;
   default:begin state<=RESPONSE;rsp_error<=3;end
  endcase
 end
end
generate if(SUPPORTED)begin:enabled
 img_mf_auto_stitch #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.MAX_SHIFT(MAX_SHIFT),.TAG_WIDTH(16),.FRAME_WIDTH(16),.CAPTURE_TIMEOUT(CAPTURE_TIMEOUT),.MIN_CONFIDENCE(MIN_CONFIDENCE)) core(
 .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cmd_valid(state==CAP_START || state==MAP_START),.cmd_ready(core_ready),
 .cmd_opcode(state==CAP_START?4'd2:(operation?4'd4:4'd3)),.cmd_frameid(16'd0),
 .cfg_aux_weight(weight),.cfg_background(operation?24'd0:parameter1[23:0]),
 .cfg_h00(32'sd1),.cfg_h01(32'sd0),.cfg_h02({{16{parameter1[15]}},parameter1[15:0]}),
 .cfg_h10(32'sd0),.cfg_h11(32'sd1),.cfg_h12({{16{parameter1[31]}},parameter1[31:16]}),
 .cfg_h20(32'sd0),.cfg_h21(32'sd0),.cfg_h22(32'sd1),
 .rsp_valid(core_rv),.rsp_ready(state==CAP_WAIT || state==MAP_WAIT),.rsp_done(),.rsp_opcode(),.rsp_frameid(),.rsp_error(core_error),.error_code(),
 .s_valid(s_valid && state==CAP_WAIT),.s_ready(core_sr),.s_data(s_data),.s_sof(s_sof),.s_eol(s_eol),.s_tag(input_index),.s_frameid(16'd0),
 .aux_valid(aux_valid && state==CAP_WAIT),.aux_ready(core_ar),.aux_data(aux_data),.aux_sof(aux_sof),.aux_eol(aux_eol),.aux_tag(input_index),.aux_frameid(16'd0),
 .m_valid(core_mv),.m_ready(m_ready && state==MAP_WAIT),.m_data(core_data),.m_sof(core_ms),.m_eol(core_me),.m_tag(),.m_frameid(),.m_error(),
 .frames_valid(),.registration_dx(),.registration_dy(),.registration_cost(),.registration_confidence(),.canvas_width(),.canvas_height());
end else begin:unsupported
 assign core_ready=0;assign core_rv=0;assign core_sr=0;assign core_ar=0;assign core_mv=0;assign core_ms=0;assign core_me=0;assign core_data=0;assign core_error=0;
end endgenerate
endmodule
