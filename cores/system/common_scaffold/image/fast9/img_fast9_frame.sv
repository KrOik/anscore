// FAST-9 radius-three circle detector. Score map only; no nonmaximum suppression.
module img_fast9_frame #(parameter BITS=8,WIDTH=16,HEIGHT=16)(
 input wire clk,rst_n,ce,
 input wire cfg_valid,output wire cfg_ready,input wire [BITS-1:0] cfg_threshold,
 input wire [BITS-1:0] s_data,input wire s_valid,output wire s_ready,input wire s_sof,s_eol,
 output reg [BITS-1:0] m_score,output reg m_corner,
 output wire m_valid,input wire m_ready,output wire m_sof,m_eol,
 output wire done_valid,input wire done_ready,output reg frame_error
);
 localparam CAPTURE=0,CENTER_READ=1,CENTER=2,RING_READ=3,RING_STORE=4,ARC=5,OUT_LOAD=6,HOLD=7,DONE=8;
 localparam PIXELS=WIDTH*HEIGHT;
 reg [3:0] state;
 reg [BITS-1:0] memory[0:PIXELS-1],center_q,pixel_q,threshold;
 reg signed [BITS:0] difference[0:15];
 reg [BITS-1:0] min_bright,min_dark,best_strength;
 reg [3:0] ring_index,arc_start,arc_tap;
 integer index,x,y;
 wire border=x<3||y<3||x>=WIDTH-3||y>=HEIGHT-3;
 wire [3:0] selected=arc_start+arc_tap;
 wire signed [BITS:0] d=difference[selected];
 wire [BITS-1:0] bright=d>0?d:0,dark=d<0?-d:0;
 wire [BITS-1:0] next_bright=bright<min_bright?bright:min_bright;
 wire [BITS-1:0] next_dark=dark<min_dark?dark:min_dark;
 wire [BITS-1:0] strength=next_bright>next_dark?next_bright:next_dark;
 wire [BITS-1:0] next_best=strength>best_strength?strength:best_strength;
 function integer dx;
 input [3:0] i;
 begin case(i)
 0,8:dx=0;1,7:dx=1;2,6:dx=2;3,4,5:dx=3;
 9,15:dx=-1;10,14:dx=-2;default:dx=-3;
 endcase end endfunction
 function integer dy;
 input [3:0] i;
 begin case(i)
 0,1,15:dy=-3;2,14:dy=-2;3,13:dy=-1;4,12:dy=0;
 5,11:dy=1;6,10:dy=2;default:dy=3;
 endcase end endfunction
 assign cfg_ready=rst_n&&ce&&state==CAPTURE&&index==0;
 assign s_ready=rst_n&&ce&&state==CAPTURE&&!(cfg_valid&&cfg_ready);
 assign m_valid=state==HOLD;
 assign m_sof=m_valid&&index==0;
 assign m_eol=m_valid&&x==WIDTH-1;
 assign done_valid=state==DONE;
 initial if((BITS!=8&&BITS!=10&&BITS!=12)||WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096||PIXELS>65536)
  $fatal(1,"invalid FAST parameters");
 always @(posedge clk) begin
  if(!rst_n) begin
   state<=CAPTURE;index<=0;x<=0;y<=0;threshold<=20;center_q<=0;pixel_q<=0;
   min_bright<=0;min_dark<=0;best_strength<=0;ring_index<=0;arc_start<=0;arc_tap<=0;
   m_score<=0;m_corner<=0;frame_error<=0;
  end else if(ce) begin
   if(cfg_valid&&cfg_ready) threshold<=cfg_threshold;
   case(state)
    CAPTURE:if(s_valid&&s_ready) begin
     if(s_sof!=(index==0)||s_eol!=(x==WIDTH-1)) begin frame_error<=1;state<=DONE;end
     else begin
      if(index==0) frame_error<=0;
      memory[index]<=s_data;
      if(index==PIXELS-1) begin index<=0;x<=0;y<=0;state<=CENTER_READ;end
      else begin index<=index+1;if(x==WIDTH-1)begin x<=0;y<=y+1;end else x<=x+1;end
     end
    end
    CENTER_READ:begin center_q<=memory[index];state<=CENTER;end
    CENTER:begin
     best_strength<=0;
     if(border) state<=OUT_LOAD;
     else begin ring_index<=0;state<=RING_READ;end
    end
    RING_READ:begin pixel_q<=memory[(y+dy(ring_index))*WIDTH+x+dx(ring_index)];state<=RING_STORE;end
    RING_STORE:begin
     difference[ring_index]<=$signed({1'b0,pixel_q})-$signed({1'b0,center_q});
     if(ring_index==15) begin
      arc_start<=0;arc_tap<=0;min_bright<={BITS{1'b1}};min_dark<={BITS{1'b1}};state<=ARC;
     end else begin ring_index<=ring_index+1'b1;state<=RING_READ;end
    end
    ARC:begin
     if(arc_tap==8) begin
      best_strength<=next_best;
      if(arc_start==15) state<=OUT_LOAD;
      else begin arc_start<=arc_start+1'b1;arc_tap<=0;min_bright<={BITS{1'b1}};min_dark<={BITS{1'b1}};end
     end else begin arc_tap<=arc_tap+1'b1;min_bright<=next_bright;min_dark<=next_dark;end
    end
    OUT_LOAD:begin m_score<=best_strength==0?0:best_strength-1'b1;m_corner<=best_strength>threshold;state<=HOLD;end
    HOLD:if(m_ready) begin
     if(index==PIXELS-1) state<=DONE;
     else begin index<=index+1;if(x==WIDTH-1)begin x<=0;y<=y+1;end else x<=x+1;state<=CENTER_READ;end
    end
    DONE:if(done_ready)begin state<=CAPTURE;index<=0;x<=0;y<=0;end
    default:state<=DONE;
   endcase
  end
 end
endmodule
