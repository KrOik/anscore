// Functional gray8 histogram/HE frame adapter; see FUNCTIONAL_IMAGE_ABI.md.
module cip_image_histogram #(parameter DATA_W=24, parameter TAG_W=8, parameter MAX_WIDTH=64, parameter MAX_HEIGHT=64)(
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
localparam HISTOGRAM=1;
localparam WORDS=HISTOGRAM?(32+DATA_W-1)/DATA_W:1;
localparam IDLE=0,START=1,RUN=2,RESPONSE=3;
localparam SUPPORTED=DATA_W>=8 && DATA_W<=32 && MAX_WIDTH>=1 && MAX_WIDTH<=65535 &&
    MAX_HEIGHT>=1 && MAX_HEIGHT<=65535 && (64'd1*MAX_WIDTH*MAX_HEIGHT)<=1048576;
reg [1:0] state;
reg [15:0] width,height;
reg input_error,packet_valid,packet_sof,packet_eol;
reg [31:0] packet_data;
integer word_index;
wire cfg_ready,core_sr,core_mv,core_ms,core_me,core_rv;
wire [31:0] core_data;
wire [1:0] core_error;
wire core_ready=state==RUN && !packet_valid;
wire bad_config=!SUPPORTED || cfg_src_width==0 || cfg_src_height==0 || cfg_src_width>MAX_WIDTH || cfg_src_height>MAX_HEIGHT ||
    (HISTOGRAM?(cfg_dst_width!=256 || cfg_dst_height!=1):(cfg_dst_width!=cfg_src_width || cfg_dst_height!=cfg_src_height)) ||
    cfg_param0!=0 || cfg_param1!=0 || cfg_frame_base!=0 || cfg_frame_stride!=0 || cfg_aux_base!=0;
assign cmd_ready=rst_n && state==IDLE;
assign rsp_valid=rst_n && state==RESPONSE;
assign s_ready=rst_n && state==RUN && core_sr;
assign m_valid=rst_n && state==RUN && packet_valid;
assign m_data=packet_data >> (word_index*DATA_W);
assign m_sof=m_valid && packet_sof && word_index==0;
assign m_eol=m_valid && packet_eol && word_index==WORDS-1;
assign coeff_ready=0;assign aux_ready=0;assign mem_req_valid=0;assign mem_req_write=0;
assign mem_req_addr=0;assign mem_req_wdata=0;assign mem_req_wstrb=0;assign mem_rsp_ready=0;
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        state<=IDLE;width<=0;height<=0;rsp_tag<=0;rsp_error<=0;input_error<=0;
        packet_valid<=0;packet_data<=0;packet_sof<=0;packet_eol<=0;word_index<=0;
    end else if(clk_en)begin
        if(s_valid && s_ready && (s_data >> 8)!=0)input_error<=1;
        if(core_mv && core_ready)begin
            packet_valid<=1;packet_data<=core_data;packet_sof<=core_ms;packet_eol<=core_me;word_index<=0;
        end
        if(m_valid && m_ready)begin
            if(word_index==WORDS-1)begin packet_valid<=0;word_index<=0;end
            else word_index<=word_index+1;
        end
        case(state)
        IDLE:if(cmd_valid)begin
            rsp_tag<=cmd_tag;rsp_error<=0;input_error<=0;packet_valid<=0;
            if(cfg_mode!=0)begin state<=RESPONSE;rsp_error<=1;end
            else if(bad_config)begin state<=RESPONSE;rsp_error<=2;end
            else begin state<=START;width<=cfg_src_width;height<=cfg_src_height;end
        end
        START:if(cfg_ready)state<=RUN;
        RUN:if(core_rv && !packet_valid)begin
            rsp_error<=core_error==3?2'd3:((core_error!=0 || input_error)?2'd2:2'd0);
            state<=RESPONSE;
        end
        RESPONSE:if(rsp_ready)state<=IDLE;
        default:begin state<=RESPONSE;rsp_error<=3;end
        endcase
    end
end
generate if(SUPPORTED)begin:enabled
    cip_image_histogram_frame #(.TAG_W(TAG_W),.MAX_WIDTH(MAX_WIDTH),.MAX_HEIGHT(MAX_HEIGHT)) core(
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
        .cmd_valid(state==START),.cmd_ready(cfg_ready),.cmd_tag(rsp_tag),
        .cfg_operation(1'b0),.cfg_width(width),.cfg_height(height),
        .rsp_valid(core_rv),.rsp_ready(state==RUN && !packet_valid),.rsp_error(core_error),.rsp_tag(),
        .s_data(s_data[7:0]),.s_valid(s_valid && state==RUN),.s_sof(s_sof),.s_eol(s_eol),.s_ready(core_sr),
        .m_data(core_data),.m_valid(core_mv),.m_sof(core_ms),.m_eol(core_me),.m_last(),.m_ready(core_ready));
end else begin:unsupported
    assign cfg_ready=0;assign core_sr=0;assign core_mv=0;assign core_ms=0;assign core_me=0;
    assign core_data=0;assign core_rv=0;assign core_error=0;
end endgenerate
endmodule
