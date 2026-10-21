// True Floyd-Steinberg error diffusion, raster I/O with optional internal serpentine.
module floyd_steinberg #(parameter WIDTH=16,HEIGHT=12,BITS=8,OUTPUT_BITS=1)(
 input wire clk,rst_n,ce,input wire cfg_serpentine,
 input wire [BITS-1:0] s_pixel,input wire s_valid,s_sof,s_eol,output wire s_ready,
 output reg [BITS-1:0] m_pixel,output reg [OUTPUT_BITS-1:0] m_code,
 output reg m_valid,input wire m_ready,
 output wire [15:0] m_x,m_y,output wire m_sof,m_eol,m_last,
 output wire done_valid,input wire done_ready,output reg done_error
);
 localparam [63:0] TOTAL=64'd1*WIDTH*HEIGHT;
 localparam N=(TOTAL>=1&&TOTAL<=65536)?TOTAL:1;
 localparam EW=(WIDTH>=1&&WIDTH<=4096)?2*WIDTH:2;
 localparam MAXPIX=(1<<BITS)-1,MAXCODE=(1<<OUTPUT_BITS)-1;
 localparam CAPTURE=0,CLEAR=1,READ=2,CORRECT=3,QSTART=4,DIVIDE=5,QDONE=6,RDONE=7,NSELECT=8,DREAD=9,DWRITE=10,NEXT=11,OREAD=12,PRESENT=13,HOLD=14,DONE=15;
 reg [3:0] state,div_return;
 reg [BITS-1:0] frame[0:N-1],pixel_q;
 reg [BITS+OUTPUT_BITS-1:0] results[0:N-1],result_q;
 reg signed [31:0] errors[0:EW-1],error_q,quant_error;
 reg [16:0] capture_address;
 reg [15:0] capture_x,x,y,clear_address;
 reg serpentine;
 reg [15:0] corrected;
 reg [OUTPUT_BITS-1:0] code;
 reg [31:0] dividend,divisor;
 reg [32:0] remainder;
 reg [4:0] div_step;
 reg [1:0] neighbor;
 integer nx,ny,direction;
 wire reverse=serpentine&&y[0];
 wire [31:0] pixel_address=y*WIDTH+x;
 wire [31:0] current_error_address=(y[0]?WIDTH:0)+x;
 wire [31:0] neighbor_error_address=(ny[0]?WIDTH:0)+nx;
 wire neighbor_valid=nx>=0&&nx<WIDTH&&ny>=0&&ny<HEIGHT;
 wire marker_ok=s_sof==(capture_address==0)&&s_eol==(capture_x==WIDTH-1);
 wire signed [31:0] combined=$signed({1'b0,pixel_q,4'b0})+error_q;
 wire [32:0] shifted_remainder={remainder[31:0],dividend[31]};
 wire quotient_bit=shifted_remainder>={1'b0,divisor};
 function [31:0] cmul;
 input [31:0] value;input [15:0] coefficient;integer k;
 begin cmul=0;for(k=0;k<16;k=k+1)if(coefficient[k])cmul=cmul+(value<<k);end
 endfunction
 function signed [31:0] contribution;
 input signed [31:0] e;input [1:0] which;reg [31:0] magnitude,scaled;
 begin
  magnitude=e<0?-e:e;
  case(which)
   0:scaled=(magnitude<<2)+(magnitude<<1)+magnitude;
   1:scaled=(magnitude<<1)+magnitude;
   2:scaled=(magnitude<<2)+magnitude;
   default:scaled=magnitude;
  endcase
  contribution=e<0?-$signed((scaled+8)>>4):$signed((scaled+8)>>4);
 end
 endfunction
 always @*begin
  direction=reverse?-1:1;ny=$signed({1'b0,y})+1;
  case(neighbor)
   0:begin nx=$signed({1'b0,x})+direction;ny=y;end
   1:nx=$signed({1'b0,x})-direction;
   2:nx=x;
   default:nx=$signed({1'b0,x})+direction;
  endcase
 end
 task next_neighbor;
 begin if(neighbor==3)state<=NEXT;else begin neighbor<=neighbor+1'b1;state<=NSELECT;end end
 endtask
 assign s_ready=rst_n&&ce&&state==CAPTURE;
 assign done_valid=rst_n&&state==DONE;
 assign m_x=x;assign m_y=y;
 assign m_sof=m_valid&&x==0&&y==0;assign m_eol=m_valid&&x==WIDTH-1;
 assign m_last=m_valid&&x==WIDTH-1&&y==HEIGHT-1;
 initial if(WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096||TOTAL>65536||BITS<8||BITS>12||OUTPUT_BITS<1||OUTPUT_BITS>BITS)$fatal(1,"invalid Floyd-Steinberg parameters");
 always @(posedge clk)if(rst_n&&ce)begin
  if(s_valid&&s_ready&&marker_ok)frame[capture_address]<=s_pixel;
  if(state==CLEAR)errors[clear_address]<=0;
  else if(state==RDONE)errors[current_error_address]<=0;
  else if(state==DWRITE)errors[neighbor_error_address]<=error_q+contribution(quant_error,neighbor);
  if(state==READ)begin pixel_q<=frame[pixel_address];error_q<=errors[current_error_address];end
  if(state==DREAD)error_q<=errors[neighbor_error_address];
  if(state==RDONE)results[pixel_address]<={dividend[BITS-1:0],code};
  if(state==OREAD)result_q<=results[pixel_address];
 end
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=CAPTURE;div_return<=0;capture_address<=0;capture_x<=0;x<=0;y<=0;clear_address<=0;serpentine<=0;
   corrected<=0;code<=0;dividend<=0;divisor<=1;remainder<=0;div_step<=0;neighbor<=0;quant_error<=0;
   m_pixel<=0;m_code<=0;m_valid<=0;done_error<=0;
  end else if(ce)case(state)
   CAPTURE:if(s_valid)begin
    if(capture_address==0)begin serpentine<=cfg_serpentine;done_error<=0;end
    if(!marker_ok)begin done_error<=1;state<=DONE;end
    else if(capture_address==N-1)begin clear_address<=0;x<=0;y<=0;state<=CLEAR;end
    else begin capture_address<=capture_address+1'b1;if(capture_x==WIDTH-1)capture_x<=0;else capture_x<=capture_x+1'b1;end
   end
   CLEAR:if(clear_address==EW-1)state<=READ;else clear_address<=clear_address+1'b1;
   READ:state<=CORRECT;
   CORRECT:begin
    if(combined<0)corrected<=0;else if(combined>MAXPIX*16)corrected<=MAXPIX*16;else corrected<=combined[15:0];
    state<=QSTART;
   end
   QSTART:begin dividend<=cmul({16'b0,corrected},MAXCODE)+MAXPIX*8;divisor<=MAXPIX*16;remainder<=0;div_step<=0;div_return<=QDONE;state<=DIVIDE;end
   DIVIDE:begin
    remainder<=quotient_bit?shifted_remainder-{1'b0,divisor}:shifted_remainder;
    dividend<={dividend[30:0],quotient_bit};
    if(div_step==31)state<=div_return;else div_step<=div_step+1'b1;
   end
   QDONE:begin
    code<=dividend[OUTPUT_BITS-1:0];dividend<=cmul(dividend,MAXPIX)+MAXCODE/2;divisor<=MAXCODE;remainder<=0;div_step<=0;div_return<=RDONE;state<=DIVIDE;
   end
   RDONE:begin quant_error<=$signed({1'b0,corrected})-$signed({1'b0,dividend[BITS-1:0],4'b0});neighbor<=0;state<=NSELECT;end
   NSELECT:if(neighbor_valid)state<=DREAD;else next_neighbor;
   DREAD:state<=DWRITE;
   DWRITE:next_neighbor;
   NEXT:begin
    if(y==HEIGHT-1&&x==(reverse?0:WIDTH-1))begin x<=0;y<=0;state<=OREAD;end
    else begin
     if(x==(reverse?0:WIDTH-1))begin y<=y+1'b1;x<=serpentine&&!y[0]?WIDTH-1:0;end
     else x<=reverse?x-1'b1:x+1'b1;
     state<=READ;
    end
   end
   OREAD:state<=PRESENT;
   PRESENT:begin m_pixel<=result_q[BITS+OUTPUT_BITS-1:OUTPUT_BITS];m_code<=result_q[OUTPUT_BITS-1:0];m_valid<=1;state<=HOLD;end
   HOLD:if(m_ready)begin
    m_valid<=0;
    if(x==WIDTH-1&&y==HEIGHT-1)state<=DONE;
    else begin if(x==WIDTH-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;state<=OREAD;end
   end
   DONE:if(done_ready)begin capture_address<=0;capture_x<=0;state<=CAPTURE;end
   default:begin m_valid<=0;done_error<=1;state<=DONE;end
  endcase
 end
endmodule
