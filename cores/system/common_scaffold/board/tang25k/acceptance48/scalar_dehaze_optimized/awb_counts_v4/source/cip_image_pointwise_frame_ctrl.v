// Shared command/frame control for same-size pointwise stream algorithms.
// The connected kernel must preserve one output per input and all markers.
module cip_image_pointwise_frame_ctrl #(parameter DATA_W=24,TAG_W=8)(
    input wire clk,rst_n,clk_en,
    input wire cmd_valid,output wire cmd_ready,input wire [TAG_W-1:0] cmd_tag,
    input wire [1:0] cmd_error,
    input wire [15:0] cfg_width,cfg_height,
    input wire [31:0] cfg_param0,cfg_param1,
    output reg [31:0] param0,param1,
    output wire configure,input wire configure_ready,
    output wire rsp_valid,input wire rsp_ready,output reg [TAG_W-1:0] rsp_tag,
    output reg [1:0] rsp_error,
    input wire s_valid,s_sof,s_eol,output wire s_ready,
    output wire kernel_s_valid,kernel_s_sof,kernel_s_eol,input wire kernel_s_ready,
    input wire [DATA_W-1:0] kernel_m_data,
    input wire kernel_m_valid,kernel_m_sof,kernel_m_eol,output wire kernel_m_ready,
    output wire [DATA_W-1:0] m_data,
    output wire m_valid,m_sof,m_eol,input wire m_ready
);
localparam IDLE=0,CONFIGURE=1,RUN=2,RESPONSE=3;
reg [1:0] state;
reg [15:0] width,x,y;
reg [31:0] input_left,output_left;
reg marker_error;
wire input_fire=s_valid && s_ready;
wire output_fire=m_valid && m_ready;
wire bad_marker=(s_sof!=(x==0 && y==0)) || (s_eol!=(x==width-1));
assign cmd_ready=rst_n && state==IDLE;
assign configure=rst_n && state==CONFIGURE;
assign rsp_valid=rst_n && state==RESPONSE;
assign s_ready=rst_n && state==RUN && input_left!=0 && kernel_s_ready;
assign kernel_s_valid=rst_n && state==RUN && input_left!=0 && s_valid;
assign kernel_s_sof=x==0 && y==0;
assign kernel_s_eol=x==width-1;
assign m_valid=rst_n && state==RUN && kernel_m_valid;
assign m_data=kernel_m_data;
assign m_sof=m_valid && kernel_m_sof;
assign m_eol=m_valid && kernel_m_eol;
assign kernel_m_ready=rst_n && state==RUN && m_ready;
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        state<=IDLE;param0<=0;param1<=0;rsp_tag<=0;rsp_error<=0;
        width<=0;x<=0;y<=0;input_left<=0;output_left<=0;marker_error<=0;
    end else if(clk_en)begin
        case(state)
        IDLE:if(cmd_valid && cmd_ready)begin
            rsp_tag<=cmd_tag;rsp_error<=cmd_error;
            if(cmd_error!=0)state<=RESPONSE;
            else begin
                width<=cfg_width;x<=0;y<=0;marker_error<=0;
                input_left<={16'b0,cfg_width}*{16'b0,cfg_height};
                output_left<={16'b0,cfg_width}*{16'b0,cfg_height};
                param0<=cfg_param0;param1<=cfg_param1;state<=CONFIGURE;
            end
        end
        CONFIGURE:if(configure_ready)state<=RUN;
        RUN:begin
            if(input_fire)begin
                input_left<=input_left-1;
                if(bad_marker)marker_error<=1;
                if(x==width-1)begin x<=0;y<=y+1;end else x<=x+1;
            end
            if(output_fire)begin
                output_left<=output_left-1;
                if(output_left==1)begin
                    rsp_error<=(marker_error || (input_fire && bad_marker))?2'd2:2'd0;
                    state<=RESPONSE;
                end
            end
        end
        RESPONSE:if(rsp_ready)state<=IDLE;
        default:state<=IDLE;
        endcase
    end
end
endmodule
