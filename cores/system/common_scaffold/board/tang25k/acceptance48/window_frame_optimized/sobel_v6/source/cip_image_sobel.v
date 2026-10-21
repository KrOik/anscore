// Functional cropped grayscale edge detector; mode0 display, mode1 lossless signed words.
// See FUNCTIONAL_IMAGE_ABI.md. DATA_W is one unsigned gray sample, not packed RGB.
module cip_image_sobel #(parameter DATA_W=24, parameter TAG_W=8, parameter MAX_WIDTH=1920, MAG_SHIFT=0)(
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
localparam GRAD_W=DATA_W+4;
localparam WORDS=(GRAD_W+DATA_W-1)/DATA_W;
localparam FULL_BEATS=3*WORDS;
localparam BEAT_W=FULL_BEATS>1?$clog2(FULL_BEATS):1;
reg full_mode,holding,pixel_sof,pixel_eol;
reg [BEAT_W-1:0] beat;
reg [DATA_W-1:0] display;
reg signed [GRAD_W-1:0] gx,gy;
reg [GRAD_W-1:0] magnitude;
wire signed [GRAD_W-1:0] core_gx,core_gy;
wire [GRAD_W-1:0] core_magnitude;
wire last_word=!full_mode || beat==FULL_BEATS-1;
function [DATA_W-1:0] signed_word;
    input signed [GRAD_W-1:0] value;
    input integer index;
    begin signed_word=value>>>(index*DATA_W);end
endfunction
function [DATA_W-1:0] unsigned_word;
    input [GRAD_W-1:0] value;
    input integer index;
    begin unsigned_word=value>>(index*DATA_W);end
endfunction
localparam SUPPORTED=DATA_W>=1 && DATA_W<=32 &&
    MAX_WIDTH>=3 && MAX_WIDTH<=65535 && MAG_SHIFT>=0;
reg [1:0] state;
reg [15:0] width,height;
wire cfg_ready,core_sr,core_mv,core_ms,core_me,core_rv;
wire [DATA_W-1:0] core_data;
wire [3:0] core_error;
wire bad_config=!SUPPORTED || cfg_src_width<3 || cfg_src_height<3 || cfg_src_width>MAX_WIDTH ||
    cfg_dst_width!=cfg_src_width-2 || cfg_dst_height!=cfg_src_height-2 ||
    cfg_param0!=0 || cfg_param1!=0 || cfg_frame_base!=0 || cfg_frame_stride!=0 || cfg_aux_base!=0;
assign cmd_ready=rst_n && state==IDLE;
assign rsp_valid=rst_n && state==RESPONSE;
assign s_ready=rst_n && state==RUN && core_sr;
assign m_valid=rst_n && state==RUN && holding;
assign m_data=!full_mode?display:beat<WORDS?signed_word(gx,beat):
    beat<2*WORDS?signed_word(gy,beat-WORDS):unsigned_word(magnitude,beat-2*WORDS);
assign m_sof=m_valid && pixel_sof && beat==0;
assign m_eol=m_valid && pixel_eol && last_word;
assign coeff_ready=0;assign aux_ready=0;assign mem_req_valid=0;assign mem_req_write=0;
assign mem_req_addr=0;assign mem_req_wdata=0;assign mem_req_wstrb=0;assign mem_rsp_ready=0;
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin state<=IDLE;width<=0;height<=0;rsp_tag<=0;rsp_error<=0;full_mode<=0;holding<=0;beat<=0;display<=0;gx<=0;gy<=0;magnitude<=0;pixel_sof<=0;pixel_eol<=0;end
    else if(clk_en)begin
        case(state)
        IDLE:if(cmd_valid && cmd_ready)begin
            rsp_tag<=cmd_tag;rsp_error<=0;
            if(cfg_mode>1)begin state<=RESPONSE;rsp_error<=1;end
            else if(bad_config)begin state<=RESPONSE;rsp_error<=2;end
            else begin state<=START;width<=cfg_src_width;height<=cfg_src_height;full_mode<=cfg_mode[0];end
        end
        START:if(cfg_ready)state<=RUN;
        RUN:begin
            if(m_valid && m_ready)begin
                if(last_word)begin holding<=0;beat<=0;end else beat<=beat+1;
            end
            if(core_mv && !holding)begin
                holding<=1;beat<=0;display<=core_data;gx<=core_gx;gy<=core_gy;magnitude<=core_magnitude;
                pixel_sof<=core_ms;pixel_eol<=core_me;
            end
            if(core_rv && !holding)begin
                if(core_error>2)rsp_error<=3;
                else rsp_error<=(core_error!=0)?2'd2:2'd0;
                state<=RESPONSE;
            end
        end
        RESPONSE:if(rsp_ready)state<=IDLE;
        default:state<=IDLE;
        endcase
    end
end
generate if(SUPPORTED)begin:enabled
    cip_image_window_filter_frame #(.PIXEL_W(DATA_W),.MAX_WIDTH(MAX_WIDTH),.TAG_W(TAG_W),.OP(3),.EDGE_SHIFT(MAG_SHIFT)) core(
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
        .cfg_valid(state==START),.cfg_ready(cfg_ready),.cfg_width(width),.cfg_height(height),.cfg_tag(rsp_tag),
        .rsp_valid(core_rv),.rsp_ready(state==RUN && !holding),.rsp_error(core_error),.rsp_tag(),.rsp_pixels(),.out_width(),.out_height(),
        .s_data(s_data),.s_valid(s_valid && state==RUN),.s_sof(s_sof),.s_eol(s_eol),.s_ready(core_sr),
        .m_data(core_data),.m_aux0(core_gx),.m_aux1(core_gy),.m_magnitude(core_magnitude),.m_valid(core_mv),.m_sof(core_ms),.m_eol(core_me),.m_eof(),.m_tag(),.m_ready(!holding && state==RUN));
end else begin:unsupported
    assign cfg_ready=0;assign core_sr=0;assign core_mv=0;assign core_ms=0;assign core_me=0;
    assign core_data=0;assign core_gx=0;assign core_gy=0;assign core_magnitude=0;assign core_rv=0;assign core_error=0;
end endgenerate
endmodule
