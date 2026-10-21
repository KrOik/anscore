// Functional fixed/Otsu/adaptive frame dispatcher; see FUNCTIONAL_IMAGE_ABI.md.
module cip_image_threshold #(parameter DATA_W=24, parameter TAG_W=8, parameter OTSU_WIDTH=32, OTSU_HEIGHT=24,
    parameter OTSU_COUNT_W=16, ADAPTIVE_MAX_WIDTH=1920)(
    input wire clk, rst_n, clk_en,
    input wire cmd_valid,
    output wire cmd_ready,
    input wire [TAG_W-1:0] cmd_tag,
    output wire rsp_valid,
    input wire rsp_ready,
    output wire [TAG_W-1:0] rsp_tag,
    output wire [1:0] rsp_error,
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
reg [1:0] state,error;
reg [3:0] mode;
reg [TAG_W-1:0] tag;
reg [15:0] sw,sh,dw,dh;
reg [31:0] param0,param1;
wire [3:0] core_cmd_ready,core_sr,core_mv,core_ms,core_me,core_rv;
wire [DATA_W-1:0] core_data[0:3];
wire [1:0] core_error[0:3];
wire start_fire=state==START && core_cmd_ready[mode];
assign cmd_ready=rst_n && state==IDLE;
assign rsp_valid=rst_n && state==RESPONSE;
assign rsp_tag=tag;
assign rsp_error=error;
assign s_ready=rst_n && state==RUN && core_sr[mode];
assign m_valid=rst_n && state==RUN && core_mv[mode];
assign m_data=state==RUN?core_data[mode]:{DATA_W{1'b0}};
assign m_sof=m_valid && core_ms[mode];
assign m_eol=m_valid && core_me[mode];
assign mem_req_valid=0;assign mem_req_write=0;assign mem_req_addr=0;
assign mem_req_wdata=0;assign mem_req_wstrb=0;assign mem_rsp_ready=0;
assign coeff_ready=0;assign aux_ready=0;
wire common_bad=DATA_W<1 || DATA_W>32 || cfg_src_width==0 || cfg_src_height==0 ||
    cfg_param1>1 || cfg_frame_base!=0 || cfg_frame_stride!=0 || cfg_aux_base!=0;
wire fixed_bad=cfg_dst_width!=cfg_src_width || cfg_dst_height!=cfg_src_height ||
    (cfg_param0 >> DATA_W)!=0;
wire otsu_bad=DATA_W!=8 || cfg_src_width!=OTSU_WIDTH || cfg_src_height!=OTSU_HEIGHT ||
    cfg_dst_width!=cfg_src_width || cfg_dst_height!=cfg_src_height || cfg_param0!=0;
wire adaptive_bad=DATA_W>16 || ADAPTIVE_MAX_WIDTH<3 || ADAPTIVE_MAX_WIDTH>65535 ||
    cfg_src_width<3 || cfg_src_height<3 || cfg_src_width>ADAPTIVE_MAX_WIDTH ||
    cfg_dst_width!=cfg_src_width-2 || cfg_dst_height!=cfg_src_height-2 ||
    $signed(cfg_param0)<-(64'sd1<<DATA_W) || $signed(cfg_param0)>((64'sd1<<DATA_W)-1);
always @(posedge clk or negedge rst_n) begin
    if(!rst_n)begin state<=IDLE;mode<=0;tag<=0;error<=0;sw<=0;sh<=0;dw<=0;dh<=0;param0<=0;param1<=0;end
    else if(clk_en)begin
        case(state)
        IDLE:if(cmd_valid && cmd_ready)begin
            tag<=cmd_tag;error<=0;
            if(cfg_mode>3)begin state<=RESPONSE;error<=1;end
            else if(common_bad || (cfg_mode==0 && fixed_bad) ||
                (cfg_mode==1 && otsu_bad) || (cfg_mode>=2 && adaptive_bad))begin state<=RESPONSE;error<=2;end
            else begin
                mode<=cfg_mode;sw<=cfg_src_width;sh<=cfg_src_height;dw<=cfg_dst_width;dh<=cfg_dst_height;
                param0<=cfg_param0;param1<=cfg_param1;state<=START;
            end
        end
        START:if(start_fire)state<=RUN;
        RUN:if(core_rv[mode])begin state<=RESPONSE;error<=core_error[mode];end
        RESPONSE:if(rsp_ready)state<=IDLE;
        default:state<=IDLE;
        endcase
    end
end
cip_image_threshold_fixed #(.DATA_W(DATA_W),.TAG_W(TAG_W)) fixed_core(
    .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cmd_valid(state==START && mode==0),.cmd_ready(core_cmd_ready[0]),
    .cmd_tag(tag),.rsp_valid(core_rv[0]),.rsp_ready(state==RUN && mode==0),.rsp_tag(),.rsp_error(core_error[0]),
    .cfg_src_width(sw),.cfg_src_height(sh),.cfg_dst_width(dw),.cfg_dst_height(dh),.cfg_mode(4'd0),
    .cfg_param0(param0),.cfg_param1(param1),.cfg_frame_base(32'd0),.cfg_frame_stride(32'd0),.cfg_aux_base(32'd0),
    .coeff_valid(1'b0),.coeff_ready(),.coeff_addr(16'd0),.coeff_data(32'd0),
    .aux_data({DATA_W{1'b0}}),.aux_valid(1'b0),.aux_sof(1'b0),.aux_eol(1'b0),.aux_ready(),
    .mem_req_valid(),.mem_req_write(),.mem_req_addr(),.mem_req_wdata(),.mem_req_wstrb(),
    .mem_req_ready(1'b0),.mem_rsp_valid(1'b0),.mem_rsp_rdata(32'd0),.mem_rsp_error(1'b0),.mem_rsp_ready(),
    .s_sof(s_sof),.s_eol(s_eol),.m_sof(core_ms[0]),.m_eol(core_me[0]),
    .s_data(s_data),.s_valid(s_valid && state==RUN && mode==0),.s_ready(core_sr[0]),
    .m_data(core_data[0]),.m_valid(core_mv[0]),.m_ready(m_ready && state==RUN && mode==0));
generate if(DATA_W==8)begin:otsu_enabled
    wire done_error;wire [7:0] done_code;
    img_hist_otsu_frame #(.FRAME_WIDTH(OTSU_WIDTH),.FRAME_HEIGHT(OTSU_HEIGHT),
        .COUNT_WIDTH(OTSU_COUNT_W),.TAG_WIDTH(TAG_W)) core(
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.start_valid(state==START && mode==1),
        .start_ready(core_cmd_ready[1]),.start_tag(tag),.start_invert(param1[0]),
        .s_valid(s_valid && state==RUN && mode==1),.s_ready(core_sr[1]),.s_gray(s_data),.s_sof(s_sof),.s_eol(s_eol),
        .m_valid(core_mv[1]),.m_ready(m_ready && state==RUN && mode==1),.m_gray(core_data[1]),
        .m_sof(core_ms[1]),.m_eol(core_me[1]),.m_last(),.m_tag(),
        .done_valid(core_rv[1]),.done_ready(state==RUN && mode==1),.done_error(done_error),
        .done_error_code(done_code),.done_threshold(),.done_count(),.done_tag(),.busy());
    assign core_error[1]=!done_error?2'd0:((done_code==1 || done_code==2 || done_code==4)?2'd2:2'd3);
end else begin:otsu_disabled
    assign core_cmd_ready[1]=0;assign core_sr[1]=0;assign core_mv[1]=0;assign core_ms[1]=0;assign core_me[1]=0;
    assign core_data[1]=0;assign core_rv[1]=0;assign core_error[1]=2;
end
genvar g;
for(g=0;g<2;g=g+1)begin:adaptive
    localparam INDEX=g+2;
    localparam GAUSS=g;
    if(DATA_W>=1 && DATA_W<=16)begin:enabled
        wire [3:0] done_error;
        img_adaptive_threshold_frame #(.PIXEL_W(DATA_W),.MAX_WIDTH(ADAPTIVE_MAX_WIDTH),.TAG_W(TAG_W),.GAUSSIAN(GAUSS)) core(
            .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cfg_valid(state==START && mode==INDEX),.cfg_ready(core_cmd_ready[INDEX]),
            .cfg_width(sw),.cfg_height(sh),.cfg_tag(tag),.cfg_offset(param0[DATA_W:0]),.cfg_invert(param1[0]),
            .s_data(s_data),.s_valid(s_valid && state==RUN && mode==INDEX),.s_sof(s_sof),.s_eol(s_eol),.s_ready(core_sr[INDEX]),
            .m_data(core_data[INDEX]),.m_valid(core_mv[INDEX]),.m_sof(core_ms[INDEX]),.m_eol(core_me[INDEX]),.m_eof(),.m_tag(),
            .m_ready(m_ready && state==RUN && mode==INDEX),.rsp_valid(core_rv[INDEX]),.rsp_ready(state==RUN && mode==INDEX),
            .rsp_error(done_error),.rsp_tag(),.rsp_pixels(),.out_width(),.out_height());
        assign core_error[INDEX]=done_error==0?2'd0:((done_error==1 || done_error==2)?2'd2:2'd3);
    end else begin:disabled
        assign core_cmd_ready[INDEX]=0;assign core_sr[INDEX]=0;assign core_mv[INDEX]=0;assign core_ms[INDEX]=0;assign core_me[INDEX]=0;
        assign core_data[INDEX]=0;assign core_rv[INDEX]=0;assign core_error[INDEX]=2;
    end
end
endgenerate
endmodule
