// Functional bounded external-memory frame store/replay frame adapter; see FUNCTIONAL_IMAGE_ABI.md.
module cip_image_framebuffer #(parameter DATA_W=24, parameter TAG_W=8, parameter MAX_WIDTH=64, parameter MAX_HEIGHT=64)(
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
// mode0 write then replay; mode1 write only; mode2 read only.
// External addresses/stride are bytes, each pixel occupies one aligned32-bit word.
// Exactly one outstanding memory request. Errors abort the current command.
localparam IDLE=0,CAPTURE=1,WRITE_REQ=2,WRITE_WAIT=3,READ_REQ=4,READ_WAIT=5,SEND=6,RESPONSE=7,CALC_SPAN=8,CALC_LAST=9,CHECK_LAST=10,WAIT_SPAN=11,FOLD_LAST=12;
localparam SUPPORTED=DATA_W>=1 && DATA_W<=32 && MAX_WIDTH>=1 && MAX_WIDTH<=65535 && MAX_HEIGHT>=1 && MAX_HEIGHT<=65535;
reg [3:0] state;
reg [47:0] span_product;
wire span_ready,span_valid;
wire [47:0] span_result;
cip_fb_unsigned_multiply #(.A_W(32),.B_W(16)) span_multiplier(
 .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
 .s_valid(state==CALC_SPAN),.s_ready(span_ready),.s_a(stride),.s_b(height-16'd1),
 .m_valid(span_valid),.m_ready(state==WAIT_SPAN),.m_product(span_result));
