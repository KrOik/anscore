from pathlib import Path
HERE=Path(__file__).resolve().parent
source=(HERE/'framebuffer_serial_v8/source/cip_image_framebuffer.v').read_text()
source=source.replace('reg [15:0] width,height,x,y;', 'reg [15:0] width,height,x,y,width_last,height_last;\nreg [31:0] row_next;')
source=source.replace('wire bad=', '''function [15:0] inc16;
 input [15:0] value;
 begin inc16[7:0]=value[7:0]+8'd1;inc16[15:8]=value[15:8]+(&value[7:0]);end
endfunction
function [31:0] plus4;
 input [31:0] value;
 begin
  plus4[7:0]=value[7:0]+8'd4;
  plus4[15:8]=value[15:8]+(&value[7:2]);
  plus4[23:16]=value[23:16]+(&value[15:2]);
  plus4[31:24]=value[31:24]+(&value[23:2]);
 end
endfunction
wire bad=''',1)
source=source.replace('width<=0;height<=0;x<=0;y<=0;', 'width<=0;height<=0;x<=0;y<=0;width_last<=0;height_last<=0;row_next<=0;')
source=source.replace('mode<=cfg_mode[1:0];width<=cfg_src_width;height<=cfg_src_height;', "mode<=cfg_mode[1:0];width<=cfg_src_width;height<=cfg_src_height;width_last<=cfg_src_width-1'b1;height_last<=cfg_src_height-1'b1;")
source=source.replace("width-1'b1",'width_last').replace("height-1'b1",'height_last')
# Undo accidental replacement inside cfg_src_width/height subtraction above.
source=source.replace('width_last<=cfg_src_width_last;',"width_last<=cfg_src_width-1'b1;")
source=source.replace('height_last<=cfg_src_height_last;',"height_last<=cfg_src_height-1'b1;")
source=source.replace('WRITE_REQ:if(mem_req_ready)state<=WRITE_WAIT;', 'WRITE_REQ:begin row_next<=row_addr+stride;if(mem_req_ready)state<=WRITE_WAIT;end')
source=source.replace('READ_REQ:if(mem_req_ready)state<=READ_WAIT;', 'READ_REQ:begin row_next<=row_addr+stride;if(mem_req_ready)state<=READ_WAIT;end')
source=source.replace("x<=x+1'b1;address<=address+4;",'x<=inc16(x);address<=plus4(address);')
source=source.replace("y<=y+1'b1;row_addr<=row_addr+stride;address<=row_addr+stride;",'y<=inc16(y);row_addr<=row_next;address<=row_next;')
target=HERE/'framebuffer_counts_source'
target.mkdir(exist_ok=True)
(target/'cip_image_framebuffer.v').write_text(source)
