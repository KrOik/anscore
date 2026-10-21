// Functional scalar/RGB weighted frame fusion; see FUNCTIONAL_IMAGE_ABI.md.
module cip_image_fusion #(parameter DATA_W=24, parameter TAG_W=8, parameter MAX_WIDTH=64, parameter MAX_HEIGHT=64)(
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
localparam SUPPORTED=DATA_W>=1 && DATA_W<=32 && MAX_WIDTH>=1 && MAX_WIDTH<=65535 && MAX_HEIGHT>=1 && MAX_HEIGHT<=65535;
localparam IDLE=0,INPUT_PIXEL=1,SCALAR_SUM=2,WAIT_RGB=3,OUTPUT_HOLD=4,RESPONSE=5,SCALAR_WAIT=6;
reg [2:0] state;
reg rgb_mode;
reg [8:0] aux_weight;
reg [15:0] width,height,x,y,width_last;
reg [31:0] pixels,index,pixels_last;
function [31:0] increment_count;
 input [31:0] value;
 begin
  increment_count[7:0]=value[7:0]+8'd1;
  increment_count[15:8]=value[15:8]+(&value[7:0]);
  increment_count[23:16]=value[23:16]+(&value[15:0]);
  increment_count[31:24]=value[31:24]+(&value[23:0]);
 end
endfunction
function [15:0] increment_position;
 input [15:0] value;
 begin increment_position[7:0]=value[7:0]+8'd1;increment_position[15:8]=value[15:8]+(&value[7:0]);end
endfunction
reg [DATA_W+8:0] product_base,product_aux;
reg [DATA_W-1:0] result;
reg marker_error;
localparam SUM_W=DATA_W+10,PAD_W=((SUM_W+7)/8)*8;
wire [SUM_W-1:0] sum_a={1'b0,product_base},sum_b={1'b0,product_aux},rounding=128;
wire [SUM_W-1:0] sum_s=sum_a^sum_b^rounding;
wire [SUM_W-1:0] sum_c=((sum_a&sum_b)|(sum_a&rounding)|(sum_b&rounding))<<1;
function [SUM_W-1:0] add_bytes;
 input [SUM_W-1:0] a,b;
 reg [PAD_W-1:0] ap,bp,r;
 reg [8:0] chunk;
 reg carry;
 integer j;
 begin
  ap=a;bp=b;r=0;carry=0;
  for(j=0;j<PAD_W/8;j=j+1)begin
   chunk={1'b0,ap[j*8+:8]}+{1'b0,bp[j*8+:8]};
   r[j*8+:8]=chunk[7:0]+carry;
   carry=chunk[8]|((&chunk[7:0])&carry);
  end
  add_bytes=r[SUM_W-1:0];
 end
endfunction
wire [SUM_W-1:0] scalar_sum=add_bytes(sum_s,sum_c);
wire [8:0] base_weight=9'd256-aux_weight;
wire mul_base_ready,mul_aux_ready,mul_base_valid,mul_aux_valid;
wire [DATA_W+8:0] mul_base_product,mul_aux_product;
wire scalar_issue=state==INPUT_PIXEL && !rgb_mode && s_valid && aux_valid && mul_base_ready && mul_aux_ready;
cip_fusion_scalar_multiply #(.A_W(DATA_W),.B_W(9)) base_multiply(
 .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.s_valid(scalar_issue),.s_ready(mul_base_ready),
 .s_a(s_data),.s_b(base_weight),.m_valid(mul_base_valid),.m_ready(state==SCALAR_WAIT && mul_aux_valid),.m_product(mul_base_product));
cip_fusion_scalar_multiply #(.A_W(DATA_W),.B_W(9)) aux_multiply(
 .clk(clk),.rst_n(rst_n),.clk_en(clk_en),.s_valid(scalar_issue),.s_ready(mul_aux_ready),
 .s_a(aux_data),.s_b(aux_weight),.m_valid(mul_aux_valid),.m_ready(state==SCALAR_WAIT && mul_base_valid),.m_product(mul_aux_product));

