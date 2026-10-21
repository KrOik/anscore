// Functional paired/history grayscale frame difference; see FUNCTIONAL_IMAGE_ABI.md.
module cip_image_frame_difference #(parameter DATA_W=24, parameter TAG_W=8, parameter MAX_WIDTH=64, parameter MAX_HEIGHT=64)(
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
localparam SUPPORTED=DATA_W>=1 && DATA_W<=32 && MAX_WIDTH>=1 && MAX_WIDTH<=65535 &&
    MAX_HEIGHT>=1 && MAX_HEIGHT<=65535 && (64'd1*MAX_WIDTH*MAX_HEIGHT)<=1048576;
localparam DEPTH=SUPPORTED?MAX_WIDTH*MAX_HEIGHT:1;
localparam AW=DEPTH>1?$clog2(DEPTH):1;
localparam IDLE=0,INPUT_PIXEL=1,HISTORY_UPDATE=2,OUTPUT_HOLD=3,RESPONSE=4;
reg [2:0] state;
reg [1:0] mode;
reg [15:0] width,height,x,y,history_width,history_height;
reg [31:0] pixels;
reg [AW-1:0] index;
reg [DATA_W-1:0] threshold,pending_data,history_q,result;
reg marker_error,history_valid,frame_history_valid;
(* ram_style="block",syn_ramstyle="block_ram" *) reg [DATA_W-1:0] history[0:DEPTH-1];
wire history_mode=mode[1];
wire [DATA_W-1:0] paired_difference=s_data>=aux_data?s_data-aux_data:aux_data-s_data;
wire [DATA_W-1:0] history_difference=!frame_history_valid?{DATA_W{1'b0}}:
    (pending_data>=history_q?pending_data-history_q:history_q-pending_data);
wire source_bad=s_sof!=(index==0) || s_eol!=(x==width-1);
wire auxiliary_bad=aux_sof!=(index==0) || aux_eol!=(x==width-1);
wire last_pixel=index==pixels-1;
wire bad_config=!SUPPORTED || cfg_src_width==0 || cfg_src_height==0 || cfg_src_width>MAX_WIDTH || cfg_src_height>MAX_HEIGHT ||
    cfg_dst_width!=cfg_src_width || cfg_dst_height!=cfg_src_height || (cfg_param0 >> DATA_W)!=0 ||
    cfg_param1!=0 || cfg_frame_base!=0 || cfg_frame_stride!=0 || cfg_aux_base!=0;
assign cmd_ready=rst_n && state==IDLE;
assign rsp_valid=rst_n && state==RESPONSE;
assign s_ready=rst_n && state==INPUT_PIXEL && (history_mode || aux_valid);
assign aux_ready=rst_n && state==INPUT_PIXEL && !history_mode && s_valid;
assign m_valid=rst_n && state==OUTPUT_HOLD;
assign m_data=result;
assign m_sof=m_valid && index==0;
assign m_eol=m_valid && x==width-1;
assign coeff_ready=0;assign mem_req_valid=0;assign mem_req_write=0;
assign mem_req_addr=0;assign mem_req_wdata=0;assign mem_req_wstrb=0;assign mem_rsp_ready=0;
always @(posedge clk)if(rst_n && clk_en)begin
    if(s_valid && s_ready && history_mode)history_q<=history[index];
    if(state==HISTORY_UPDATE)history[index]<=pending_data;
end
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        state<=IDLE;mode<=0;width<=0;height<=0;x<=0;y<=0;pixels<=0;index<=0;
        history_width<=0;history_height<=0;history_valid<=0;frame_history_valid<=0;
        threshold<=0;pending_data<=0;result<=0;marker_error<=0;rsp_tag<=0;rsp_error<=0;
    end else if(clk_en)begin
        case(state)
        IDLE:if(cmd_valid)begin
            rsp_tag<=cmd_tag;rsp_error<=0;marker_error<=0;
            if(cfg_mode>3)begin rsp_error<=1;state<=RESPONSE;end
            else if(bad_config)begin rsp_error<=2;state<=RESPONSE;end
            else begin
                mode<=cfg_mode[1:0];width<=cfg_src_width;height<=cfg_src_height;threshold<=cfg_param0;
                pixels<={16'd0,cfg_src_width}*{16'd0,cfg_src_height};index<=0;x<=0;y<=0;
                frame_history_valid<=history_valid && cfg_src_width==history_width && cfg_src_height==history_height;
                state<=INPUT_PIXEL;
            end
        end
        INPUT_PIXEL:if(s_valid && s_ready)begin
            if(source_bad || (!history_mode && auxiliary_bad))marker_error<=1;
            if(history_mode)begin pending_data<=s_data;state<=HISTORY_UPDATE;end
            else begin
                result<=mode[0]?(paired_difference>threshold?{DATA_W{1'b1}}:{DATA_W{1'b0}}):paired_difference;
                state<=OUTPUT_HOLD;
            end
        end
        HISTORY_UPDATE:begin
            result<=mode[0]?(history_difference>threshold?{DATA_W{1'b1}}:{DATA_W{1'b0}}):history_difference;
            state<=OUTPUT_HOLD;
        end
        OUTPUT_HOLD:if(m_ready)begin
            if(last_pixel)begin
                rsp_error<=marker_error?2'd2:2'd0;state<=RESPONSE;
                if(history_mode)begin
                    history_width<=width;history_height<=height;history_valid<=!marker_error;
                end
            end else begin
                index<=index+1;
                if(x==width-1)begin x<=0;y<=y+1;end else x<=x+1;
                state<=INPUT_PIXEL;
            end
        end
        RESPONSE:if(rsp_ready)state<=IDLE;
        default:begin rsp_error<=3;state<=RESPONSE;history_valid<=0;end
        endcase
    end
end
endmodule
