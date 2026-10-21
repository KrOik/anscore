from pathlib import Path
HERE=Path(__file__).resolve().parent
COMMON=HERE.parents[3]
source=(HERE/'framebuffer_v5/source/cip_image_framebuffer.v').read_text()
source=source.replace('CHECK_LAST=10;', 'CHECK_LAST=10,WAIT_SPAN=11,FOLD_LAST=12;')
source=source.replace('reg [47:0] span_product;', '''reg [47:0] span_product;
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
wire [63:0] fold_next={fold_byte[7:0],fold_result[63:8]};''')
source=source.replace('span_product<=0;last_byte_q<=0;', 'span_product<=0;last_byte_q<=0;add_sum<=0;add_carry<=0;fold_result<=0;fold_carry<=0;fold_count<=0;')
source=source.replace("CALC_SPAN:begin span_product<=(height-16'd1)*stride;state<=CALC_LAST;end", '''CALC_SPAN:if(span_ready)state<=WAIT_SPAN;
   WAIT_SPAN:if(span_valid)begin span_product<=span_result;state<=CALC_LAST;end''')
source=source.replace("CALC_LAST:begin last_byte_q<={32'd0,base}+{16'd0,span_product}+64'd4*width-1;state<=CHECK_LAST;end", '''CALC_LAST:begin
    add_sum<=last_a^last_b^last_c;
    add_carry<=((last_a&last_b)|(last_a&last_c)|(last_b&last_c))<<1;
    fold_result<=0;fold_carry<=0;fold_count<=8;state<=FOLD_LAST;
   end
   FOLD_LAST:begin
    add_sum<=add_sum>>8;add_carry<=add_carry>>8;
    fold_result<=fold_next;fold_carry<=fold_byte[8];fold_count<=fold_count-1'b1;
    if(fold_count==1)begin last_byte_q<=fold_next;state<=CHECK_LAST;end
   end''')
begin=source.index('wire span_ready,span_valid;')
end=source.index('reg [63:0] last_byte_q;',begin)
declarations=source[begin:end]
source=source[:begin]+source[end:]
anchor='reg [31:0] base,stride,row_addr,address,write_data;'
source=source.replace(anchor,anchor+'\n'+declarations)
helper=(COMMON/'image/histogram/rtl/img_hist_serial_multiply.v').read_text().replace('module img_hist_serial_multiply','module cip_fb_unsigned_multiply')
target=HERE/'framebuffer_serial_source'
target.mkdir(exist_ok=True)
(target/'cip_image_framebuffer.v').write_text(source+'\n'+helper)