wire rgb_ready,rgb_valid;
wire [23:0] rgb_result;
wire source_bad=s_sof!=(index==0) || s_eol!=(x==width_last);
wire auxiliary_bad=aux_sof!=(index==0) || aux_eol!=(x==width_last);
wire last_pixel=index==pixels_last;
wire pair_ready=state==INPUT_PIXEL && (rgb_mode ? rgb_ready : (mul_base_ready && mul_aux_ready));
wire bad_config=!SUPPORTED || (cfg_mode==1 && DATA_W!=24) ||
    cfg_src_width==0 || cfg_src_height==0 || cfg_src_width>MAX_WIDTH || cfg_src_height>MAX_HEIGHT ||
    cfg_dst_width!=cfg_src_width || cfg_dst_height!=cfg_src_height || cfg_param0>256 ||
    cfg_param1!=0 || cfg_frame_base!=0 || cfg_frame_stride!=0 || cfg_aux_base!=0;
assign cmd_ready=rst_n && state==IDLE;
assign rsp_valid=rst_n && state==RESPONSE;
assign s_ready=rst_n && pair_ready && aux_valid;
assign aux_ready=rst_n && pair_ready && s_valid;
assign m_valid=rst_n && state==OUTPUT_HOLD;
assign m_data=result;
assign m_sof=m_valid && index==0;
assign m_eol=m_valid && x==width_last;
assign coeff_ready=0;assign mem_req_valid=0;assign mem_req_write=0;
assign mem_req_addr=0;assign mem_req_wdata=0;assign mem_req_wstrb=0;assign mem_rsp_ready=0;
generate if(DATA_W==24)begin:rgb
    img_mf_rgb_blend_partial_pipe #(.TAG_WIDTH(TAG_W),.FRAME_WIDTH(1)) core(
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
        .s_valid(state==INPUT_PIXEL && rgb_mode && s_valid && aux_valid),.s_ready(rgb_ready),
        .s_base(s_data),.s_aux(aux_data),.s_weight(aux_weight),.s_use_blend(1'b1),
        .s_sof(index==0),.s_eol(x==width_last),.s_tag(rsp_tag),.s_frameid(1'b0),.s_error(8'd0),
        .m_valid(rgb_valid),.m_ready(state==WAIT_RGB),.m_data(rgb_result),
        .m_sof(),.m_eol(),.m_tag(),.m_frameid(),.m_error());
end else begin:no_rgb
    assign rgb_ready=0;assign rgb_valid=0;assign rgb_result=0;
end endgenerate
always @(posedge clk or negedge rst_n)begin
    if(!rst_n)begin
        state<=IDLE;rgb_mode<=0;aux_weight<=0;width<=0;height<=0;x<=0;y<=0;pixels<=0;index<=0;pixels_last<=0;width_last<=0;
        product_base<=0;product_aux<=0;result<=0;marker_error<=0;rsp_tag<=0;rsp_error<=0;
    end else if(clk_en)begin
        case(state)
        IDLE:if(cmd_valid)begin
            rsp_tag<=cmd_tag;rsp_error<=0;marker_error<=0;
            if(cfg_mode>1)begin rsp_error<=1;state<=RESPONSE;end
            else if(bad_config)begin rsp_error<=2;state<=RESPONSE;end
            else begin
                rgb_mode<=cfg_mode[0];aux_weight<=cfg_param0[8:0];width<=cfg_src_width;height<=cfg_src_height;
                pixels<={16'd0,cfg_src_width}*{16'd0,cfg_src_height};pixels_last<=({16'd0,cfg_src_width}*{16'd0,cfg_src_height})-32'd1;width_last<=cfg_src_width-16'd1;index<=0;x<=0;y<=0;state<=INPUT_PIXEL;
            end
        end
        INPUT_PIXEL:if(s_valid && s_ready)begin
            if(source_bad || auxiliary_bad)marker_error<=1;
            if(rgb_mode)state<=WAIT_RGB;
            else state<=SCALAR_WAIT;
        end
        SCALAR_WAIT:if(mul_base_valid && mul_aux_valid)begin product_base<=mul_base_product;product_aux<=mul_aux_product;state<=SCALAR_SUM;end
        SCALAR_SUM:begin result<=scalar_sum >> 8;state<=OUTPUT_HOLD;end
        WAIT_RGB:if(rgb_valid)begin result<=rgb_result;state<=OUTPUT_HOLD;end
        OUTPUT_HOLD:if(m_ready)begin
            if(last_pixel)begin rsp_error<=marker_error?2'd2:2'd0;state<=RESPONSE;end
            else begin
                index<=increment_count(index);
                if(x==width_last)begin x<=0;y<=increment_position(y);end else x<=increment_position(x);
                state<=INPUT_PIXEL;
            end
        end
        RESPONSE:if(rsp_ready)state<=IDLE;
        default:begin rsp_error<=3;state<=RESPONSE;end
        endcase
    end
end
endmodule
