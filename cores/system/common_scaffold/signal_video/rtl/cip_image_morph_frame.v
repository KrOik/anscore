// Bounded grayscale morphology with synchronous raw/scratch memories.
// op0 erode,1 dilate,2 open,3 close,4 saturated nonnegative gradient.
// Erosion samples x+b; dilation samples x-b, including asymmetric masks.
module cip_image_morph_frame #(
    parameter DATA_W=8,TAG_W=8,MAX_WIDTH=64,MAX_HEIGHT=64
)(
    input wire clk,rst_n,clk_en,
    input wire cmd_valid,output wire cmd_ready,input wire [TAG_W-1:0] cmd_tag,
    input wire [2:0] cfg_operation,input wire [15:0] cfg_width,cfg_height,
    input wire [8:0] cfg_mask,
    output wire rsp_valid,input wire rsp_ready,output reg [TAG_W-1:0] rsp_tag,
    output reg [1:0] rsp_error,
    input wire [DATA_W-1:0] s_data,input wire s_valid,s_sof,s_eol,output wire s_ready,
    output reg [DATA_W-1:0] m_data,output wire m_valid,m_sof,m_eol,m_last,input wire m_ready
);
localparam CAPACITY_OK=MAX_WIDTH>=1 && MAX_WIDTH<=65535 && MAX_HEIGHT>=1 && MAX_HEIGHT<=65535 &&
    (64'd1*MAX_WIDTH*MAX_HEIGHT)<=1048576;
localparam DEPTH=CAPACITY_OK?MAX_WIDTH*MAX_HEIGHT:1;
localparam AW=DEPTH>1?$clog2(DEPTH):1;
localparam IDLE=0,CAPTURE=1,READ=2,REDUCE=3,STORE=4,GRAD_OUT=5,OUTPUT_HOLD=6,RESPONSE=7,MEM_READ=8;
reg [3:0] state;
reg [2:0] operation;
reg [15:0] width,height,x,y;
reg [31:0] pixels;
reg [AW-1:0] index,read_address_q;
reg [8:0] mask;
reg [3:0] tap;
reg second_pass,marker_error;
reg [DATA_W-1:0] extreme,raw_q,tmp_q;
(* ram_style="block", syn_ramstyle="block_ram" *) reg [DATA_W-1:0] raw[0:DEPTH-1];
(* ram_style="block", syn_ramstyle="block_ram" *) reg [DATA_W-1:0] scratch[0:DEPTH-1];
wire maximum_pass=operation==1 || (operation==3 && !second_pass) ||
    ((operation==2 || operation==4) && second_pass);
wire read_scratch=second_pass && operation!=4;
wire [DATA_W-1:0] sample=read_scratch?tmp_q:raw_q;
wire [DATA_W-1:0] reduced=mask[tap] && (maximum_pass?(sample>extreme):(sample<extreme))?sample:extreme;
wire buffered_first_pass=!second_pass && operation>=2;
wire last_pixel=index==pixels-1;
wire input_bad=(s_sof!=(index==0)) || (s_eol!=(x==width-1));
integer read_x,read_y,read_address,offset_x,offset_y;
always @* begin
    offset_x=tap%3;offset_x=offset_x-1;
    offset_y=tap/3;offset_y=offset_y-1;
    read_x=x;read_y=y;
    if(maximum_pass)begin read_x=$signed({1'b0,x})-offset_x;read_y=$signed({1'b0,y})-offset_y;end
    else begin read_x=$signed({1'b0,x})+offset_x;read_y=$signed({1'b0,y})+offset_y;end
    if(read_x<0)read_x=0;else if(read_x>=width)read_x=width-1;
    if(read_y<0)read_y=0;else if(read_y>=height)read_y=height-1;
    read_address=read_y*width+read_x;
end
assign cmd_ready=rst_n && state==IDLE;
assign s_ready=rst_n && state==CAPTURE;
assign rsp_valid=rst_n && state==RESPONSE;
assign m_valid=rst_n && state==OUTPUT_HOLD;
assign m_sof=m_valid && index==0;
assign m_eol=m_valid && x==width-1;
assign m_last=m_valid && last_pixel;
always @(posedge clk)if(rst_n && clk_en)begin
    if(s_valid && s_ready)raw[index]<=s_data;
    if(state==MEM_READ && !read_scratch)raw_q<=raw[read_address_q];
    // Explicit one synchronous scratch read port, shared between passes.
    if((state==MEM_READ && read_scratch) || (state==STORE && operation==4 && second_pass))
        tmp_q<=scratch[state==STORE ? index : read_address_q];
    if(state==STORE && buffered_first_pass)scratch[index]<=extreme;
end
task next_position;
begin
    index<=index+1;
    if(x==width-1)begin x<=0;y<=y+1;end else x<=x+1;
end
endtask
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        state<=IDLE;operation<=0;width<=0;height<=0;x<=0;y<=0;pixels<=0;index<=0;
        read_address_q<=0;mask<=0;tap<=0;second_pass<=0;marker_error<=0;extreme<=0;
        rsp_tag<=0;rsp_error<=0;m_data<=0;
    end else if(clk_en)begin
        case(state)
        IDLE:if(cmd_valid && cmd_ready)begin
            rsp_tag<=cmd_tag;rsp_error<=0;marker_error<=0;
            if(cfg_operation>4)begin rsp_error<=1;state<=RESPONSE;end
            else if(!CAPACITY_OK || DATA_W<1 || DATA_W>32 || cfg_width==0 || cfg_height==0 ||
                cfg_width>MAX_WIDTH || cfg_height>MAX_HEIGHT || cfg_mask==0)begin rsp_error<=2;state<=RESPONSE;end
            else begin
                operation<=cfg_operation;width<=cfg_width;height<=cfg_height;mask<=cfg_mask;
                pixels<={16'd0,cfg_width}*{16'd0,cfg_height};index<=0;x<=0;y<=0;second_pass<=0;tap<=0;state<=CAPTURE;
            end
        end
        CAPTURE:if(s_valid && s_ready)begin
            if(input_bad)marker_error<=1;
            if(last_pixel)begin
                index<=0;x<=0;y<=0;tap<=0;extreme<=(operation==1 || operation==3)?0:{DATA_W{1'b1}};state<=READ;
            end else next_position;
        end
        READ:begin read_address_q<=read_address;state<=MEM_READ;end
        MEM_READ:state<=REDUCE;
        REDUCE:begin
            extreme<=reduced;
            if(tap==8)state<=STORE;
            else begin tap<=tap+1;state<=READ;end
        end
        STORE:begin
            if(buffered_first_pass)begin
                tap<=0;state<=READ;
                if(last_pixel)begin
                    second_pass<=1;index<=0;x<=0;y<=0;
                    extreme<=operation==3?{DATA_W{1'b1}}:0;
                end else begin next_position;extreme<=maximum_pass?0:{DATA_W{1'b1}};end
            end else if(operation==4)state<=GRAD_OUT;
            else begin m_data<=extreme;state<=OUTPUT_HOLD;end
        end
        GRAD_OUT:begin m_data<=extreme>tmp_q?extreme-tmp_q:0;state<=OUTPUT_HOLD;end
        OUTPUT_HOLD:if(m_ready)begin
            if(last_pixel)begin rsp_error<=marker_error?2'd2:2'd0;state<=RESPONSE;end
            else begin next_position;tap<=0;extreme<=maximum_pass?0:{DATA_W{1'b1}};state<=READ;end
        end
        RESPONSE:if(rsp_ready)state<=IDLE;
        default:begin rsp_error<=3;state<=RESPONSE;end
        endcase
    end
end
endmodule
