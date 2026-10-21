// Functional internally buffered motion-adaptive temporal denoiser; see FUNCTIONAL_IMAGE_ABI.md.
module cip_image_temporal_denoise #(parameter DATA_W=24, parameter TAG_W=8, parameter MAX_WIDTH=64, parameter MAX_HEIGHT=64)(
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
localparam SUPPORTED=DATA_W>=1 && DATA_W<=32 && MAX_WIDTH>=1 && MAX_WIDTH<=65535 &&
    MAX_HEIGHT>=1 && MAX_HEIGHT<=65535 && (64'd1*MAX_WIDTH*MAX_HEIGHT)<=1048576;
reg [1:0] state;
reg [15:0] width,height;
reg fresh;
reg [8:0] weight;
reg [DATA_W-1:0] threshold;
wire cfg_ready,core_sr,core_mv,core_ms,core_me,core_rv;
wire [DATA_W-1:0] core_data;
wire [7:0] core_error;
wire bad_config=!SUPPORTED || cfg_src_width==0 || cfg_src_height==0 || cfg_src_width>MAX_WIDTH || cfg_src_height>MAX_HEIGHT ||
    cfg_dst_width!=cfg_src_width || cfg_dst_height!=cfg_src_height || cfg_param0>256 ||
    (cfg_param1 >> DATA_W)!=0 || cfg_frame_base!=0 || cfg_frame_stride!=0 || cfg_aux_base!=0;
assign cmd_ready=rst_n && state==IDLE;
assign rsp_valid=rst_n && state==RESPONSE;
assign s_ready=rst_n && state==RUN && core_sr;
assign m_valid=rst_n && state==RUN && core_mv;
assign m_data=core_data;
assign m_sof=m_valid && core_ms;assign m_eol=m_valid && core_me;
assign coeff_ready=0;assign aux_ready=0;assign mem_req_valid=0;assign mem_req_write=0;
assign mem_req_addr=0;assign mem_req_wdata=0;assign mem_req_wstrb=0;assign mem_rsp_ready=0;
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin state<=IDLE;width<=0;height<=0;fresh<=0;weight<=0;threshold<=0;rsp_tag<=0;rsp_error<=0;end
    else if(clk_en)begin
        case(state)
        IDLE:if(cmd_valid && cmd_ready)begin
            rsp_tag<=cmd_tag;rsp_error<=0;
            if(cfg_mode>1)begin state<=RESPONSE;rsp_error<=1;end
            else if(bad_config)begin state<=RESPONSE;rsp_error<=2;end
            else begin state<=START;width<=cfg_src_width;height<=cfg_src_height;fresh<=cfg_mode[0];weight<=cfg_param0[8:0];threshold<=cfg_param1;end
        end
        START:if(cfg_ready)state<=RUN;
        RUN:begin
            if(core_rv)begin
                rsp_error<=core_error==0?2'd0:((core_error & 8'hf9)!=0?2'd3:2'd2);
                state<=RESPONSE;
            end
        end
        RESPONSE:if(rsp_ready)state<=IDLE;
        default:state<=IDLE;
        endcase
    end
end
generate if(SUPPORTED)begin:enabled
    img_filter_temporal_denoise #(.PIXEL_W(DATA_W),.MAX_WIDTH(MAX_WIDTH),.MAX_HEIGHT(MAX_HEIGHT),.INTERNAL_HISTORY(1)) core(
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
        .cmd_valid(state==START),.cmd_ready(cfg_ready),.cmd_tag(8'd0),
        .cfg_width(width),.cfg_height(height),.cfg_current_weight_q8(weight),
        .cfg_motion_threshold(threshold),.cfg_history_valid(!fresh),
        .rsp_valid(core_rv),.rsp_ready(state==RUN),.rsp_error(core_error),.rsp_tag(),
        .s_data(s_data),.s_valid(s_valid && state==RUN),.s_sof(s_sof),.s_eol(s_eol),.s_ready(core_sr),
        .s_history_data({DATA_W{1'b0}}),.s_history_valid(1'b0),.s_history_sof(1'b0),.s_history_eol(1'b0),.s_history_ready(),
        .m_data(core_data),.m_valid(core_mv),.m_sof(core_ms),.m_eol(core_me),.m_ready(m_ready && state==RUN));
end else begin:unsupported
    assign cfg_ready=0;assign core_sr=0;assign core_mv=0;assign core_ms=0;assign core_me=0;
    assign core_data=0;assign core_rv=0;assign core_error=0;
end endgenerate
endmodule
