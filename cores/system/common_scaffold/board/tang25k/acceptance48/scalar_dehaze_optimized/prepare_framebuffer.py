from pathlib import Path
HERE=Path(__file__).resolve().parent;COMMON=HERE.parents[3]
text=(COMMON/'signal_video/rtl/cip_image_framebuffer.v').read_text()
text=text.replace('RESPONSE=7;', 'RESPONSE=7,CALC_SPAN=8,CALC_LAST=9,CHECK_LAST=10;')
text=text.replace('reg [2:0] state;', 'reg [3:0] state;\nreg [47:0] span_product;\nreg [63:0] last_byte_q;')
text=text.replace(' || last_byte>64\'hffffffff;', ';')
text=text.replace('state<=IDLE;mode<=0;', 'state<=IDLE;span_product<=0;last_byte_q<=0;mode<=0;')
text=text.replace('state<=cfg_mode==2?READ_REQ:CAPTURE;', 'state<=CALC_SPAN;')
text=text.replace('   CAPTURE:if(s_valid && s_ready)begin', '''   CALC_SPAN:begin span_product<=(height-16'd1)*stride;state<=CALC_LAST;end
   CALC_LAST:begin last_byte_q<={32'd0,base}+{16'd0,span_product}+64'd4*width-1;state<=CHECK_LAST;end
   CHECK_LAST:begin
    if(last_byte_q>64'hffffffff)begin state<=RESPONSE;rsp_error<=2;end
    else state<=mode==2?READ_REQ:CAPTURE;
   end
   CAPTURE:if(s_valid && s_ready)begin''')
(HERE/'cip_image_framebuffer.v').write_text(text)
