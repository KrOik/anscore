from pathlib import Path
HERE=Path(__file__).resolve().parent
COMMON=HERE.parents[3]
source=(HERE/'bilateral_borrow_v4/source/img_filter_bilateral3x3.v').read_text()
source=source.replace('WEIGHT_CAPTURE=17;', 'WEIGHT_CAPTURE=17,PRODUCT_WAIT=18;')
source=source.replace('wire [NUM_W-1:0] weighted_sample=sample_q*weight_q;', '''wire product_ready,product_valid;
    wire [PIXEL_W+15:0] weighted_sample;
    cip_bilateral_unsigned_multiply #(.A_W(PIXEL_W),.B_W(16)) weight_multiplier(
        .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
        .s_valid(state==WEIGHT_PRODUCT),.s_ready(product_ready),.s_a(sample_q),.s_b(weight_q),
        .m_valid(product_valid),.m_ready(state==PRODUCT_WAIT),.m_product(weighted_sample));''')
source=source.replace('WEIGHT_PRODUCT:begin product_q<=weighted_sample;state<=ACCUM;end', '''WEIGHT_PRODUCT:if(product_ready)state<=PRODUCT_WAIT;
                PRODUCT_WAIT:if(product_valid)begin product_q<=weighted_sample;state<=ACCUM;end''')
helper=(COMMON/'image/histogram/rtl/img_hist_serial_multiply.v').read_text().replace('module img_hist_serial_multiply','module cip_bilateral_unsigned_multiply')
target=HERE/'bilateral_product_source'
target.mkdir(exist_ok=True)
(target/'img_filter_bilateral3x3.v').write_text(source+'\n'+helper)
