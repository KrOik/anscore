// Runtime-size 8-bit grayscale histogram / normalized HE frame engine.
// op0 emits 256 unsigned 32-bit bin counts; op1 replays equalized gray pixels.
// HE: floor(255*(CDF-CDFmin)/(N-CDFmin)); constant frames retain their value.
// Shared CE protocol; synchronous memories, no RAM reset loops.
module cip_image_histogram_frame #(
    parameter TAG_W=8, MAX_WIDTH=64, MAX_HEIGHT=64
)(
    input wire clk,rst_n,clk_en,
    input wire cmd_valid,output wire cmd_ready,input wire [TAG_W-1:0] cmd_tag,
    input wire cfg_operation,input wire [15:0] cfg_width,cfg_height,
    output wire rsp_valid,input wire rsp_ready,output reg [TAG_W-1:0] rsp_tag,
    output reg [1:0] rsp_error,
    input wire [7:0] s_data,input wire s_valid,s_sof,s_eol,output wire s_ready,
    output reg [31:0] m_data,output wire m_valid,m_sof,m_eol,m_last,input wire m_ready
);
localparam CAPACITY_OK=MAX_WIDTH>=1 && MAX_WIDTH<=65535 && MAX_HEIGHT>=1 && MAX_HEIGHT<=65535 &&
    (64'd1*MAX_WIDTH*MAX_HEIGHT)<=1048576;
localparam DEPTH=CAPACITY_OK?MAX_WIDTH*MAX_HEIGHT:1;
localparam AW=DEPTH>1?$clog2(DEPTH):1;
localparam IDLE=0,CLEAR=1,CAPTURE=2,UPDATE=3,BIN_READ=4,SCAN=5,
    DIV_REQUEST=6,DIV_RESPONSE=7,LUT_WRITE=8,OUT_READ=9,OUT_LUT=10,
    OUT_WAIT=11,OUTPUT_HOLD=12,RESPONSE=13;
reg [3:0] state;
reg operation,marker_error,seen;
reg [15:0] width,height,x,y;
reg [31:0] pixels,cdf,cdf_min,numerator,denominator;
reg [AW-1:0] index;
reg [7:0] bin,pending_gray,raw_q,lut_q,lut_value;
reg [31:0] hist_q;
(* ram_style="block",syn_ramstyle="block_ram" *) reg [7:0] raw[0:DEPTH-1];
(* ram_style="block",syn_ramstyle="block_ram" *) reg [31:0] histogram[0:255];
(* ram_style="block",syn_ramstyle="block_ram" *) reg [7:0] lookup[0:255];
wire [31:0] next_cdf=cdf+hist_q;
wire [31:0] effective_min=seen?cdf_min:hist_q;
wire div_ready,div_valid,div_error;
wire [7:0] div_value;
wire last_input=index==pixels-1;
assign cmd_ready=rst_n && state==IDLE;
assign s_ready=rst_n && state==CAPTURE;
assign rsp_valid=rst_n && state==RESPONSE;
assign m_valid=rst_n && state==OUTPUT_HOLD;
assign m_sof=m_valid && (operation?index==0:bin==0);
assign m_eol=m_valid && (operation?x==width-1:bin==255);
assign m_last=m_valid && (operation?last_input:bin==255);
img_hist_ratio_u8 #(.COUNT_WIDTH(32)) ratio(
    .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
    .s_valid(state==DIV_REQUEST),.s_ready(div_ready),.s_numerator(numerator),.s_denominator(denominator),
    .m_valid(div_valid),.m_ready(state==DIV_RESPONSE),.m_value(div_value),.m_error(div_error));
