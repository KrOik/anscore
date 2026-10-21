// Functional pointwise frame adapter. See FUNCTIONAL_IMAGE_ABI.md.
module cip_image_gamma #(parameter DATA_W=24, parameter TAG_W=8)(
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
// LUT staging is double-buffered, synchronously read and never reset.
localparam LOAD_IDLE=0,LOAD_RECEIVE=1,LOAD_RESPONSE=2;
localparam FILL_IDLE=0,FILL_READ=1,FILL_WRITE=2,FILL_COMMIT=3;
reg [1:0] load_state,load_error,fill_state;
reg [TAG_W-1:0] load_tag;
reg [9:0] load_index,fill_index;
reg table_bank,table_loaded,bad_load;
(* ram_style="block", syn_ramstyle="block_ram" *) reg [7:0] table_mem[0:1535];
reg [7:0] table_q;
wire [10:0] table_write_addr=(table_bank?11'd0:11'd768)+load_index;
wire [10:0] table_read_addr=(table_bank?11'd768:11'd0)+fill_index;
wire frame_cmd_ready,frame_rsp_valid;
wire [TAG_W-1:0] frame_rsp_tag;
wire [1:0] frame_rsp_error;
wire core_cfg_ready;
wire coefficient_bad=coeff_addr!={6'd0,load_index} || coeff_data[31:8]!=0;
wire load_config_bad=DATA_W!=24 || cfg_src_width!=0 || cfg_src_height!=0 ||
    cfg_dst_width!=0 || cfg_dst_height!=0 || cfg_param0!=0 || cfg_param1!=0 ||
    cfg_frame_base!=0 || cfg_frame_stride!=0 || cfg_aux_base!=0;
wire specific_bad=DATA_W!=24 || cfg_param0>1 || cfg_param1!=0 || (cfg_param0==1 && !table_loaded);
assign cmd_ready=rst_n && load_state==LOAD_IDLE && frame_cmd_ready;
assign rsp_valid=rst_n && (load_state==LOAD_RESPONSE || frame_rsp_valid);
assign rsp_tag=load_state==LOAD_RESPONSE?load_tag:frame_rsp_tag;
assign rsp_error=load_state==LOAD_RESPONSE?load_error:frame_rsp_error;
assign coeff_ready=rst_n && load_state==LOAD_RECEIVE;
always @(posedge clk)begin
    if(rst_n && clk_en)begin
        if(coeff_valid && coeff_ready)table_mem[table_write_addr]<=coeff_data[7:0];
        if(fill_state==FILL_READ)table_q<=table_mem[table_read_addr];
    end
end
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        load_state<=LOAD_IDLE;load_error<=0;load_tag<=0;load_index<=0;
        table_bank<=0;table_loaded<=0;bad_load<=0;fill_state<=FILL_IDLE;fill_index<=0;
    end else if(clk_en)begin
        case(load_state)
        LOAD_IDLE:if(cmd_valid && cmd_ready && cfg_mode==1)begin
            load_tag<=cmd_tag;load_error<=0;load_index<=0;bad_load<=0;
            if(load_config_bad)begin load_state<=LOAD_RESPONSE;load_error<=2;end
            else load_state<=LOAD_RECEIVE;
        end
        LOAD_RECEIVE:if(coeff_valid && coeff_ready)begin
            if(coefficient_bad)bad_load<=1;
            if(load_index==767)begin
                load_state<=LOAD_RESPONSE;
                if(bad_load || coefficient_bad)load_error<=2;
                else begin table_bank<=!table_bank;table_loaded<=1;end
            end else load_index<=load_index+1;
        end
        LOAD_RESPONSE:if(rsp_ready)load_state<=LOAD_IDLE;
        default:load_state<=LOAD_IDLE;
        endcase
        case(fill_state)
        FILL_IDLE:if(configure)begin
            fill_index<=0;
            fill_state<=param0[0]?FILL_READ:FILL_COMMIT;
        end
        FILL_READ:fill_state<=FILL_WRITE;
        FILL_WRITE:if(core_cfg_ready)begin
            if(fill_index==767)fill_state<=FILL_COMMIT;
            else begin fill_index<=fill_index+1;fill_state<=FILL_READ;end
        end
        FILL_COMMIT:if(core_cfg_ready)fill_state<=FILL_IDLE;
        default:fill_state<=FILL_IDLE;
        endcase
    end
end
wire [1:0] command_error=cfg_mode!=0?2'd1:(common_bad || specific_bad)?2'd2:2'd0;
cip_image_pointwise_frame_ctrl #(.DATA_W(DATA_W),.TAG_W(TAG_W)) control(
    .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cmd_valid(cmd_valid && load_state==LOAD_IDLE && cfg_mode!=1),.cmd_ready(frame_cmd_ready),
    .cmd_tag(cmd_tag),.cmd_error(command_error),.cfg_width(cfg_src_width),.cfg_height(cfg_src_height),
    .cfg_param0(cfg_param0),.cfg_param1(32'd0),.param0(param0),.param1(param1),
    .configure(configure),.configure_ready(configure_ready),
    .rsp_valid(frame_rsp_valid),.rsp_ready(rsp_ready && load_state==LOAD_IDLE),.rsp_tag(frame_rsp_tag),.rsp_error(frame_rsp_error),
    .s_valid(s_valid),.s_sof(s_sof),.s_eol(s_eol),.s_ready(s_ready),
    .kernel_s_valid(ksv),.kernel_s_sof(kss),.kernel_s_eol(kse),.kernel_s_ready(ksr),
    .kernel_m_data(kmd),.kernel_m_valid(kmv),.kernel_m_sof(kms),.kernel_m_eol(kme),.kernel_m_ready(kmr),
    .m_data(m_data),.m_valid(m_valid),.m_sof(m_sof),.m_eol(m_eol),.m_ready(m_ready));
generate if(DATA_W==24)begin:rgb
    img_isp_gamma_lut core(
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.s_data(s_data),.s_valid(ksv),
        .s_sof(kss),.s_eol(kse),.s_ready(ksr),
        .cfg_we(fill_state==FILL_WRITE),.cfg_channel(fill_index[9:8]),
        .cfg_addr(fill_index[7:0]),.cfg_value(table_q),
        .cfg_commit(configure && fill_state==FILL_COMMIT),.cfg_enable(param0[0]),
        .cfg_ready(core_cfg_ready),.cfg_pending(),.cfg_error(),.cfg_lut_complete(),.active_enable(),
        .m_data(kmd),.m_valid(kmv),.m_sof(kms),.m_eol(kme),.m_ready(kmr));
assign configure_ready=fill_state==FILL_COMMIT && core_cfg_ready;
end else begin:unsupported_width
    assign core_cfg_ready=0;assign configure_ready=0;assign ksr=0;assign kmv=0;assign kmd=0;assign kms=0;assign kme=0;
end endgenerate
endmodule
