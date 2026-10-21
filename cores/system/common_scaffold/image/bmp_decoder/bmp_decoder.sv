module bmp_decoder #(
 parameter MAX_WIDTH=64, MAX_HEIGHT=64
)(input wire clk,rst_n,ce,start_valid,abort,
 output wire start_ready,input wire[7:0] s_data,input wire s_valid,s_last,output wire s_ready,
 output wire[23:0] m_rgb,output wire m_valid,m_sof,m_eol,m_last,input wire m_ready,
 output wire done_valid,input wire done_ready,output wire frame_error,output reg[7:0] error_code,
 output reg[15:0] image_width,image_height);
localparam IDLE=0,HEADER=1,VALIDATE=2,INPUT=3,READ=4,OUTPUT=5,DONE=6;
localparam AW=$clog2(MAX_WIDTH*MAX_HEIGHT+1);
reg[2:0]state;reg[31:0]pos,file_size,offset,dib,width_raw,height_raw,compression,image_size;
reg[15:0]planes,bpp;reg signature_ok,reserved_ok,top_down;
reg[31:0]stride,pixel_end;reg[15:0]ix,iy,ox,oy;reg[31:0]rowbyte;
reg[1:0]channel;reg[7:0]blue,green;reg[23:0]pixel;reg[23:0] mem[0:MAX_WIDTH*MAX_HEIGHT-1];
wire[31:0]height_abs=height_raw[31]?(~height_raw+1):height_raw;
wire[31:0]calc_stride=(width_raw*3+3)&32'hfffffffc;
wire[63:0]calc_end={32'b0,offset}+({32'b0,calc_stride}*height_abs);
wire[31:0]wr_y=top_down?iy:(image_height-1-iy);
wire[AW-1:0]wr_addr=wr_y*image_width+ix;
wire[AW-1:0]rd_addr=oy*image_width+ox;
assign start_ready=state==IDLE;assign s_ready=state==HEADER||state==INPUT;
assign m_rgb=pixel;assign m_valid=state==OUTPUT;
assign m_sof=ox==0&&oy==0;assign m_eol=ox==image_width-1;
assign m_last=m_eol&&oy==image_height-1;assign done_valid=state==DONE;assign frame_error=error_code!=0;
task fail;input[7:0]code;begin error_code<=code;state<=DONE;end endtask
always @(posedge clk)begin
 if(!rst_n)begin state<=IDLE;error_code<=0;image_width<=0;image_height<=0;pixel<=0;ox<=0;oy<=0;end
 else if(ce)begin
 if(abort&&state!=IDLE&&state!=DONE)fail(8'h08);
 else case(state)
 IDLE:if(start_valid)begin
 error_code<=0;image_width<=0;image_height<=0;pos<=0;file_size<=0;offset<=0;dib<=0;width_raw<=0;height_raw<=0;planes<=0;bpp<=0;compression<=0;image_size<=0;signature_ok<=1;reserved_ok<=1;ox<=0;oy<=0;
 if(MAX_WIDTH<1||MAX_WIDTH>256||MAX_HEIGHT<1||MAX_HEIGHT>256)fail(8'h09);else state<=HEADER;
 end
 HEADER:if(s_valid)begin
 if(pos==0&&s_data!=8'h42)signature_ok<=0;if(pos==1&&s_data!=8'h4d)signature_ok<=0;
 if(pos>=2&&pos<=5)file_size[(pos-2)*8+:8]<=s_data;
 if(pos>=6&&pos<=9&&s_data!=0)reserved_ok<=0;
 if(pos>=10&&pos<=13)offset[(pos-10)*8+:8]<=s_data;
 if(pos>=14&&pos<=17)dib[(pos-14)*8+:8]<=s_data;
 if(pos>=18&&pos<=21)width_raw[(pos-18)*8+:8]<=s_data;
 if(pos>=22&&pos<=25)height_raw[(pos-22)*8+:8]<=s_data;
 if(pos>=26&&pos<=27)planes[(pos-26)*8+:8]<=s_data;
 if(pos>=28&&pos<=29)bpp[(pos-28)*8+:8]<=s_data;
 if(pos>=30&&pos<=33)compression[(pos-30)*8+:8]<=s_data;
 if(pos>=34&&pos<=37)image_size[(pos-34)*8+:8]<=s_data;
 pos<=pos+1;if(s_last)fail(8'h01);else if(pos==53)state<=VALIDATE;
 end
 VALIDATE:begin
 if(!signature_ok||!reserved_ok||dib!=40||planes!=1||bpp!=24||compression!=0)fail(8'h02);
 else if(width_raw==0||width_raw>MAX_WIDTH||height_abs==0||height_abs>MAX_HEIGHT)fail(8'h03);
 else if(offset<54||calc_end[63:32]!=0||file_size<calc_end[31:0]||(image_size!=0&&image_size!=calc_stride*height_abs))fail(8'h04);
 else begin image_width<=width_raw;image_height<=height_abs;top_down<=height_raw[31];stride<=calc_stride;pixel_end<=calc_end;ix<=0;iy<=0;rowbyte<=0;channel<=0;state<=INPUT;end
 end
 INPUT:if(s_valid)begin
 pos<=pos+1;
 if(pos>=offset&&pos<pixel_end)begin
 if(rowbyte<image_width*3)begin
 channel<=channel==2?0:channel+1;case(channel)0:blue<=s_data;1:green<=s_data;2:begin mem[wr_addr]<={s_data,green,blue};ix<=ix+1;end endcase
 end
 if(rowbyte==stride-1)begin rowbyte<=0;channel<=0;ix<=0;iy<=iy+1;end else rowbyte<=rowbyte+1;
 end
 if(s_last)begin if(pos!=file_size-1)fail(8'h05);else state<=READ;end
 else if(pos==file_size-1)fail(8'h06);
 end
 READ:begin pixel<=mem[rd_addr];state<=OUTPUT;end
 OUTPUT:if(m_ready)begin
 if(m_last)state<=DONE;else begin if(m_eol)begin ox<=0;oy<=oy+1;end else ox<=ox+1;state<=READ;end end
 DONE:if(done_ready)state<=IDLE;
 default:fail(8'h07);
 endcase
 end
end
endmodule