always @(posedge clk)if(rst_n && clk_en)begin
    // One explicit synchronous read and one write port; FSM timing unchanged.
    if(s_valid && s_ready)raw[index]<=s_data;
    if((s_valid && s_ready) || state==BIN_READ)
        hist_q<=histogram[state==BIN_READ ? bin : s_data];
    if(state==CLEAR || state==UPDATE)
        histogram[state==CLEAR ? bin : pending_gray]<=state==CLEAR ? 32'd0 : hist_q+32'd1;
    if(state==LUT_WRITE)lookup[bin]<=lut_value;
    if(state==OUT_READ)raw_q<=raw[index];
    if(state==OUT_LUT)lut_q<=lookup[raw_q];
end
task next_position;
begin
    index<=index+1;
    if(x==width-1)begin x<=0;y<=y+1;end else x<=x+1;
end
endtask
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        state<=IDLE;operation<=0;marker_error<=0;seen<=0;width<=0;height<=0;x<=0;y<=0;
        pixels<=0;cdf<=0;cdf_min<=0;numerator<=0;denominator<=0;index<=0;bin<=0;
        pending_gray<=0;lut_value<=0;m_data<=0;rsp_tag<=0;rsp_error<=0;
    end else if(clk_en)begin
        case(state)
        IDLE:if(cmd_valid)begin
            rsp_tag<=cmd_tag;rsp_error<=0;
            if(!CAPACITY_OK || cfg_width==0 || cfg_height==0 || cfg_width>MAX_WIDTH || cfg_height>MAX_HEIGHT)begin
                rsp_error<=2;state<=RESPONSE;
            end else begin
                operation<=cfg_operation;width<=cfg_width;height<=cfg_height;
                pixels<={16'd0,cfg_width}*{16'd0,cfg_height};index<=0;x<=0;y<=0;
                bin<=0;marker_error<=0;seen<=0;cdf<=0;cdf_min<=0;state<=CLEAR;
            end
        end
        CLEAR:if(bin==255)begin bin<=0;state<=CAPTURE;end else bin<=bin+1;
        CAPTURE:if(s_valid && s_ready)begin
            pending_gray<=s_data;
            if(s_sof!=(index==0) || s_eol!=(x==width-1))marker_error<=1;
            state<=UPDATE;
        end
        UPDATE:if(last_input)begin index<=0;x<=0;y<=0;bin<=0;state<=BIN_READ;end
            else begin next_position;state<=CAPTURE;end
        BIN_READ:state<=SCAN;
        SCAN:begin
            if(!operation)begin m_data<=hist_q;state<=OUTPUT_HOLD;end
            else begin
                cdf<=next_cdf;
                if(!seen && hist_q!=0)begin seen<=1;cdf_min<=hist_q;end
                if(!seen && hist_q==0)begin lut_value<=0;state<=LUT_WRITE;end
                else if(effective_min==pixels)begin lut_value<=bin;state<=LUT_WRITE;end
                else begin numerator<=next_cdf-effective_min;denominator<=pixels-effective_min;state<=DIV_REQUEST;end
            end
        end
        DIV_REQUEST:if(div_ready)state<=DIV_RESPONSE;
        DIV_RESPONSE:if(div_valid)begin
            if(div_error)begin rsp_error<=3;state<=RESPONSE;end
            else begin lut_value<=div_value;state<=LUT_WRITE;end
        end
        LUT_WRITE:if(bin==255)begin index<=0;x<=0;y<=0;state<=OUT_READ;end
            else begin bin<=bin+1;state<=BIN_READ;end
        OUT_READ:state<=OUT_LUT;
        OUT_LUT:state<=OUT_WAIT;
        OUT_WAIT:begin m_data<={24'd0,lut_q};state<=OUTPUT_HOLD;end
        OUTPUT_HOLD:if(m_ready)begin
            if(m_last)begin rsp_error<=marker_error?2'd2:2'd0;state<=RESPONSE;end
            else if(operation)begin next_position;state<=OUT_READ;end
            else begin bin<=bin+1;state<=BIN_READ;end
        end
        RESPONSE:if(rsp_ready)state<=IDLE;
        default:begin rsp_error<=3;state<=RESPONSE;end
        endcase
    end
end
endmodule
