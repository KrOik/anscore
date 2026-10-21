// Classic TIFF baseline decoder. Complete-file synchronous byte RAM.
module tiff_decoder #(parameter MAX_WIDTH=16,MAX_HEIGHT=12,MAX_FILE_BYTES=4096)(
 input wire clk,rst_n,ce,start_valid,abort,input wire[7:0]s_data,input wire s_valid,s_last,
 output wire start_ready,s_ready,output reg[23:0]m_pixel,output reg m_valid,
 input wire m_ready,output reg m_sof,m_eol,m_last,output wire done_valid,
 input wire done_ready,output reg frame_error,output reg[7:0]error_code,
 output reg[15:0]image_width,image_height,output reg[1:0]image_mode);
 localparam IDLE=0,INPUT=1,HEADER=2,MAGIC=3,IFDOFF=4,IFDNUM=5,TAG=6,TYPE=7,COUNT=8,VAL=9,DISPATCH=10,NEXTTAG=11,CHECK=12,BITS=13,BITSCHK=14,STRIP=15,OFFSET=16,BYTECOUNT=17,STRIPCHECK=18,PIXEL=19,PIXELDONE=20,OUTPUT=21,DONE=22,RDWAIT=23,RDCAP=24,NEXTIFD=25,ENDCHECK=26;
 reg[5:0]state,ret;
 reg[7:0]mem[0:MAX_FILE_BYTES-1];reg[7:0]rq;
 reg[31:0]raddr,value,file_size,input_pos,ifd,entry,entries,index;
 reg[2:0]rn,ri;reg little;
 reg[15:0]tag,typ;reg[31:0]cnt,val;
 reg[31:0]width,height,bitsval,compression,photo,samples,rowsper,orientation,planar,sampleformat;
 reg[31:0]offptr,offcount,offtype,bcptr,bccount,bctype,bitsptr,bitscount;
 reg[15:0]seen;
 reg[31:0]strip_index,strip_offset,strip_bytes,rowsleft,striprows,rowbytes,needbytes,pixeladdr;
 reg[31:0]x,y,strip_y;reg[2:0]bpp,bits_index;reg[15:0]bits_first;
 wire static_bad=MAX_WIDTH<1||MAX_WIDTH>256||MAX_HEIGHT<1||MAX_HEIGHT>256||MAX_FILE_BYTES<64||MAX_FILE_BYTES>8192;
 assign start_ready=state==IDLE;assign s_ready=state==INPUT;assign done_valid=state==DONE;
 always @(posedge clk)if(ce)begin
  if(state==INPUT&&s_valid&&s_ready&&input_pos<MAX_FILE_BYTES)mem[input_pos]<=s_data;
  if(raddr<MAX_FILE_BYTES)rq<=mem[raddr];
 end
 task fail;input[7:0]code;begin frame_error<=1;error_code<=code;m_valid<=0;state<=DONE;end endtask
 task rd;input[31:0]addr;input[2:0]n;input[5:0]next;begin
  if(addr>file_size||n>file_size-addr)fail(8'h04);
  else begin raddr<=addr;rn<=n;ri<=0;value<=0;ret<=next;state<=RDWAIT;end
 end endtask
 always @(posedge clk)begin
 if(!rst_n)begin state<=IDLE;m_valid<=0;m_pixel<=0;m_sof<=0;m_eol<=0;m_last<=0;frame_error<=0;error_code<=0;image_width<=0;image_height<=0;image_mode<=0;raddr<=0;end
 else if(ce)begin
 if(abort&&state!=IDLE&&state!=DONE)fail(8'h09);
 else case(state)
 IDLE:if(start_valid)begin
  frame_error<=0;error_code<=0;m_valid<=0;input_pos<=0;file_size<=0;seen<=0;width<=0;height<=0;bitsval<=1;compression<=1;photo<=32'hffffffff;samples<=1;rowsper<=32'hffffffff;orientation<=1;planar<=1;sampleformat<=1;offptr<=0;offcount<=0;bcptr<=0;bccount<=0;bitscount<=1;bitsptr<=0;bits_index<=0;image_width<=0;image_height<=0;image_mode<=0;
  if(static_bad)fail(8'h0a);else state<=INPUT;
 end
 INPUT:if(s_valid)begin
  if(input_pos>=MAX_FILE_BYTES)fail(8'h03);
  else if(s_last)begin file_size<=input_pos+1;state<=HEADER;end
  else if(input_pos==MAX_FILE_BYTES-1)fail(8'h03);
  else input_pos<=input_pos+1;
 end
 HEADER:begin little<=1;rd(0,2,MAGIC);end
 MAGIC:begin
  if(value==16'h4949)begin little<=1;rd(2,2,IFDOFF);end
  else if(value==16'h4d4d)begin little<=0;rd(2,2,IFDOFF);end
  else fail(1);
 end
 IFDOFF:if(value!=42)fail(1);else rd(4,4,IFDNUM);
 IFDNUM:begin ifd<=value;if(value<8)fail(4);else rd(value,2,TAG);end
 TAG:begin entries<=value;index<=0;entry<=ifd+2;
  if(value==0||value>(file_size-ifd-2)/12||ifd+2+value*12+4>file_size)fail(4);
  else rd(ifd+2,2,TYPE);
 end
 TYPE:begin tag<=value;rd(entry+2,2,COUNT);end
 COUNT:begin typ<=value;rd(entry+4,4,VAL);end
 VAL:begin cnt<=value;rd(entry+8,typ==3?2:4,DISPATCH);end
 DISPATCH:begin
  val<=value;
  case(tag)
  256:if(seen[0]||cnt!=1||(typ!=3&&typ!=4))fail(5);else begin seen[0]<=1;width<=value;state<=NEXTTAG;end
  257:if(seen[1]||cnt!=1||(typ!=3&&typ!=4))fail(5);else begin seen[1]<=1;height<=value;state<=NEXTTAG;end
  258:if(seen[2]||typ!=3||(cnt!=1&&cnt!=3))fail(5);else begin seen[2]<=1;bitscount<=cnt;if(cnt==1)bitsval<=value;else begin state<=BITS;bits_index<=0;rd(entry+8,4,BITS);end if(cnt==1)state<=NEXTTAG;end
  259:if(seen[3]||cnt!=1||typ!=3)fail(5);else begin seen[3]<=1;compression<=value;state<=NEXTTAG;end
  262:if(seen[4]||cnt!=1||typ!=3)fail(5);else begin seen[4]<=1;photo<=value;state<=NEXTTAG;end
  273:if(seen[5]||cnt==0||(typ!=3&&typ!=4))fail(5);else begin seen[5]<=1;offcount<=cnt;offtype<=typ;if(cnt==1||(cnt==2&&typ==3))offptr<=entry+8;else begin rd(entry+8,4,ENDCHECK);end if(cnt==1||(cnt==2&&typ==3))state<=NEXTTAG;end
  274:if(seen[6]||cnt!=1||typ!=3)fail(5);else begin seen[6]<=1;orientation<=value;state<=NEXTTAG;end
  277:if(seen[7]||cnt!=1||typ!=3)fail(5);else begin seen[7]<=1;samples<=value;state<=NEXTTAG;end
  278:if(seen[8]||cnt!=1||(typ!=3&&typ!=4))fail(5);else begin seen[8]<=1;rowsper<=value;state<=NEXTTAG;end
  279:if(seen[9]||cnt==0||(typ!=3&&typ!=4))fail(5);else begin seen[9]<=1;bccount<=cnt;bctype<=typ;if(cnt==1||(cnt==2&&typ==3))begin bcptr<=entry+8;state<=NEXTTAG;end else rd(entry+8,4,ENDCHECK);end
  284:if(seen[10]||cnt!=1||typ!=3)fail(5);else begin seen[10]<=1;planar<=value;state<=NEXTTAG;end
  339:if(seen[11]||cnt!=1||typ!=3)fail(5);else begin seen[11]<=1;sampleformat<=value;state<=NEXTTAG;end
  266:if(cnt!=1||typ!=3||value!=1)fail(6);else state<=NEXTTAG;
  317:if(cnt!=1||typ!=3||value!=1)fail(6);else state<=NEXTTAG;
  322,323,324,325,338:fail(6);
  default:state<=NEXTTAG;
  endcase
 end
 ENDCHECK:begin if(tag==273)offptr<=value;else bcptr<=value;state<=NEXTTAG;end
 BITS:begin bitsptr<=value;rd(value,2,BITSCHK);end
 BITSCHK:begin
  if(bits_index==0)begin bits_first<=value;bitsval<=value;end
  if(bits_index!=0&&value!=bits_first)fail(6);
  else if(bits_index==2)state<=NEXTTAG;
  else begin bits_index<=bits_index+1;rd(bitsptr+(bits_index+1)*2,2,BITSCHK);end
 end
 NEXTTAG:if(index+1==entries)rd(ifd+2+entries*12,4,NEXTIFD);
  else begin index<=index+1;entry<=entry+12;rd(entry+12,2,TYPE);end
 NEXTIFD:if(value!=0)fail(6);else state<=CHECK;
 CHECK:begin
  if(!seen[0]||!seen[1]||!seen[4]||!seen[5]||!seen[9])fail(5);
  else if(width==0||height==0||width>MAX_WIDTH||height>MAX_HEIGHT)fail(2);
  else if(offcount>height||offptr>file_size||bcptr>file_size||offcount*(offtype==3?2:4)>file_size-offptr||bccount*(bctype==3?2:4)>file_size-bcptr)fail(4);
  else if(compression!=1||orientation!=1||planar!=1||sampleformat!=1||rowsper==0||offcount!=bccount)fail(6);
  else if(samples==1&&(photo==0||photo==1)&&(bitsval==8||bitsval==16)&&bitscount==1)begin
   image_mode<=bitsval==8?0:1;bpp<=bitsval==8?1:2;rowbytes<=width*(bitsval==8?1:2);state<=STRIP;strip_index<=0;rowsleft<=height;x<=0;y<=0;image_width<=width;image_height<=height;
  end else if(samples==3&&photo==2&&bitsval==8&&(bitscount==1||bitscount==3))begin
   image_mode<=2;bpp<=3;rowbytes<=width*3;state<=STRIP;strip_index<=0;rowsleft<=height;x<=0;y<=0;image_width<=width;image_height<=height;
  end else fail(6);
 end
 STRIP:begin
  if(strip_index>=offcount)fail(5);
  else begin striprows<=rowsleft<rowsper?rowsleft:rowsper;strip_y<=0;rd(offptr+strip_index*(offtype==3?2:4),offtype==3?2:4,OFFSET);end
 end
 OFFSET:begin strip_offset<=value;rd(bcptr+strip_index*(bctype==3?2:4),bctype==3?2:4,BYTECOUNT);end
 BYTECOUNT:begin strip_bytes<=value;needbytes<=striprows[8:0]*rowbytes[9:0];state<=STRIPCHECK;end
 STRIPCHECK:begin
  if(strip_bytes!=needbytes||strip_offset>file_size||needbytes>file_size-strip_offset)fail(4);
  else begin pixeladdr<=strip_offset;state<=PIXEL;end
 end
 PIXEL:rd(pixeladdr,bpp,PIXELDONE);
 PIXELDONE:begin
  if(image_mode==2)begin
   if(little)m_pixel<={value[7:0],value[15:8],value[23:16]};else m_pixel<=value[23:0];
  end else if(photo==0)m_pixel<=image_mode==0?{16'b0,~value[7:0]}:{8'b0,~value[15:0]};
  else m_pixel<=value[23:0];
  m_valid<=1;m_sof<=x==0&&y==0;m_eol<=x==width-1;m_last<=x==width-1&&y==height-1;state<=OUTPUT;
 end
 OUTPUT:if(m_ready)begin
  m_valid<=0;
  if(x==width-1)begin x<=0;y<=y+1;
   if(strip_y+1==striprows)begin
    if(rowsleft==striprows)begin if(strip_index+1!=offcount)fail(5);else state<=DONE;end
    else begin rowsleft<=rowsleft-striprows;strip_index<=strip_index+1;state<=STRIP;end
   end else begin strip_y<=strip_y+1;pixeladdr<=pixeladdr+bpp;state<=PIXEL;end
  end else begin x<=x+1;pixeladdr<=pixeladdr+bpp;state<=PIXEL;end
 end
 RDWAIT:state<=RDCAP;
 RDCAP:begin
  if(little)value<=value|({24'b0,rq}<<(ri*8));else value<=(value<<8)|rq;
  if(ri+1==rn)state<=ret;
  else begin ri<=ri+1;raddr<=raddr+1;state<=RDWAIT;end
 end
 DONE:if(done_ready)state<=IDLE;
 default:fail(8);
 endcase
 end
 end
endmodule
