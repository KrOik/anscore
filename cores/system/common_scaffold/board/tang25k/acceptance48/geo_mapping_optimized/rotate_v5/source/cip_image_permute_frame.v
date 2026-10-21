// Lossless word-preserving frame permutation, synchronous internal frame RAM.
// op0 identity,1 horizontal mirror,2 vertical flip,3 180deg,4 90deg CW,5 270deg CW.
module cip_image_permute_frame #(
    parameter DATA_W=24,TAG_W=8,MAX_WIDTH=64,MAX_HEIGHT=64
)(
    input wire clk,rst_n,clk_en,
    input wire cmd_valid,output wire cmd_ready,input wire [TAG_W-1:0] cmd_tag,
    input wire [2:0] cfg_operation,input wire [15:0] cfg_width,cfg_height,
    output wire rsp_valid,input wire rsp_ready,output reg [TAG_W-1:0] rsp_tag,
    output reg [1:0] rsp_error,
    input wire [DATA_W-1:0] s_data,input wire s_valid,s_sof,s_eol,output wire s_ready,
    output wire [DATA_W-1:0] m_data,output wire m_valid,m_sof,m_eol,m_last,input wire m_ready
);
localparam CAPACITY_OK=DATA_W>=1 && DATA_W<=32 && MAX_WIDTH>=1 && MAX_WIDTH<=65535 &&
    MAX_HEIGHT>=1 && MAX_HEIGHT<=65535 && (64'd1*MAX_WIDTH*MAX_HEIGHT)<=1048576;
localparam DEPTH=CAPACITY_OK?MAX_WIDTH*MAX_HEIGHT:1;
localparam AW=DEPTH>1?$clog2(DEPTH):1;
localparam IDLE=0,CAPTURE=1,READ=2,OUTPUT_HOLD=3,RESPONSE=4;
reg [2:0] state,operation;
reg [15:0] width,height,out_width,out_height,x,y;
reg [31:0] pixels;
reg [AW-1:0] index;
reg marker_error;
reg [DATA_W-1:0] ram_q;
(* ram_style="block",syn_ramstyle="block_ram" *) reg [DATA_W-1:0] frame[0:DEPTH-1];
integer source_x,source_y,read_address;
always @* begin
    source_x=x;source_y=y;
    case(operation)
    1:source_x=width-1-x;
    2:source_y=height-1-y;
    3:begin source_x=width-1-x;source_y=height-1-y;end
    4:begin source_x=y;source_y=height-1-x;end
    5:begin source_x=width-1-y;source_y=x;end
    default:begin source_x=x;source_y=y;end
    endcase
    read_address=source_y*width+source_x;
end
assign cmd_ready=rst_n && state==IDLE;
assign s_ready=rst_n && state==CAPTURE;
assign rsp_valid=rst_n && state==RESPONSE;
assign m_valid=rst_n && state==OUTPUT_HOLD;
assign m_data=ram_q;
assign m_sof=m_valid && index==0;
assign m_eol=m_valid && x==out_width-1;
assign m_last=m_valid && index==pixels-1;
always @(posedge clk)if(rst_n && clk_en)begin
    if(s_valid && s_ready)frame[index]<=s_data;
    if(state==READ)ram_q<=frame[read_address];
end
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        state<=IDLE;operation<=0;width<=0;height<=0;out_width<=0;out_height<=0;
        x<=0;y<=0;pixels<=0;index<=0;marker_error<=0;rsp_tag<=0;rsp_error<=0;
    end else if(clk_en)begin
        case(state)
        IDLE:if(cmd_valid)begin
            rsp_tag<=cmd_tag;rsp_error<=0;marker_error<=0;
            if(cfg_operation>5)begin rsp_error<=1;state<=RESPONSE;end
            else if(!CAPACITY_OK || cfg_width==0 || cfg_height==0 || cfg_width>MAX_WIDTH || cfg_height>MAX_HEIGHT)begin
                rsp_error<=2;state<=RESPONSE;
            end else begin
                operation<=cfg_operation;width<=cfg_width;height<=cfg_height;
                out_width<=cfg_operation>=4?cfg_height:cfg_width;
                out_height<=cfg_operation>=4?cfg_width:cfg_height;
                pixels<={16'd0,cfg_width}*{16'd0,cfg_height};index<=0;x<=0;y<=0;state<=CAPTURE;
            end
        end
        CAPTURE:if(s_valid && s_ready)begin
            if(s_sof!=(index==0) || s_eol!=(x==width-1))marker_error<=1;
            if(index==pixels-1)begin index<=0;x<=0;y<=0;state<=READ;end
            else begin
                index<=index+1;
                if(x==width-1)begin x<=0;y<=y+1;end else x<=x+1;
            end
        end
        READ:state<=OUTPUT_HOLD;
        OUTPUT_HOLD:if(m_ready)begin
            if(m_last)begin rsp_error<=marker_error?2'd2:2'd0;state<=RESPONSE;end
            else begin
                index<=index+1;
                if(x==out_width-1)begin x<=0;y<=y+1;end else x<=x+1;
                state<=READ;
            end
        end
        RESPONSE:if(rsp_ready)state<=IDLE;
        default:begin rsp_error<=3;state<=RESPONSE;end
        endcase
    end
end
endmodule
