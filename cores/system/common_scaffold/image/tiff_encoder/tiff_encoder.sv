// TIFF 6.0 baseline, uncompressed chunky samples, top-left orientation.
module tiff_encoder #(parameter WIDTH=16, HEIGHT=12, ROWS_PER_STRIP=4)(
 input wire clk,rst_n,ce,start_valid, input wire [1:0] cfg_mode,
 input wire cfg_big_endian,abort, output wire start_ready,
 input wire [31:0] s_pixel,input wire s_valid,s_sof,s_eol,s_last,
 output wire s_ready,output wire [7:0] m_data,output wire m_valid,m_sof,m_last,
 input wire m_ready,output wire done_valid,input wire done_ready,
 output reg frame_error,output reg [7:0] error_code,output reg [31:0] output_bytes
);
 localparam NS=(HEIGHT+ROWS_PER_STRIP-1)/(ROWS_PER_STRIP>0?ROWS_PER_STRIP:1);
 localparam BASE=152+8*NS;
 localparam LEGAL=WIDTH>=1 && WIDTH<=4096 && HEIGHT>=1 && HEIGHT<=4096 && ROWS_PER_STRIP>=1 && ROWS_PER_STRIP<=4096;
 localparam IDLE=0,META=1,PIX=2,DONE=3;
 reg [1:0] state,mode;reg be,have;
 reg [31:0] pos,pixel,pi;reg [1:0] bi;
 wire [2:0] bpp=mode==2?3:mode==1?2:1;
 wire [31:0] total=BASE+WIDTH*HEIGHT*bpp;
 function [7:0] byte32;input [31:0] v;input integer i;input endian;begin byte32=endian?(v>>((3-i)*8)):(v>>(i*8));end endfunction
 function [7:0] byte16;input [15:0] v;input integer i;input endian;begin byte16=endian?(v>>((1-i)*8)):(v>>(i*8));end endfunction
 function [7:0] metadata;
 input [31:0] p;input be;input [1:0] mode;input [2:0] bpp;integer e,k,t,typ,cnt,v,idx,rows;reg shortval;
 begin
 metadata=0;t=0;typ=4;cnt=1;v=0;shortval=0;
 if(p<2)metadata=be?8'h4d:8'h49;
 else if(p<4)metadata=byte16(42,p-2,be);
 else if(p<8)metadata=byte32(8,p-4,be);
 else if(p<10)metadata=byte16(11,p-8,be);
 else if(p<142)begin
 e=(p-10)/12;k=(p-10)%12;
 case(e)
 0:begin t=256;v=WIDTH;end
 1:begin t=257;v=HEIGHT;end
 2:begin t=258;typ=3;cnt=mode==2?3:1;v=mode==2?146:mode==1?16:8;shortval=mode!=2;end
 3:begin t=259;typ=3;v=1;shortval=1;end
 4:begin t=262;typ=3;v=mode==2?2:1;shortval=1;end
 5:begin t=273;cnt=NS;v=NS==1?BASE:152;end
 6:begin t=274;typ=3;v=1;shortval=1;end
 7:begin t=277;typ=3;v=mode==2?3:1;shortval=1;end
 8:begin t=278;v=ROWS_PER_STRIP;end
 9:begin t=279;cnt=NS;v=NS==1?WIDTH*HEIGHT*bpp:152+4*NS;end
 10:begin t=284;typ=3;v=1;shortval=1;end
 endcase
 if(k<2)metadata=byte16(t,k,be);
 else if(k<4)metadata=byte16(typ,k-2,be);
 else if(k<8)metadata=byte32(cnt,k-4,be);
 else if(shortval)metadata=k<10?byte16(v,k-8,be):0;
 else metadata=byte32(v,k-8,be);
 end else if(p>=146&&p<152)metadata=byte16(8,(p-146)%2,be);
 else if(p>=152&&p<152+4*NS)begin idx=(p-152)/4;metadata=byte32(BASE+idx*ROWS_PER_STRIP*WIDTH*bpp,(p-152)%4,be);end
 else if(p>=152+4*NS)begin idx=(p-152-4*NS)/4;rows=HEIGHT-idx*ROWS_PER_STRIP;if(rows>ROWS_PER_STRIP)rows=ROWS_PER_STRIP;metadata=byte32(rows*WIDTH*bpp,(p-152-4*NS)%4,be);end
 end endfunction
 assign start_ready=state==IDLE;
 assign s_ready=state==PIX&&!have;
 assign m_valid=state==META||(state==PIX&&have);
 assign m_sof=pos==0;assign m_last=pos==total-1;
 assign m_data=state==META?metadata(pos,be,mode,bpp):mode==2?(pixel>>((2-bi)*8)):mode==1?byte16(pixel[15:0],bi,be):pixel[7:0];
 assign done_valid=state==DONE;
 always @(posedge clk)begin
 if(!rst_n)begin state<=IDLE;mode<=0;be<=0;have<=0;pos<=0;pi<=0;bi<=0;pixel<=0;frame_error<=0;error_code<=0;output_bytes<=0;end
 else if(ce)begin
 if(abort&&state!=IDLE&&state!=DONE)begin state<=DONE;have<=0;frame_error<=1;error_code<=3;end
 else case(state)
 IDLE:if(start_valid)begin mode<=cfg_mode;be<=cfg_big_endian;pos<=0;pi<=0;bi<=0;have<=0;output_bytes<=0;frame_error<=0;error_code<=0;
 if(!LEGAL||cfg_mode==3)begin state<=DONE;frame_error<=1;error_code<=!LEGAL?1:2;end else state<=META;end
 META:if(m_ready)begin pos<=pos+1;output_bytes<=output_bytes+1;if(pos==BASE-1)state<=PIX;end
 PIX:begin
 if(s_valid&&s_ready)begin
 if(s_sof!=(pi==0)||s_eol!=((pi%WIDTH)==WIDTH-1)||s_last!=(pi==WIDTH*HEIGHT-1))begin state<=DONE;frame_error<=1;error_code<=4;end
 else begin pixel<=s_pixel;have<=1;bi<=0;end end
 if(have&&m_ready)begin pos<=pos+1;output_bytes<=output_bytes+1;
 if(bi==bpp-1)begin have<=0;bi<=0;pi<=pi+1;if(pi==WIDTH*HEIGHT-1)state<=DONE;end else bi<=bi+1;end
 end
 DONE:if(done_ready)state<=IDLE;
 endcase end end
endmodule
