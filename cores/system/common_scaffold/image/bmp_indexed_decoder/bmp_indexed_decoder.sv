// Windows BITMAPINFOHEADER indexed BMP / BI_RLE4 / BI_RLE8 decoder.
// Full indexed frame buffer; RGB output begins only after complete valid file.
module bmp_indexed_decoder #(parameter MAX_WIDTH=64,MAX_HEIGHT=64,MAX_FILE_BYTES=65536)(
 input wire clk,rst_n,ce,start,abort,output wire start_ready,
 input wire[7:0]s_data,input wire s_valid,s_last,output wire s_ready,
 output reg[23:0]m_rgb,output reg m_valid,m_sof,m_eol,m_last,input wire m_ready,
 output wire done_valid,input wire done_ready,output reg[7:0]error_code,
 output reg[15:0]width,height,output wire busy);
 localparam IDLE=0,CLEAR=1,HDR=2,CHECK=3,PAL=4,GAP=5,RAW=6,BITS=7,
 RCNT=8,RVAL=9,RWRITE=10,LIT=11,LPAD=12,DX=13,DY=14,TAIL=15,
 READ=16,LOOKUP=17,HOLD=18,DONE=19,FAIL=20;
 localparam N=MAX_WIDTH*MAX_HEIGHT;
 reg[4:0]state;reg[7:0]indices[0:N-1];reg[23:0]palette[0:255];
 reg[31:0]pos,file_size,offset,dib,wraw,hraw,compression,image_size,colors;
 reg[15:0]planes,bpp;reg topdown,eof;reg[31:0]clear_index;
 reg[8:0]pal_count,pal_index;reg[1:0]pal_byte;reg[23:0]pal_temp;
 reg[15:0]x,y,ox,oy;reg[31:0]row_bytes,stride,row_pos;
 reg[7:0]data_byte,count,remaining,index_q,delta_x;reg[3:0]bit_slot;
 reg literal_mode;reg[8:0]literal_bytes;reg literal_pad;
 wire need_byte=state==HDR||state==PAL||state==GAP||state==RAW||state==RCNT||state==RVAL||state==LIT||state==LPAD||state==DX||state==DY||state==TAIL;
 assign start_ready=rst_n&&ce&&state==IDLE;
 assign s_ready=rst_n&&ce&&need_byte&&!eof&&!(state==GAP&&pos==offset);
 assign done_valid=rst_n&&(state==DONE||state==FAIL);
 assign busy=state!=IDLE;
 wire take=s_valid&&s_ready;
 wire[7:0]pixel_index=bpp==8?data_byte:bpp==4?(bit_slot[0]?{4'b0,data_byte[3:0]}:{4'b0,data_byte[7:4]}):{7'b0,data_byte[7-bit_slot]};
 wire[31:0]write_address=(topdown?y:height-1-y)*width+x;
 task fail;input[7:0]code;begin error_code<=code;state<=FAIL;m_valid<=0;end endtask
 task emit_index;input[7:0]idx;begin
 if(x>=width||y>=height||idx>=pal_count)fail(8'h07);
 else begin indices[write_address]<=idx;x<=x+1'b1;end
 end endtask
 initial if(MAX_WIDTH<1||MAX_HEIGHT<1||N>16384||MAX_WIDTH>256||MAX_HEIGHT>256||MAX_FILE_BYTES<54)$fatal(1,"invalid indexed BMP parameters");
 always @(posedge clk)begin
 if(!rst_n)begin state<=IDLE;error_code<=0;pos<=0;file_size<=0;offset<=0;dib<=0;wraw<=0;hraw<=0;compression<=0;image_size<=0;colors<=0;planes<=0;bpp<=0;width<=0;height<=0;topdown<=0;eof<=0;clear_index<=0;pal_count<=0;pal_index<=0;pal_byte<=0;pal_temp<=0;x<=0;y<=0;ox<=0;oy<=0;row_bytes<=0;stride<=0;row_pos<=0;data_byte<=0;count<=0;remaining<=0;index_q<=0;delta_x<=0;bit_slot<=0;literal_mode<=0;literal_bytes<=0;literal_pad<=0;m_rgb<=0;m_valid<=0;m_sof<=0;m_eol<=0;m_last<=0;end
 else if(ce)begin
 if(abort&&state!=IDLE&&state!=DONE&&state!=FAIL)fail(8'h0a);
 else if(need_byte&&eof&&state!=TAIL)fail(8'h08);
 else if((state==BITS||state==RWRITE)&&(x>=width||y>=height||pixel_index>=pal_count))fail(8'h07);
 else if(take&&pos>=6&&file_size!=0&&pos>=file_size)fail(8'h08);
 else if(take&&pos>=MAX_FILE_BYTES)fail(8'h09);
 else if(take&&pos>=6&&s_last&&(pos+1!=file_size))fail(8'h08);
 else begin
 if(take)begin pos<=pos+1'b1;if(s_last)eof<=1;end
 case(state)
 IDLE:if(start)begin state<=CLEAR;error_code<=0;pos<=0;file_size<=0;offset<=0;dib<=0;wraw<=0;hraw<=0;compression<=0;image_size<=0;colors<=0;planes<=0;bpp<=0;eof<=0;clear_index<=0;pal_index<=0;pal_byte<=0;x<=0;y<=0;ox<=0;oy<=0;m_valid<=0;end
 CLEAR:begin indices[clear_index]<=0;if(clear_index==N-1)state<=HDR;else clear_index<=clear_index+1;end
 HDR:if(take)begin
 case(pos)
 0:if(s_data!=8'h42)fail(1);
 1:if(s_data!=8'h4d)fail(1);
 2,3,4,5:file_size<=file_size|({24'b0,s_data}<<((pos-2)*8));
 6,7,8,9:if(s_data!=0)fail(1);
 10,11,12,13:offset<=offset|({24'b0,s_data}<<((pos-10)*8));
 14,15,16,17:dib<=dib|({24'b0,s_data}<<((pos-14)*8));
 18,19,20,21:wraw<=wraw|({24'b0,s_data}<<((pos-18)*8));
 22,23,24,25:hraw<=hraw|({24'b0,s_data}<<((pos-22)*8));
 26,27:planes<=planes|({8'b0,s_data}<<((pos-26)*8));
 28,29:bpp<=bpp|({8'b0,s_data}<<((pos-28)*8));
 30,31,32,33:compression<=compression|({24'b0,s_data}<<((pos-30)*8));
 34,35,36,37:image_size<=image_size|({24'b0,s_data}<<((pos-34)*8));
 46,47,48,49:colors<=colors|({24'b0,s_data}<<((pos-46)*8));
 endcase
 if(pos==53)state<=CHECK;
 end
 CHECK:begin
 if(dib!=40||planes!=1||!(bpp==1||bpp==4||bpp==8))fail(2);
 else if(wraw==0||wraw>MAX_WIDTH||hraw==0||hraw==32'h80000000||(hraw[31]?(~hraw+1):hraw)>MAX_HEIGHT)fail(3);
 else if(!(compression==0||(compression==1&&bpp==8)||(compression==2&&bpp==4))||(hraw[31]&&compression!=0))fail(4);
 else if(colors>(1<<bpp)||file_size>MAX_FILE_BYTES||file_size<offset||offset<54+4*(colors==0?(1<<bpp):colors))fail(5);
 else begin
 width<=wraw[15:0];height<=hraw[31]?(~hraw+1):hraw;topdown<=hraw[31];pal_count<=colors==0?(1<<bpp):colors;
 row_bytes<=((wraw*bpp)+7)>>3;stride<=(((wraw*bpp)+31)>>5)<<2;row_pos<=0;state<=PAL;
 end end
 PAL:if(take)begin
 case(pal_byte)0:pal_temp[7:0]<=s_data;1:pal_temp[15:8]<=s_data;2:pal_temp[23:16]<=s_data;3:begin palette[pal_index]<=pal_temp;if(pal_index+1==pal_count)state<=GAP;else pal_index<=pal_index+1'b1;end endcase
 pal_byte<=pal_byte+1'b1;
 end
 GAP:begin
 if(pos==offset)begin
 if(compression==0)begin if(file_size<offset+stride*height||(image_size!=0&&image_size!=stride*height))fail(5);else state<=RAW;end
 else if(image_size!=0&&image_size>file_size-offset)fail(5);else state<=RCNT;
 end else if(pos>offset)fail(5);
 end
 RAW:if(take)begin
 row_pos<=row_pos+1'b1;
 if(row_pos<row_bytes)begin data_byte<=s_data;bit_slot<=0;state<=BITS;end
 else if(row_pos+1==stride)begin row_pos<=0;x<=0;if(y+1==height)state<=TAIL;else y<=y+1'b1;end
 end
 BITS:begin
 emit_index(pixel_index);
 if(x+1==width||bit_slot+1==(bpp==1?8:bpp==4?2:1))begin
 if(row_pos==stride)begin row_pos<=0;x<=0;if(y+1==height)state<=TAIL;else begin y<=y+1'b1;state<=RAW;end end
 else state<=RAW;
 end else bit_slot<=bit_slot+1'b1;
 end
 RCNT:if(take)begin count<=s_data;state<=RVAL;end
 RVAL:if(take)begin
 if(count!=0)begin data_byte<=s_data;remaining<=count;bit_slot<=0;literal_mode<=0;if(x+count>width||y>=height)fail(6);else state<=RWRITE;end
 else case(s_data)
 0:begin if(y>=height)fail(6);else begin x<=0;y<=y+1'b1;state<=RCNT;end end
 1:state<=TAIL;
 2:state<=DX;
 default:begin remaining<=s_data;literal_bytes<=bpp==4?({1'b0,s_data}+1)>>1:{1'b0,s_data};literal_pad<=bpp==4?(((s_data+1)>>1)&1):s_data[0];literal_mode<=1;if(x+s_data>width||y>=height)fail(6);else state<=LIT;end
 endcase
 end
 RWRITE:begin
 emit_index(pixel_index);remaining<=remaining-1'b1;bit_slot<=bit_slot+1'b1;
 if(remaining==1)state<=literal_mode?(literal_pad?LPAD:RCNT):RCNT;
 else if(literal_mode&&(bpp==8||bit_slot[0]))state<=LIT;
 end
 LIT:if(take)begin data_byte<=s_data;bit_slot<=0;literal_bytes<=literal_bytes-1'b1;state<=RWRITE;end
 LPAD:if(take)state<=RCNT;
 DX:if(take)begin delta_x<=s_data;state<=DY;end
 DY:if(take)begin if(x+delta_x>=width||y+s_data>=height)fail(6);else begin x<=x+delta_x;y<=y+s_data;state<=RCNT;end end
 TAIL:begin if(eof)begin ox<=0;oy<=0;state<=READ;end else if(pos>=file_size)fail(8);end
 READ:begin index_q<=indices[oy*width+ox];state<=LOOKUP;end
 LOOKUP:begin m_rgb<=palette[index_q];m_sof<=ox==0&&oy==0;m_eol<=ox+1==width;m_last<=ox+1==width&&oy+1==height;m_valid<=1;state<=HOLD;end
 HOLD:if(m_ready)begin m_valid<=0;if(m_last)state<=DONE;else begin if(ox+1==width)begin ox<=0;oy<=oy+1;end else ox<=ox+1;state<=READ;end end
 DONE,FAIL:if(done_ready)state<=IDLE;
 default:fail(8'hff);
 endcase
 end
 end
 end
endmodule
