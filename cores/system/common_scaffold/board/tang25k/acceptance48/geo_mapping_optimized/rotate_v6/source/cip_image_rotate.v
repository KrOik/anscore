// Functional right-angle and centered arbitrary-angle rotation adapter; see FUNCTIONAL_IMAGE_ABI.md.
module cip_image_rotate #(parameter DATA_W=24, parameter TAG_W=8, parameter MAX_WIDTH=64, parameter MAX_HEIGHT=64, parameter PIXEL_W=8)(
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
reg [15:0] width,height,dst_width,dst_height;
reg angle_operation,bilinear;
reg signed [31:0] cosine,sine;
localparam ANGLE_SUPPORTED=PIXEL_W>=1 && PIXEL_W<=16 && DATA_W%(PIXEL_W>0?PIXEL_W:1)==0;
reg [2:0] operation;

wire old_cr,old_sr,old_mv,old_ms,old_me,old_rv;
wire angle_cr,angle_sr,angle_mv,angle_ms,angle_me,angle_rv;
wire [DATA_W-1:0] old_data,angle_data;
wire [1:0] old_error,angle_error;
wire cfg_ready=angle_operation?angle_cr:old_cr;
wire core_sr=angle_operation?angle_sr:old_sr;
wire core_mv=angle_operation?angle_mv:old_mv;
wire core_ms=angle_operation?angle_ms:old_ms;
wire core_me=angle_operation?angle_me:old_me;
wire core_rv=angle_operation?angle_rv:old_rv;
wire [DATA_W-1:0] core_data=angle_operation?angle_data:old_data;
wire [1:0] core_error=angle_operation?angle_error:old_error;
wire bad_config=!SUPPORTED || cfg_src_width==0 || cfg_src_height==0 || cfg_src_width>MAX_WIDTH || cfg_src_height>MAX_HEIGHT ||
    (cfg_mode<4 && (cfg_dst_width!=(cfg_mode[0]?cfg_src_height:cfg_src_width) || cfg_dst_height!=(cfg_mode[0]?cfg_src_width:cfg_src_height) || cfg_param0!=0 || cfg_param1!=0)) ||
    (cfg_mode>=4 && (!ANGLE_SUPPORTED || cfg_dst_width==0 || cfg_dst_height==0)) || cfg_frame_base!=0 || cfg_frame_stride!=0 || cfg_aux_base!=0;
assign cmd_ready=rst_n && state==IDLE;
assign rsp_valid=rst_n && state==RESPONSE;
assign s_ready=rst_n && state==RUN && core_sr;
assign m_valid=rst_n && state==RUN && core_mv;
assign m_data=core_data;
assign m_sof=m_valid && core_ms;assign m_eol=m_valid && core_me;
assign coeff_ready=0;assign aux_ready=0;assign mem_req_valid=0;assign mem_req_write=0;
assign mem_req_addr=0;assign mem_req_wdata=0;assign mem_req_wstrb=0;assign mem_rsp_ready=0;
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin state<=IDLE;width<=0;height<=0;dst_width<=0;dst_height<=0;angle_operation<=0;bilinear<=0;cosine<=0;sine<=0;operation<=0;rsp_tag<=0;rsp_error<=0;end
    else if(clk_en)begin
        case(state)
        IDLE:if(cmd_valid && cmd_ready)begin
            rsp_tag<=cmd_tag;rsp_error<=0;
            if(cfg_mode>5)begin state<=RESPONSE;rsp_error<=1;end
            else if(bad_config)begin state<=RESPONSE;rsp_error<=2;end
            else begin state<=START;width<=cfg_src_width;height<=cfg_src_height;dst_width<=cfg_dst_width;dst_height<=cfg_dst_height;angle_operation<=cfg_mode>=4;bilinear<=cfg_mode==5;cosine<=cfg_param0;sine<=cfg_param1;operation<=(cfg_mode==1?3'd4:(cfg_mode==2?3'd3:(cfg_mode==3?3'd5:3'd0)));end
        end
        START:if(cfg_ready)state<=RUN;
        RUN:begin
            if(core_rv)begin
                rsp_error<=core_error;
                state<=RESPONSE;
            end
        end
        RESPONSE:if(rsp_ready)state<=IDLE;
        default:state<=IDLE;
        endcase
    end
end
generate if(SUPPORTED)begin:enabled
    cip_image_permute_frame #(.DATA_W(DATA_W),.TAG_W(TAG_W),.MAX_WIDTH(MAX_WIDTH),.MAX_HEIGHT(MAX_HEIGHT)) core(
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
        .cmd_valid(state==START && !angle_operation),.cmd_ready(old_cr),.cmd_tag(rsp_tag),
        .cfg_operation(operation),.cfg_width(width),.cfg_height(height),
        .rsp_valid(old_rv),.rsp_ready(state==RUN && !angle_operation),.rsp_error(old_error),.rsp_tag(),
        .s_data(s_data),.s_valid(s_valid && state==RUN && !angle_operation),.s_sof(s_sof),.s_eol(s_eol),.s_ready(old_sr),
        .m_data(old_data),.m_valid(old_mv),.m_sof(old_ms),.m_eol(old_me),.m_last(),.m_ready(m_ready && state==RUN && !angle_operation));
end else begin:unsupported
    assign old_cr=0;assign old_sr=0;assign old_mv=0;assign old_ms=0;assign old_me=0;
    assign old_data=0;assign old_rv=0;assign old_error=0;
end endgenerate
generate if(SUPPORTED && ANGLE_SUPPORTED)begin:arbitrary_angle
 cip_image_rotate_angle_frame #(.DATA_W(DATA_W),.TAG_W(TAG_W),.MAX_WIDTH(MAX_WIDTH),.MAX_HEIGHT(MAX_HEIGHT),.PIXEL_W(PIXEL_W)) core(
 .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.cmd_valid(state==START && angle_operation),.cmd_ready(angle_cr),.cmd_tag(rsp_tag),
 .cfg_width(width),.cfg_height(height),.cfg_dst_width(dst_width),.cfg_dst_height(dst_height),.cfg_bilinear(bilinear),.cfg_cos(cosine),.cfg_sin(sine),
 .rsp_valid(angle_rv),.rsp_ready(state==RUN && angle_operation),.rsp_error(angle_error),.rsp_tag(),
 .s_data(s_data),.s_valid(s_valid && state==RUN && angle_operation),.s_sof(s_sof),.s_eol(s_eol),.s_ready(angle_sr),
 .m_data(angle_data),.m_valid(angle_mv),.m_sof(angle_ms),.m_eol(angle_me),.m_ready(m_ready && state==RUN && angle_operation));
end else begin:no_angle
 assign angle_cr=0;assign angle_sr=0;assign angle_mv=0;assign angle_ms=0;assign angle_me=0;assign angle_rv=0;assign angle_data=0;assign angle_error=0;
end endgenerate
endmodule
