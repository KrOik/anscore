// Zero-bordered exact integral image and squared integral image, synchronous RAM.
module integral_image #(
 parameter integer WIDTH=32,HEIGHT=24,BITS=12
)(
 input wire clk,rst_n,ce,
 input wire start_valid,output wire start_ready,input wire abort,
 input wire[BITS-1:0]s_data,input wire s_valid,output wire s_ready,
 input wire s_sof,s_eol,s_last,
 output reg done_valid,input wire done_ready,output reg done_error,output reg[3:0]error_code,
 output reg frame_valid,output reg[31:0]accepted_pixels,
 input wire query_valid,output wire query_ready,
 input wire[15:0]query_x0,query_y0,query_x1,query_y1,
 output reg result_valid,input wire result_ready,
 output reg[31:0]result_sum,output reg[39:0]result_sqsum,output reg[31:0]result_count,
 output reg result_error,output reg[3:0]result_error_code
);
 localparam integer STRIDE=WIDTH+1,DEPTH=(WIDTH+1)*(HEIGHT+1),AW=$clog2(DEPTH+1);
 localparam IDLE=0,ZERO_TOP=1,ZERO_ROW=2,CAPTURE=3,COMMIT=4,FDONE=5,
 READY=6,QREAD=7,QUSE=8,QRESULT=9;
 reg[3:0]state;
 reg[15:0]x,y,zero_x;
 reg[AW-1:0]row_base,prev_base;
 reg[31:0]row_sum;reg[39:0]row_sqsum;
 (* ram_style="block" *)reg[31:0]sum_ram[0:DEPTH-1];
 (* ram_style="block" *)reg[39:0]sq_ram[0:DEPTH-1];
 reg[31:0]sum_q;reg[39:0]sq_q;
 reg[15:0]qx0,qy0,qx1,qy1;reg[1:0]corner;
 reg[31:0]a_sum,b_sum,c_sum;
 reg[39:0]a_sq,b_sq,c_sq;
 wire accept=s_valid&&s_ready;
 wire marker_bad=(s_sof!=(accepted_pixels==0))||(s_eol!=(x==WIDTH-1))||
                 (s_last!=(accepted_pixels==WIDTH*HEIGHT-1));
 wire[2*BITS-1:0]pixel_square=s_data*s_data;
 wire[15:0]read_x=(corner==0||corner==2)?qx1:qx0;
 wire[15:0]read_y=(corner==0||corner==1)?qy1:qy0;
 wire[31:0]query_address=read_y*STRIDE+read_x;
 wire ram_write=state==ZERO_TOP||state==ZERO_ROW||state==COMMIT;
 wire[AW-1:0]write_address=(state==ZERO_TOP)?zero_x:
                           (state==ZERO_ROW)?row_base:(row_base+x+1);
 wire[31:0]write_sum=(state==COMMIT)?sum_q+row_sum:32'd0;
 wire[39:0]write_sq=(state==COMMIT)?sq_q+row_sqsum:40'd0;
 wire ram_read=(accept&&!marker_bad)||state==QREAD;
 wire[AW-1:0]read_address=(state==QREAD)?query_address:(prev_base+x+1);
 assign start_ready=rst_n&&ce&&!abort&&(state==IDLE||state==READY);
 assign s_ready=rst_n&&ce&&!abort&&state==CAPTURE;
 assign query_ready=rst_n&&ce&&!abort&&!start_valid&&state==READY&&frame_valid;
 initial if(WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096||WIDTH*HEIGHT>65536||
            (BITS!=8&&BITS!=10&&BITS!=12))$fatal(1,"integral_image parameters");
 // Explicit synchronous read/write; RAM contents survive reset, validity does not.
 always @(posedge clk)if(rst_n&&ce&&!abort)begin
  if(ram_write)begin sum_ram[write_address]<=write_sum;sq_ram[write_address]<=write_sq;end
  if(ram_read)begin sum_q<=sum_ram[read_address];sq_q<=sq_ram[read_address];end
 end
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;done_valid<=0;done_error<=0;error_code<=0;frame_valid<=0;accepted_pixels<=0;
   result_valid<=0;result_sum<=0;result_sqsum<=0;result_count<=0;result_error<=0;result_error_code<=0;
   x<=0;y<=0;zero_x<=0;row_base<=0;prev_base<=0;row_sum<=0;row_sqsum<=0;
   qx0<=0;qy0<=0;qx1<=0;qy1<=0;corner<=0;a_sum<=0;b_sum<=0;c_sum<=0;a_sq<=0;b_sq<=0;c_sq<=0;
  end else if(ce)begin
   if(abort&&state!=IDLE&&state!=FDONE)begin
    frame_valid<=0;result_valid<=0;done_valid<=1;done_error<=1;error_code<=3;state<=FDONE;
   end else case(state)
    IDLE,READY:begin
     if(start_valid&&start_ready)begin
      frame_valid<=0;accepted_pixels<=0;done_error<=0;error_code<=0;
      result_valid<=0;result_error<=0;result_error_code<=0;
      x<=0;y<=0;zero_x<=0;row_base<=STRIDE;prev_base<=0;row_sum<=0;row_sqsum<=0;state<=ZERO_TOP;
     end else if(query_valid&&query_ready)begin
      result_sum<=0;result_sqsum<=0;result_count<=0;result_error<=0;result_error_code<=0;
      qx0<=query_x0;qy0<=query_y0;qx1<=query_x1;qy1<=query_y1;corner<=0;
      if(query_x0>query_x1||query_y0>query_y1||query_x1>WIDTH||query_y1>HEIGHT)begin
       result_valid<=1;result_error<=1;result_error_code<=1;state<=QRESULT;
      end else begin result_count<=(query_x1-query_x0)*(query_y1-query_y0);state<=QREAD;end
     end
    end
    ZERO_TOP:if(zero_x==WIDTH)state<=ZERO_ROW;else zero_x<=zero_x+1;
    ZERO_ROW:state<=CAPTURE;
    CAPTURE:if(accept)begin
     accepted_pixels<=accepted_pixels+1;
     if(marker_bad)begin frame_valid<=0;done_valid<=1;done_error<=1;error_code<=2;state<=FDONE;end
     else begin
      row_sum<=row_sum+s_data;row_sqsum<=row_sqsum+pixel_square;state<=COMMIT;
     end
    end
    COMMIT:begin
     if(x==WIDTH-1)begin
      if(y==HEIGHT-1)begin frame_valid<=1;done_valid<=1;state<=FDONE;end
      else begin y<=y+1;x<=0;prev_base<=row_base;row_base<=row_base+STRIDE;row_sum<=0;row_sqsum<=0;state<=ZERO_ROW;end
     end else begin x<=x+1;state<=CAPTURE;end
    end
    FDONE:if(done_ready)begin done_valid<=0;state<=frame_valid?READY:IDLE;end
    QREAD:state<=QUSE;
    QUSE:begin
     case(corner)
      0:begin a_sum<=sum_q;a_sq<=sq_q;end
      1:begin b_sum<=sum_q;b_sq<=sq_q;end
      2:begin c_sum<=sum_q;c_sq<=sq_q;end
      3:begin
       // Modular fixed-width intermediates are exact in final unsigned result:
       // A-B-C+D is nonnegative and bounded by the full-frame integral.
       result_sum<=a_sum-b_sum-c_sum+sum_q;result_sqsum<=a_sq-b_sq-c_sq+sq_q;
       result_valid<=1;
      end
     endcase
     if(corner==3)state<=QRESULT;else begin corner<=corner+1;state<=QREAD;end
    end
    QRESULT:if(result_ready)begin result_valid<=0;state<=READY;end
    default:begin frame_valid<=0;result_valid<=0;done_valid<=1;done_error<=1;error_code<=4;state<=FDONE;end
   endcase
  end
 end
endmodule