reg [63:0] add_sum,add_carry,fold_result;
reg fold_carry;
reg [3:0] fold_count;
wire [63:0] last_a={32'd0,base},last_b={16'd0,span_product};
wire [63:0] last_c=64'd4*width-64'd1;
wire [8:0] fold_byte={1'b0,add_sum[7:0]}+{1'b0,add_carry[7:0]}+fold_carry;
wire [63:0] fold_next={fold_byte[7:0],fold_result[63:8]};
reg [63:0] last_byte_q;
reg [1:0] mode;
reg [15:0] width,height,x,y;
reg [31:0] base,stride,row_addr,address,write_data;
reg [DATA_W-1:0] read_data;
reg frame_error;
wire [63:0] last_byte={32'd0,cfg_frame_base}+64'd1*(cfg_src_height-16'd1)*cfg_frame_stride+64'd4*cfg_src_width-1;
wire bad=!SUPPORTED || cfg_src_width==0 || cfg_src_height==0 || cfg_src_width>MAX_WIDTH || cfg_src_height>MAX_HEIGHT ||
 cfg_dst_width!=cfg_src_width || cfg_dst_height!=cfg_src_height || cfg_param0!=0 || cfg_param1!=0 || cfg_aux_base!=0 ||
 cfg_frame_base[1:0]!=0 || cfg_frame_stride[1:0]!=0 || cfg_frame_stride<32'd4*cfg_src_width;
assign cmd_ready=rst_n && state==IDLE;
assign rsp_valid=rst_n && state==RESPONSE;
assign s_ready=rst_n && state==CAPTURE;
assign m_valid=rst_n && state==SEND;
assign m_data=read_data;
assign m_sof=m_valid && x==0 && y==0;
assign m_eol=m_valid && x==width-1'b1;
assign coeff_ready=0;assign aux_ready=0;
assign mem_req_valid=rst_n && (state==WRITE_REQ || state==READ_REQ);
assign mem_req_write=state==WRITE_REQ;
assign mem_req_addr=address;
assign mem_req_wdata=write_data;
assign mem_req_wstrb=state==WRITE_REQ?4'b1111:4'b0000;
assign mem_rsp_ready=rst_n && (state==WRITE_WAIT || state==READ_WAIT);
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=IDLE;span_product<=0;last_byte_q<=0;add_sum<=0;add_carry<=0;fold_result<=0;fold_carry<=0;fold_count<=0;mode<=0;width<=0;height<=0;x<=0;y<=0;base<=0;stride<=0;row_addr<=0;address<=0;write_data<=0;read_data<=0;frame_error<=0;rsp_tag<=0;rsp_error<=0;end
 else if(clk_en)begin
  case(state)
   IDLE:if(cmd_valid)begin
    rsp_tag<=cmd_tag;rsp_error<=0;frame_error<=0;x<=0;y<=0;
    if(cfg_mode>2)begin state<=RESPONSE;rsp_error<=1;end
    else if(bad)begin state<=RESPONSE;rsp_error<=2;end
    else begin
     mode<=cfg_mode[1:0];width<=cfg_src_width;height<=cfg_src_height;base<=cfg_frame_base;stride<=cfg_frame_stride;
     row_addr<=cfg_frame_base;address<=cfg_frame_base;state<=CALC_SPAN;
    end
   end
   CALC_SPAN:if(span_ready)state<=WAIT_SPAN;
   WAIT_SPAN:if(span_valid)begin span_product<=span_result;state<=CALC_LAST;end
   CALC_LAST:begin
    add_sum<=last_a^last_b^last_c;
    add_carry<=((last_a&last_b)|(last_a&last_c)|(last_b&last_c))<<1;
    fold_result<=0;fold_carry<=0;fold_count<=8;state<=FOLD_LAST;
   end
   FOLD_LAST:begin
    add_sum<=add_sum>>8;add_carry<=add_carry>>8;
    fold_result<=fold_next;fold_carry<=fold_byte[8];fold_count<=fold_count-1'b1;
    if(fold_count==1)begin last_byte_q<=fold_next;state<=CHECK_LAST;end
   end
   CHECK_LAST:begin
    if(last_byte_q>64'hffffffff)begin state<=RESPONSE;rsp_error<=2;end
    else state<=mode==2?READ_REQ:CAPTURE;
   end
   CAPTURE:if(s_valid && s_ready)begin
    write_data<=s_data;
    if(s_sof!=(x==0 && y==0) || s_eol!=(x==width-1'b1))frame_error<=1;
    state<=WRITE_REQ;
   end
   WRITE_REQ:if(mem_req_ready)state<=WRITE_WAIT;
   WRITE_WAIT:if(mem_rsp_valid)begin
    if(mem_rsp_error)begin state<=RESPONSE;rsp_error<=3;end
    else if(x==width-1'b1 && y==height-1'b1)begin
     if(mode==0 && !frame_error)begin x<=0;y<=0;address<=base;row_addr<=base;state<=READ_REQ;end
     else begin state<=RESPONSE;rsp_error<=frame_error?2:0;end
    end else begin
     if(x==width-1'b1)begin x<=0;y<=y+1'b1;row_addr<=row_addr+stride;address<=row_addr+stride;end
     else begin x<=x+1'b1;address<=address+4;end
     state<=CAPTURE;
    end
   end
   READ_REQ:if(mem_req_ready)state<=READ_WAIT;
   READ_WAIT:if(mem_rsp_valid)begin
    if(mem_rsp_error)begin state<=RESPONSE;rsp_error<=3;end
    else begin read_data<=mem_rsp_rdata;state<=SEND;end
   end
   SEND:if(m_ready)begin
    if(x==width-1'b1 && y==height-1'b1)state<=RESPONSE;
    else begin
     if(x==width-1'b1)begin x<=0;y<=y+1'b1;row_addr<=row_addr+stride;address<=row_addr+stride;end
     else begin x<=x+1'b1;address<=address+4;end
     state<=READ_REQ;
    end
   end
   RESPONSE:if(rsp_ready)state<=IDLE;
   default:begin state<=RESPONSE;rsp_error<=3;end
  endcase
 end
end
endmodule

// Exact unsigned carry-save shift/add multiplier. B_W CSA iterations,
// then ceil((A_W+B_W)/8) byte-carry fold iterations. Shared CE/ready handshake.
module cip_fb_unsigned_multiply #(parameter A_W=64,B_W=32)(
 input wire clk,rst_n,clk_en,input wire s_valid,output wire s_ready,
 input wire [A_W-1:0] s_a,input wire [B_W-1:0] s_b,
 output reg m_valid,input wire m_ready,output reg [A_W+B_W-1:0] m_product
);
localparam W=A_W+B_W,PAD_W=((W+7)/8)*8,CHUNKS=PAD_W/8;
localparam CW=$clog2(B_W+CHUNKS+1)>0?$clog2(B_W+CHUNKS+1):1;
reg [1:0] state;
reg [PAD_W-1:0] multiplicand,sum_vector,carry_vector,fold_product;
reg [B_W-1:0] multiplier;
reg [CW-1:0] remaining;
reg fold_carry;
wire [PAD_W-1:0] addend=multiplier[0]?multiplicand:{PAD_W{1'b0}};
wire [PAD_W-1:0] csa_sum=sum_vector^carry_vector^addend;
wire [PAD_W-1:0] csa_carry=((sum_vector&carry_vector)|(sum_vector&addend)|(carry_vector&addend))<<1;
wire [8:0] fold_sum={1'b0,sum_vector[7:0]}+{1'b0,carry_vector[7:0]}+fold_carry;
wire [PAD_W-1:0] next_product=(fold_product>>8)|({{(PAD_W-8){1'b0}},fold_sum[7:0]}<<(PAD_W-8));
assign s_ready=rst_n && state==0 && !m_valid;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin state<=0;m_valid<=0;m_product<=0;multiplicand<=0;sum_vector<=0;carry_vector<=0;fold_product<=0;multiplier<=0;remaining<=0;fold_carry<=0;end
 else if(clk_en)begin
 if(m_valid && m_ready)m_valid<=0;
 if(s_valid && s_ready)begin
 multiplicand<=s_a;multiplier<=s_b;sum_vector<=0;carry_vector<=0;remaining<=B_W;state<=1;fold_carry<=0;fold_product<=0;
 end else if(state==1)begin
 sum_vector<=csa_sum;carry_vector<=csa_carry;multiplicand<=multiplicand<<1;multiplier<=multiplier>>1;
 if(remaining==1)begin remaining<=CHUNKS;state<=2;end else remaining<=remaining-1'b1;
 end else if(state==2)begin
 sum_vector<=sum_vector>>8;carry_vector<=carry_vector>>8;fold_carry<=fold_sum[8];fold_product<=next_product;
 if(remaining==1)begin m_product<=next_product[W-1:0];m_valid<=1;state<=0;end else remaining<=remaining-1'b1;
 end
 end
end
endmodule
