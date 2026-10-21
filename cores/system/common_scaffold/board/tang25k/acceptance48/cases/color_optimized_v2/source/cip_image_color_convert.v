// Functional pointwise frame adapter. See FUNCTIONAL_IMAGE_ABI.md.
module cip_image_color_convert #(parameter DATA_W=24, parameter TAG_W=8)(
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
assign mem_req_valid=0;assign mem_req_write=0;assign mem_req_addr=0;
assign mem_req_wdata=0;assign mem_req_wstrb=0;assign mem_rsp_ready=0;
assign coeff_ready=0;assign aux_ready=0;
wire configure,configure_ready,ksv,kss,kse,ksr,kmv,kms,kme,kmr;
wire [DATA_W-1:0] kmd;
wire [31:0] param0,param1;
wire common_bad=DATA_W<1 || DATA_W>32 || cfg_src_width==0 || cfg_src_height==0 ||
    cfg_dst_width!=cfg_src_width || cfg_dst_height!=cfg_src_height ||
    cfg_frame_base!=0 || cfg_frame_stride!=0 || cfg_aux_base!=0;
wire specific_bad=DATA_W!=24 || cfg_param0!=0 || cfg_param1!=0;
wire [1:0] command_error=cfg_mode>1?2'd1:(common_bad || specific_bad)?2'd2:2'd0;
cip_image_pointwise_frame_ctrl #(.DATA_W(DATA_W),.TAG_W(TAG_W)) control(
    .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cmd_valid(cmd_valid),.cmd_ready(cmd_ready),
    .cmd_tag(cmd_tag),.cmd_error(command_error),.cfg_width(cfg_src_width),.cfg_height(cfg_src_height),
    .cfg_param0({31'd0,cfg_mode[0]}),.cfg_param1(32'd0),.param0(param0),.param1(param1),
    .configure(configure),.configure_ready(configure_ready),
    .rsp_valid(rsp_valid),.rsp_ready(rsp_ready),.rsp_tag(rsp_tag),.rsp_error(rsp_error),
    .s_valid(s_valid),.s_sof(s_sof),.s_eol(s_eol),.s_ready(s_ready),
    .kernel_s_valid(ksv),.kernel_s_sof(kss),.kernel_s_eol(kse),.kernel_s_ready(ksr),
    .kernel_m_data(kmd),.kernel_m_valid(kmv),.kernel_m_sof(kms),.kernel_m_eol(kme),.kernel_m_ready(kmr),
    .m_data(m_data),.m_valid(m_valid),.m_sof(m_sof),.m_eol(m_eol),.m_ready(m_ready));
generate if(DATA_W==24)begin:rgb
    img_isp_colorspace core(
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.s_data(s_data),.s_valid(ksv),
        .s_sof(kss),.s_eol(kse),.s_ready(ksr),
        .cfg_we(configure),.cfg_commit(configure),.cfg_yuv_to_rgb(param0[0]),
        .cfg_ready(configure_ready),.cfg_pending(),
        .m_data(kmd),.m_valid(kmv),.m_sof(kms),.m_eol(kme),.m_ready(kmr));
end else begin:unsupported_width
    assign configure_ready=0;assign ksr=0;assign kmv=0;assign kmd=0;assign kms=0;assign kme=0;
end endgenerate
endmodule
