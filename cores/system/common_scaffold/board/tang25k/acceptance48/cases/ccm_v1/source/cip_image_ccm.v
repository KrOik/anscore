// Functional pointwise frame adapter. See FUNCTIONAL_IMAGE_ABI.md.
module cip_image_ccm #(parameter DATA_W=24, parameter TAG_W=8)(
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
assign aux_ready=0;
wire configure,configure_ready,ksv,kss,kse,ksr,kmv,kms,kme,kmr;
wire [DATA_W-1:0] kmd;
wire [31:0] param0,param1;
wire common_bad=DATA_W<1 || DATA_W>32 || cfg_src_width==0 || cfg_src_height==0 ||
    cfg_dst_width!=cfg_src_width || cfg_dst_height!=cfg_src_height ||
    cfg_frame_base!=0 || cfg_frame_stride!=0 || cfg_aux_base!=0;
wire specific_bad=DATA_W!=24 || cfg_param0!=0 || cfg_param1!=0;
localparam LOAD_IDLE=0,LOAD_RECEIVE=1,LOAD_APPLY=2,LOAD_RESPONSE=3;
reg [1:0] load_state,load_error;
reg [TAG_W-1:0] load_tag;
reg [3:0] received,apply_index;
reg [11:0] seen;
reg bad_load;
reg signed [15:0] staging[0:11];
wire frame_cmd_ready,frame_rsp_valid;
wire [TAG_W-1:0] frame_rsp_tag;
wire [1:0] frame_rsp_error;
wire core_cfg_ready;
wire coefficient_bad=coeff_addr>=12 || coeff_data!={{16{coeff_data[15]}},coeff_data[15:0]};
wire duplicate=coeff_addr<12 && seen[coeff_addr];
wire load_config_bad=DATA_W!=24 || cfg_src_width!=0 || cfg_src_height!=0 ||
    cfg_dst_width!=0 || cfg_dst_height!=0 || cfg_param0!=0 || cfg_param1!=0 ||
    cfg_frame_base!=0 || cfg_frame_stride!=0 || cfg_aux_base!=0;
assign cmd_ready=rst_n && load_state==LOAD_IDLE && frame_cmd_ready;
assign rsp_valid=rst_n && (load_state==LOAD_RESPONSE || frame_rsp_valid);
assign rsp_tag=load_state==LOAD_RESPONSE?load_tag:frame_rsp_tag;
assign rsp_error=load_state==LOAD_RESPONSE?load_error:frame_rsp_error;
assign coeff_ready=rst_n && load_state==LOAD_RECEIVE;
integer i;
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        load_state<=LOAD_IDLE;load_error<=0;load_tag<=0;received<=0;apply_index<=0;seen<=0;bad_load<=0;
        for(i=0;i<12;i=i+1)staging[i]<=0;
    end else if(clk_en)begin
        case(load_state)
        LOAD_IDLE:if(cmd_valid && cmd_ready && cfg_mode==1)begin
            load_tag<=cmd_tag;load_error<=0;received<=0;apply_index<=0;seen<=0;bad_load<=0;
            if(load_config_bad)begin load_state<=LOAD_RESPONSE;load_error<=2;end
            else load_state<=LOAD_RECEIVE;
        end
        LOAD_RECEIVE:if(coeff_valid && coeff_ready)begin
            if(coefficient_bad || duplicate)bad_load<=1;
            if(coeff_addr<12)begin seen[coeff_addr]<=1;staging[coeff_addr]<=coeff_data[15:0];end
            received<=received+1;
            if(received==11)begin
                if(bad_load || coefficient_bad || duplicate ||
                   ((seen | (12'b1<<coeff_addr))!=12'hfff))begin load_state<=LOAD_RESPONSE;load_error<=2;end
                else begin load_state<=LOAD_APPLY;apply_index<=0;end
            end
        end
        LOAD_APPLY:if(core_cfg_ready)begin
            if(apply_index==11)load_state<=LOAD_RESPONSE;
            else apply_index<=apply_index+1;
        end
        LOAD_RESPONSE:if(rsp_ready)load_state<=LOAD_IDLE;
        default:load_state<=LOAD_IDLE;
        endcase
    end
end
wire [1:0] command_error=cfg_mode!=0?2'd1:(common_bad || specific_bad)?2'd2:2'd0;
cip_image_pointwise_frame_ctrl #(.DATA_W(DATA_W),.TAG_W(TAG_W)) control(
    .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cmd_valid(cmd_valid && load_state==LOAD_IDLE && cfg_mode!=1),.cmd_ready(frame_cmd_ready),
    .cmd_tag(cmd_tag),.cmd_error(command_error),.cfg_width(cfg_src_width),.cfg_height(cfg_src_height),
    .cfg_param0(32'd0),.cfg_param1(32'd0),.param0(param0),.param1(param1),
    .configure(configure),.configure_ready(configure_ready),
    .rsp_valid(frame_rsp_valid),.rsp_ready(rsp_ready && load_state==LOAD_IDLE),.rsp_tag(frame_rsp_tag),.rsp_error(frame_rsp_error),
    .s_valid(s_valid),.s_sof(s_sof),.s_eol(s_eol),.s_ready(s_ready),
    .kernel_s_valid(ksv),.kernel_s_sof(kss),.kernel_s_eol(kse),.kernel_s_ready(ksr),
    .kernel_m_data(kmd),.kernel_m_valid(kmv),.kernel_m_sof(kms),.kernel_m_eol(kme),.kernel_m_ready(kmr),
    .m_data(m_data),.m_valid(m_valid),.m_sof(m_sof),.m_eol(m_eol),.m_ready(m_ready));
generate if(DATA_W==24)begin:rgb
    img_isp_ccm core(
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.s_data(s_data),.s_valid(ksv),
        .s_sof(kss),.s_eol(kse),.s_ready(ksr),
        .cfg_we(load_state==LOAD_APPLY),.cfg_commit(configure),
        .cfg_index(apply_index),.cfg_value(staging[apply_index]),
        .cfg_ready(core_cfg_ready),.cfg_pending(),.cfg_error(),
        .m_data(kmd),.m_valid(kmv),.m_sof(kms),.m_eol(kme),.m_ready(kmr));
assign configure_ready=core_cfg_ready;
end else begin:unsupported_width
    assign core_cfg_ready=0;assign configure_ready=0;assign ksr=0;assign kmv=0;assign kmd=0;assign kms=0;assign kme=0;
end endgenerate
endmodule
