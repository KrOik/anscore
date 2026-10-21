// Quantized single-scale grayscale Retinex; no MSR/MSRCR claim.
module retinex_ssr #(
 parameter WIDTH=16,HEIGHT=12,BITS=8,
 parameter LOG_FILE="cores/system/common_scaffold/image/retinex/log2_q8.hex"
)(
 input wire clk,rst_n,ce,
 input wire cfg_valid,output wire cfg_ready,
 input wire [15:0] cfg_gain,input wire signed [15:0] cfg_offset,output reg cfg_done,
 input wire [BITS-1:0] s_pixel,input wire s_valid,s_sof,s_eol,output wire s_ready,
 output reg [BITS-1:0] m_pixel,output reg signed [15:0] m_raw,
 output reg [BITS-1:0] m_surround,
 output reg m_valid,input wire m_ready,
 output wire [15:0] m_x,m_y,output wire m_sof,m_eol,m_last,
 output wire done_valid,input wire done_ready,output reg done_error
);
 localparam [63:0] TOTAL=64'd1*WIDTH*HEIGHT;
 localparam N=(TOTAL>=1&&TOTAL<=65536)?TOTAL:1;
 localparam CAPTURE=0,SREAD=1,SACC=2,LIREAD=3,LICAP=4,LSREAD=5,LSCAP=6,MINIT=7,MULTIPLY=8,MAP=9,HOLD=10,DONE=11;
 reg [3:0] state;
 reg [BITS-1:0] frame[0:N-1],pixel_q,source_pixel,surround;
 reg [11:0] logs[0:4095],log_q,log_i;
 reg [16:0] capture_address;
 reg [15:0] capture_x,x,y;
 reg [4:0] tap;
 reg [23:0] accumulator;
 reg [15:0] gain,frame_gain;reg signed [15:0] offset,frame_offset;
 reg signed [15:0] raw;
 reg [31:0] product,multiplicand;reg [15:0] multiplier;reg [3:0] bit_index;
 function integer reflect;
 input integer coordinate,size;integer k;
 begin
  if(size==1)reflect=0;
  else begin
   for(k=0;k<2;k=k+1)begin
    if(coordinate<0)coordinate=-coordinate;
    if(coordinate>=size)coordinate=2*size-2-coordinate;
   end
   reflect=coordinate;
  end
 end
 endfunction
 function [5:0] weight;
 input [4:0] i;
 begin case(i)
 0,4,20,24:weight=1;
 1,3,5,9,15,19,21,23:weight=4;
 2,10,14,22:weight=6;
 6,8,16,18:weight=16;
 7,11,13,17:weight=24;
 default:weight=36;
 endcase end
 endfunction
 function [23:0] weighted;
 input [BITS-1:0] p;input [5:0] w;reg [23:0] v;
 begin v=p;case(w)
 1:weighted=v;4:weighted=v<<2;6:weighted=(v<<2)+(v<<1);
 16:weighted=v<<4;24:weighted=(v<<4)+(v<<3);
 default:weighted=(v<<5)+(v<<2);
 endcase end
 endfunction
 wire [23:0] sample_sum=accumulator+weighted(pixel_q,weight(tap));
 wire [31:0] address=reflect(y+tap/5-2,HEIGHT)*WIDTH+reflect(x+tap%5-2,WIDTH);
 wire marker_ok=s_sof==(capture_address==0)&&s_eol==(capture_x==WIDTH-1);
 wire [BITS-1:0] log_address=state==LIREAD?source_pixel:surround;
 wire [31:0] rounded_product=(product+32'd32768)>>16;
 wire signed [31:0] adjusted=$signed(frame_offset)+(raw<0?-$signed(rounded_product):$signed(rounded_product));
 assign cfg_ready=rst_n&&ce&&state==CAPTURE&&capture_address==0;
 assign s_ready=rst_n&&ce&&state==CAPTURE&&!(capture_address==0&&cfg_valid);
 assign done_valid=rst_n&&state==DONE;
 assign m_x=x;assign m_y=y;
 assign m_sof=m_valid&&x==0&&y==0;assign m_eol=m_valid&&x==WIDTH-1;
 assign m_last=m_valid&&x==WIDTH-1&&y==HEIGHT-1;
 initial begin
  if(WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096||TOTAL>65536||BITS<8||BITS>12)$fatal(1,"invalid Retinex parameters");
  $readmemh(LOG_FILE,logs);
 end
 always @(posedge clk)if(rst_n&&ce)begin
  if(s_valid&&s_ready&&marker_ok)frame[capture_address]<=s_pixel;
  if(state==SREAD)pixel_q<=frame[address];
  if(state==LIREAD||state==LSREAD)log_q<=logs[log_address];
 end
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=CAPTURE;capture_address<=0;capture_x<=0;x<=0;y<=0;tap<=0;accumulator<=0;source_pixel<=0;surround<=0;log_i<=0;
   gain<=256;offset<=0;frame_gain<=256;frame_offset<=0;raw<=0;product<=0;multiplicand<=0;multiplier<=0;bit_index<=0;
   cfg_done<=0;m_valid<=0;m_pixel<=0;m_raw<=0;m_surround<=0;done_error<=0;
  end else if(ce)begin
   cfg_done<=0;
   if(cfg_valid&&cfg_ready)begin gain<=cfg_gain;offset<=cfg_offset;cfg_done<=1;end
   case(state)
    CAPTURE:if(s_valid&&s_ready)begin
     if(capture_address==0)begin frame_gain<=gain;frame_offset<=offset;done_error<=0;end
     if(!marker_ok)begin done_error<=1;state<=DONE;end
     else if(capture_address==N-1)begin x<=0;y<=0;tap<=0;accumulator<=0;state<=SREAD;end
     else begin capture_address<=capture_address+1'b1;if(capture_x==WIDTH-1)capture_x<=0;else capture_x<=capture_x+1'b1;end
    end
    SREAD:state<=SACC;
    SACC:begin
     accumulator<=sample_sum;if(tap==12)source_pixel<=pixel_q;
     if(tap==24)begin surround<=(sample_sum+24'd128)>>8;state<=LIREAD;end
     else begin tap<=tap+1'b1;state<=SREAD;end
    end
    LIREAD:state<=LICAP;
    LICAP:begin log_i<=log_q;state<=LSREAD;end
    LSREAD:state<=LSCAP;
    LSCAP:begin raw<=$signed({1'b0,log_i})-$signed({1'b0,log_q});state<=MINIT;end
    MINIT:begin
     product<=0;multiplicand<=raw<0?-$signed(raw):raw;multiplier<=frame_gain;bit_index<=0;state<=MULTIPLY;
    end
    MULTIPLY:begin
     if(multiplier[0])product<=product+multiplicand;
     multiplier<=multiplier>>1;multiplicand<=multiplicand<<1;
     if(bit_index==15)state<=MAP;else bit_index<=bit_index+1'b1;
    end
    MAP:begin
     if(adjusted<0)m_pixel<=0;else if(adjusted>((1<<BITS)-1))m_pixel<={BITS{1'b1}};else m_pixel<=adjusted[BITS-1:0];
     m_raw<=raw;m_surround<=surround;m_valid<=1;state<=HOLD;
    end
    HOLD:if(m_ready)begin
     m_valid<=0;
     if(x==WIDTH-1&&y==HEIGHT-1)state<=DONE;
     else begin if(x==WIDTH-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;tap<=0;accumulator<=0;state<=SREAD;end
    end
    DONE:if(done_ready)begin capture_address<=0;capture_x<=0;state<=CAPTURE;end
    default:begin m_valid<=0;done_error<=1;state<=DONE;end
   endcase
  end
 end
endmodule
