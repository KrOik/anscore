// Original complete PNG8 encoder: filter None, zlib DEFLATE stored blocks.
// Standards-valid lossless coding, without compression-ratio benefit.
module png_encoder #(
 parameter integer WIDTH=16,HEIGHT=12
)(input wire clk,rst_n,ce,start_valid,output wire start_ready,
 input wire[1:0]cfg_mode,input wire abort,
 input wire[23:0]s_pixel,input wire s_valid,s_sof,s_eol,s_last,output wire s_ready,
 output reg[7:0]m_data,output wire m_valid,m_sof,m_last,input wire m_ready,
 output wire done_valid,input wire done_ready,output reg done_error,output reg[7:0]error_code,
 output wire busy,output reg[31:0]output_bytes);
 localparam[31:0] RAW_GRAY=(WIDTH+1)*HEIGHT,RAW_RGB=(WIDTH*3+1)*HEIGHT;
 localparam[31:0] IDAT_GRAY=2+RAW_GRAY+5*((RAW_GRAY+65534)/65535)+4;
 localparam[31:0] IDAT_RGB=2+RAW_RGB+5*((RAW_RGB+65534)/65535)+4;
 localparam IDLE=0,SIGNATURE=1,IHDR_LEN=2,IHDR_TYPE=3,IHDR_DATA=4,IHDR_CRC=5,
 IDAT_LEN=6,IDAT_TYPE=7,ZLIB_HEADER=8,BLOCK_HEADER=9,RAW_DATA=10,ADLER=11,IDAT_CRC=12,
 IEND_LEN=13,IEND_TYPE=14,IEND_CRC=15,DONE=16;
 reg[4:0]state;reg[3:0]index;reg rgb,filter_pending,pixel_valid;
 reg[23:0]pixel_q;reg[1:0]channel;
 reg[15:0]x,y,block_length,block_remaining;
 reg[31:0]raw_remaining,idat_length,crc;
 reg[15:0]adler_a,adler_b;
 wire[7:0]raw_byte=filter_pending?8'd0:(!rgb?pixel_q[7:0]:(channel==0?pixel_q[23:16]:(channel==1?pixel_q[15:8]:pixel_q[7:0])));
 wire[16:0]adler_sum_a={1'b0,adler_a}+raw_byte;
 wire[15:0]adler_next_a=adler_sum_a>=65521?adler_sum_a-17'd65521:adler_sum_a[15:0];
 wire[16:0]adler_sum_b={1'b0,adler_b}+adler_next_a;
 wire[15:0]adler_next_b=adler_sum_b>=65521?adler_sum_b-17'd65521:adler_sum_b[15:0];
 wire[31:0]crc_final=~crc,adler_final={adler_b,adler_a};
 wire[15:0]nlength=~block_length;
 function[31:0]crc32_byte;input[31:0]current;input[7:0]value;reg[31:0]q;integer j;
 begin q=current^{24'd0,value};for(j=0;j<8;j=j+1)q=q[0]?(q>>1)^32'hedb88320:q>>1;crc32_byte=q;end endfunction
 function[7:0]be32;input[31:0]word;input[3:0]i;begin case(i)0:be32=word[31:24];1:be32=word[23:16];2:be32=word[15:8];default:be32=word[7:0];endcase end endfunction
 assign start_ready=rst_n&&ce&&!abort&&state==IDLE;
 assign s_ready=rst_n&&ce&&!abort&&state==RAW_DATA&&!filter_pending&&!pixel_valid;
 assign m_valid=!abort&&state!=IDLE&&state!=DONE&&(state!=RAW_DATA||filter_pending||pixel_valid);
 assign m_sof=state==SIGNATURE&&index==0;assign m_last=state==IEND_CRC&&index==3;
 assign done_valid=state==DONE;assign busy=state!=IDLE&&state!=DONE;
 always @*begin
 m_data=0;
 case(state)
 SIGNATURE:case(index)0:m_data=137;1:m_data=80;2:m_data=78;3:m_data=71;4:m_data=13;5:m_data=10;6:m_data=26;default:m_data=10;endcase
 IHDR_LEN:m_data=be32(32'd13,index);
 IHDR_TYPE:case(index)0:m_data="I";1:m_data="H";2:m_data="D";default:m_data="R";endcase
 IHDR_DATA:if(index<4)m_data=be32(WIDTH,index);else if(index<8)m_data=be32(HEIGHT,index-4);else if(index==8)m_data=8;else if(index==9)m_data=rgb?2:0;
 IHDR_CRC,IDAT_CRC,IEND_CRC:m_data=be32(crc_final,index);
 IDAT_LEN:m_data=be32(idat_length,index);
 IDAT_TYPE:case(index)0:m_data="I";1:m_data="D";2:m_data="A";default:m_data="T";endcase
 ZLIB_HEADER:m_data=index==0?8'h78:8'h01;
 BLOCK_HEADER:case(index)
 0:m_data=raw_remaining<=65535?1:0;1:m_data=block_length[7:0];2:m_data=block_length[15:8];3:m_data=nlength[7:0];default:m_data=nlength[15:8];endcase
 RAW_DATA:m_data=raw_byte;
 ADLER:m_data=be32(adler_final,index);
 IEND_TYPE:case(index)0:m_data="I";1:m_data="E";2:m_data="N";default:m_data="D";endcase
 default:m_data=0;
 endcase end
 task fail;input[7:0]code;begin done_error<=1;error_code<=code;state<=DONE;pixel_valid<=0;end endtask
 always @(posedge clk)begin
 if(!rst_n)begin
 state<=IDLE;index<=0;rgb<=0;filter_pending<=1;pixel_valid<=0;pixel_q<=0;channel<=0;x<=0;y<=0;
 block_length<=0;block_remaining<=0;raw_remaining<=0;idat_length<=0;crc<=32'hffffffff;adler_a<=1;adler_b<=0;
 done_error<=0;error_code<=0;output_bytes<=0;
 end else if(ce)begin
 if(abort&&state!=IDLE&&state!=DONE)fail(8'h93);
 else if(state==IDLE)begin
 if(start_valid&&!abort)begin
 index<=0;rgb<=cfg_mode==1;filter_pending<=1;pixel_valid<=0;channel<=0;x<=0;y<=0;
 raw_remaining<=cfg_mode==1?RAW_RGB:RAW_GRAY;idat_length<=cfg_mode==1?IDAT_RGB:IDAT_GRAY;
 block_length<=(cfg_mode==1?RAW_RGB:RAW_GRAY)>65535?16'd65535:(cfg_mode==1?RAW_RGB:RAW_GRAY);
 block_remaining<=(cfg_mode==1?RAW_RGB:RAW_GRAY)>65535?16'd65535:(cfg_mode==1?RAW_RGB:RAW_GRAY);
 crc<=32'hffffffff;adler_a<=1;adler_b<=0;done_error<=0;error_code<=0;output_bytes<=0;
 if(WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096)fail(8'h80);
 else if(cfg_mode>1)fail(8'h82);else state<=SIGNATURE;
 end end
 else if(state==DONE)begin if(done_ready)state<=IDLE;end
 else begin
 if(s_valid&&s_ready)begin
 if(s_sof!=(x==0&&y==0)||s_eol!=(x==WIDTH-1)||s_last!=(x==WIDTH-1&&y==HEIGHT-1))fail(8'h81);
 else begin pixel_q<=s_pixel;pixel_valid<=1;channel<=0;end
 end
 if(m_valid&&m_ready)begin
 output_bytes<=output_bytes+1'b1;
 if(state==IHDR_TYPE||state==IHDR_DATA||state==IDAT_TYPE||state==ZLIB_HEADER||state==BLOCK_HEADER||state==RAW_DATA||state==ADLER||state==IEND_TYPE)
 crc<=crc32_byte(crc,m_data);
 case(state)
 SIGNATURE:if(index==7)begin state<=IHDR_LEN;index<=0;end else index<=index+1'b1;
 IHDR_LEN:if(index==3)begin state<=IHDR_TYPE;index<=0;crc<=32'hffffffff;end else index<=index+1'b1;
 IHDR_TYPE:if(index==3)begin state<=IHDR_DATA;index<=0;end else index<=index+1'b1;
 IHDR_DATA:if(index==12)begin state<=IHDR_CRC;index<=0;end else index<=index+1'b1;
 IHDR_CRC:if(index==3)begin state<=IDAT_LEN;index<=0;end else index<=index+1'b1;
 IDAT_LEN:if(index==3)begin state<=IDAT_TYPE;index<=0;crc<=32'hffffffff;end else index<=index+1'b1;
 IDAT_TYPE:if(index==3)begin state<=ZLIB_HEADER;index<=0;end else index<=index+1'b1;
 ZLIB_HEADER:if(index==1)begin state<=BLOCK_HEADER;index<=0;end else index<=index+1'b1;
 BLOCK_HEADER:if(index==4)begin state<=RAW_DATA;index<=0;end else index<=index+1'b1;
 RAW_DATA:begin
 adler_a<=adler_next_a;adler_b<=adler_next_b;raw_remaining<=raw_remaining-1'b1;block_remaining<=block_remaining-1'b1;
 if(filter_pending)filter_pending<=0;
 else if(!rgb||channel==2)begin
 pixel_valid<=0;channel<=0;
 if(x==WIDTH-1)begin x<=0;y<=y+1'b1;filter_pending<=1;end else x<=x+1'b1;
 end else channel<=channel+1'b1;
 if(raw_remaining==1)begin state<=ADLER;index<=0;end
 else if(block_remaining==1)begin
 state<=BLOCK_HEADER;index<=0;
 block_length<=raw_remaining-1>65535?16'd65535:raw_remaining-1'b1;
 block_remaining<=raw_remaining-1>65535?16'd65535:raw_remaining-1'b1;
 end end
 ADLER:if(index==3)begin state<=IDAT_CRC;index<=0;end else index<=index+1'b1;
 IDAT_CRC:if(index==3)begin state<=IEND_LEN;index<=0;end else index<=index+1'b1;
 IEND_LEN:if(index==3)begin state<=IEND_TYPE;index<=0;crc<=32'hffffffff;end else index<=index+1'b1;
 IEND_TYPE:if(index==3)begin state<=IEND_CRC;index<=0;end else index<=index+1'b1;
 IEND_CRC:if(index==3)begin state<=DONE;index<=0;end else index<=index+1'b1;
 default:fail(8'h94);
 endcase end end end end
endmodule
