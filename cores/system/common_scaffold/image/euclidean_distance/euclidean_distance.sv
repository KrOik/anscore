// Exact squared Euclidean EDT, separable exhaustive 1-D min-plus passes.
module euclidean_distance #(parameter WIDTH=16,HEIGHT=12)(
 input wire clk,rst_n,ce,
 input wire s_pixel,s_valid,s_sof,s_eol,output wire s_ready,
 output reg m_valid,input wire m_ready,
 output reg [31:0] m_distance_squared,
 output reg [15:0] m_nearest_x,m_nearest_y,
 output reg m_invalid,
 output wire [15:0] m_x,m_y,output wire m_sof,m_eol,m_last,
 output wire done_valid,input wire done_ready,output reg done_error
);
 localparam [63:0] TOTAL=64'd1*WIDTH*HEIGHT;
 localparam N=(TOTAL>=1&&TOTAL<=65536)?TOTAL:1;
 localparam XW=WIDTH<2?1:$clog2(WIDTH),YW=HEIGHT<2?1:$clog2(HEIGHT);
 localparam DW=2*XW,HW=1+XW+DW;
 localparam CAPTURE=0,HREAD=1,HEVAL=2,HSTORE=3,VINIT=4,VREAD=5,VEVAL=6,PRESENT=7,HOLD=8,DONE=9;
 reg [3:0] state;
 reg frame[0:N-1],frame_q;
 reg [HW-1:0] horizontal[0:N-1],hq;
 reg [16:0] capture_address;
 reg [XW-1:0] capture_x,x,scan_x,hbest_x,best_x;
 reg [YW-1:0] capture_y,y,scan_y,best_y;
 reg [31:0] hbest,best;reg hfound,found;
 wire marker_ok=s_sof==(capture_address==0)&&s_eol==(capture_x==WIDTH-1);
 wire [15:0] dx=x>=scan_x?x-scan_x:scan_x-x;
 wire [15:0] dy=y>=scan_y?y-scan_y:scan_y-y;
 function [31:0] square;
 input [15:0] value;integer k;
 begin square=0;for(k=0;k<16;k=k+1)if(value[k])square=square+({16'b0,value}<<k);end
 endfunction
 wire [31:0] horizontal_cost=square(dx);
 wire [32:0] candidate={1'b0,square(dy)}+{{(33-DW){1'b0}},hq[DW-1:0]};
 wire [31:0] out_address=y*WIDTH+x;
 wire [31:0] hread_address=y*WIDTH+scan_x;
 wire [31:0] vread_address=scan_y*WIDTH+x;
 assign s_ready=rst_n&&ce&&state==CAPTURE;
 assign done_valid=rst_n&&state==DONE;
 assign m_x=x;assign m_y=y;
 assign m_sof=m_valid&&x==0&&y==0;
 assign m_eol=m_valid&&x==WIDTH-1;
 assign m_last=m_valid&&x==WIDTH-1&&y==HEIGHT-1;
 initial if(WIDTH<1||HEIGHT<1||WIDTH>65535||HEIGHT>65535||TOTAL>65536)$fatal(1,"invalid Euclidean EDT geometry");
 always @(posedge clk)if(rst_n&&ce)begin
  if(state==CAPTURE&&s_valid&&marker_ok)frame[capture_address]<=s_pixel;
  if(state==HREAD)frame_q<=frame[hread_address];
  if(state==HSTORE)horizontal[out_address]<={hfound,hbest_x,hbest[DW-1:0]};
  if(state==VREAD)hq<=horizontal[vread_address];
 end
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=CAPTURE;capture_address<=0;capture_x<=0;capture_y<=0;x<=0;y<=0;scan_x<=0;scan_y<=0;
   hbest_x<=0;best_x<=0;best_y<=0;hbest<=32'hffffffff;best<=32'hffffffff;hfound<=0;found<=0;
   m_valid<=0;m_distance_squared<=0;m_nearest_x<=0;m_nearest_y<=0;m_invalid<=0;done_error<=0;
  end else if(ce)begin
   case(state)
    CAPTURE:if(s_valid)begin
     if(capture_address==0)done_error<=0;
     if(!marker_ok)begin done_error<=1;state<=DONE;end
     else if(capture_address==N-1)begin x<=0;y<=0;scan_x<=0;hbest<=32'hffffffff;hfound<=0;hbest_x<=0;state<=HREAD;end
     else begin
      capture_address<=capture_address+1'b1;
      if(capture_x==WIDTH-1)begin capture_x<=0;capture_y<=capture_y+1'b1;end else capture_x<=capture_x+1'b1;
     end
    end
    HREAD:state<=HEVAL;
    HEVAL:begin
     // Ascending scan_x makes an equal-cost tie retain lowest x.
     if(!frame_q&&(!hfound||horizontal_cost<hbest))begin hbest<=horizontal_cost;hbest_x<=scan_x;hfound<=1;end
     if(scan_x==WIDTH-1)state<=HSTORE;
     else begin scan_x<=scan_x+1'b1;state<=HREAD;end
    end
    HSTORE:begin
     if(x==WIDTH-1&&y==HEIGHT-1)begin x<=0;y<=0;state<=VINIT;end
     else begin
      if(x==WIDTH-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;
      scan_x<=0;hbest<=32'hffffffff;hfound<=0;hbest_x<=0;state<=HREAD;
     end
    end
    VINIT:begin scan_y<=0;best<=32'hffffffff;found<=0;best_x<=0;best_y<=0;state<=VREAD;end
    VREAD:state<=VEVAL;
    VEVAL:begin
     // Ascending source row, then lowest horizontal x, gives lowest raster tie.
     if(hq[HW-1]&&(!found||candidate<{1'b0,best}))begin best<=candidate[31:0];best_x<=hq[DW+:XW];best_y<=scan_y;found<=1;end
     if(scan_y==HEIGHT-1)state<=PRESENT;
     else begin scan_y<=scan_y+1'b1;state<=VREAD;end
    end
    PRESENT:begin
     m_distance_squared<=found?best:32'hffffffff;m_nearest_x<=found?best_x:16'hffff;m_nearest_y<=found?best_y:16'hffff;
     m_invalid<=!found;m_valid<=1;state<=HOLD;
    end
    HOLD:if(m_ready)begin
     m_valid<=0;
     if(x==WIDTH-1&&y==HEIGHT-1)state<=DONE;
     else begin if(x==WIDTH-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;state<=VINIT;end
    end
    DONE:if(done_ready)begin capture_address<=0;capture_x<=0;capture_y<=0;state<=CAPTURE;end
    default:begin m_valid<=0;done_error<=1;state<=DONE;end
   endcase
  end
 end
endmodule
