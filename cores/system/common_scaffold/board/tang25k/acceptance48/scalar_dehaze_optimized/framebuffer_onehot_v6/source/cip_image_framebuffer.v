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
localparam IDLE=11'h001,CAPTURE=11'h002,WRITE_REQ=11'h004,WRITE_WAIT=11'h008,READ_REQ=11'h010,READ_WAIT=11'h020,SEND=11'h040,RESPONSE=11'h080,CALC_SPAN=11'h100,CALC_LAST=11'h200,CHECK_LAST=11'h400;
localparam SUPPORTED=DATA_W>=1 && DATA_W<=32 && MAX_WIDTH>=1 && MAX_WIDTH<=65535 && MAX_HEIGHT>=1 && MAX_HEIGHT<=65535;
reg [10:0] state;
reg [47:0] span_product;
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
 if(!rst_n)begin state<=IDLE;span_product<=0;last_byte_q<=0;mode<=0;width<=0;height<=0;x<=0;y<=0;base<=0;stride<=0;row_addr<=0;address<=0;write_data<=0;read_data<=0;frame_error<=0;rsp_tag<=0;rsp_error<=0;end
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
   CALC_SPAN:begin span_product<=(height-16'd1)*stride;state<=CALC_LAST;end
   CALC_LAST:begin last_byte_q<={32'd0,base}+{16'd0,span_product}+64'd4*width-1;state<=CHECK_LAST;end
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
