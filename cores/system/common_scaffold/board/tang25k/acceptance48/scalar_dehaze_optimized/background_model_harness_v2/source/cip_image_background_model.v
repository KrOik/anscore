// Functional internal Qn.8 EWMA grayscale background model; see FUNCTIONAL_IMAGE_ABI.md.
module cip_image_background_model #(parameter DATA_W=24, parameter TAG_W=8, parameter MAX_WIDTH=64, parameter MAX_HEIGHT=64)(
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
localparam MODEL_W=DATA_W+8;
localparam RAW_WORDS=(MODEL_W+DATA_W-1)/DATA_W;
localparam IDLE=0,INPUT_PIXEL=1,MODEL_UPDATE=2,OUTPUT_HOLD=3,RESPONSE=4;
reg [2:0] state;
reg [1:0] mode;
reg [3:0] update_shift;
reg freeze_foreground;
reg [15:0] width,height,x,y,history_width,history_height;
reg [31:0] pixels;
reg [AW-1:0] index;
reg [DATA_W-1:0] threshold,pending_data;
reg [MODEL_W-1:0] history_q,packet;
reg marker_error,history_valid,frame_history_valid;
integer word_index;
(* ram_style="block",syn_ramstyle="block_ram" *) reg [MODEL_W-1:0] history[0:DEPTH-1];
wire [DATA_W-1:0] old_pixel=history_q[MODEL_W-1:8];
wire [DATA_W-1:0] difference=!frame_history_valid?{DATA_W{1'b0}}:
    (pending_data>=old_pixel?pending_data-old_pixel:old_pixel-pending_data);
wire foreground=frame_history_valid && difference>threshold;
wire signed [MODEL_W+1:0] delta=$signed({2'b00,pending_data,8'd0})-$signed({2'b00,history_q});
wire signed [MODEL_W+1:0] updated=$signed({2'b00,history_q})+(delta >>> update_shift);
wire [MODEL_W-1:0] next_model=!frame_history_valid?{pending_data,8'd0}:
    ((freeze_foreground && foreground)?history_q:updated[MODEL_W-1:0]);
wire source_bad=s_sof!=(index==0) || s_eol!=(x==width-1);
wire last_pixel=index==pixels-1;
wire last_word=word_index==(mode==3?RAW_WORDS-1:0);
wire bad_config=!SUPPORTED || cfg_src_width==0 || cfg_src_height==0 || cfg_src_width>MAX_WIDTH || cfg_src_height>MAX_HEIGHT ||
    cfg_dst_width!=cfg_src_width || cfg_dst_height!=cfg_src_height || (cfg_param0 >> DATA_W)!=0 ||
    cfg_param1[3:0]>8 || (cfg_param1 & 32'hfffffcf0)!=0 ||
    cfg_frame_base!=0 || cfg_frame_stride!=0 || cfg_aux_base!=0;
assign cmd_ready=rst_n && state==IDLE;
assign rsp_valid=rst_n && state==RESPONSE;
assign s_ready=rst_n && state==INPUT_PIXEL;
assign aux_ready=0;
assign m_valid=rst_n && state==OUTPUT_HOLD;
assign m_data=packet >> (word_index*DATA_W);
assign m_sof=m_valid && index==0 && word_index==0;
assign m_eol=m_valid && x==width-1 && last_word;
assign coeff_ready=0;assign mem_req_valid=0;assign mem_req_write=0;
assign mem_req_addr=0;assign mem_req_wdata=0;assign mem_req_wstrb=0;assign mem_rsp_ready=0;
always @(posedge clk)if(rst_n && clk_en)begin
    if(s_valid && s_ready)history_q<=history[index];
    if(state==MODEL_UPDATE)history[index]<=next_model;
end
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        state<=IDLE;mode<=0;update_shift<=0;freeze_foreground<=0;width<=0;height<=0;x<=0;y<=0;pixels<=0;index<=0;
        history_width<=0;history_height<=0;history_valid<=0;frame_history_valid<=0;
        threshold<=0;pending_data<=0;packet<=0;marker_error<=0;rsp_tag<=0;rsp_error<=0;word_index<=0;
    end else if(clk_en)begin
        case(state)
        IDLE:if(cmd_valid)begin
            rsp_tag<=cmd_tag;rsp_error<=0;marker_error<=0;word_index<=0;
            if(cfg_mode>3)begin rsp_error<=1;state<=RESPONSE;end
            else if(bad_config)begin rsp_error<=2;state<=RESPONSE;end
            else begin
                mode<=cfg_mode[1:0];width<=cfg_src_width;height<=cfg_src_height;threshold<=cfg_param0;
                update_shift<=cfg_param1[3:0];freeze_foreground<=cfg_param1[8];
                pixels<={16'd0,cfg_src_width}*{16'd0,cfg_src_height};index<=0;x<=0;y<=0;
                frame_history_valid<=history_valid && !cfg_param1[9] && cfg_src_width==history_width && cfg_src_height==history_height;
                state<=INPUT_PIXEL;
            end
        end
        INPUT_PIXEL:if(s_valid && s_ready)begin
            if(source_bad)marker_error<=1;
            pending_data<=s_data;state<=MODEL_UPDATE;
        end
        MODEL_UPDATE:begin
            word_index<=0;
            case(mode)
            0:packet<=next_model >> 8;
            1:packet<={{8{1'b0}},difference};
            2:packet<=foreground?{{8{1'b0}},{DATA_W{1'b1}}}:{MODEL_W{1'b0}};
            3:packet<=next_model;
            endcase
            state<=OUTPUT_HOLD;
        end
        OUTPUT_HOLD:if(m_ready)begin
            if(!last_word)word_index<=word_index+1;
            else if(last_pixel)begin
                rsp_error<=marker_error?2'd2:2'd0;state<=RESPONSE;
                history_width<=width;history_height<=height;history_valid<=!marker_error;
            end else begin
                index<=index+1;word_index<=0;
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
