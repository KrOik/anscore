// Same-Bayer-phase dynamic defect correction using eight radius-two neighbors.
module raw_bad_pixel_frame #(parameter BITS=12, WIDTH=16, HEIGHT=16)(
 input wire clk,rst_n,ce,
 input wire cfg_valid,output wire cfg_ready,input wire [BITS-1:0] cfg_threshold,
 input wire [BITS-1:0] s_data,input wire s_valid,output wire s_ready,input wire s_sof,s_eol,
 output reg [BITS-1:0] m_data,output reg m_corrected,
 output wire m_valid,input wire m_ready,output wire m_sof,m_eol,
 output wire done_valid,input wire done_ready,output reg frame_error
);
 localparam CAPTURE=0,READ_CENTER=1,CENTER=2,READ_RING=3,RING=4,SORT=5,RESULT=6,HOLD=7,DONE=8;
 localparam PIXELS=WIDTH*HEIGHT;
 reg [3:0] state;
 reg [BITS-1:0] memory[0:PIXELS-1],q,center,threshold;
 reg [BITS-1:0] neighbors[0:7];
 reg [2:0] neighbor,sort_pass,sort_index;
 integer index,x,y;
 wire border=x<2||y<2||x>=WIDTH-2||y>=HEIGHT-2;
 wire [BITS:0] middle_sum={1'b0,neighbors[3]}+{1'b0,neighbors[4]};
 wire [BITS-1:0] median=middle_sum[BITS:1];
 wire [BITS-1:0] delta=center>=median?center-median:median-center;
 assign cfg_ready=rst_n&&state==CAPTURE&&index==0;
 assign s_ready=rst_n&&state==CAPTURE&&!cfg_valid;
 assign m_valid=rst_n&&state==HOLD;
 assign m_sof=m_valid&&index==0;
 assign m_eol=m_valid&&x==WIDTH-1;
 assign done_valid=rst_n&&state==DONE;
 function integer dx;
 input [2:0] n;
 begin case(n) 0,3,5:dx=-2;1,6:dx=0;default:dx=2;endcase end
 endfunction
 function integer dy;
 input [2:0] n;
 begin case(n) 0,1,2:dy=-2;3,4:dy=0;default:dy=2;endcase end
 endfunction
 initial begin
  if(BITS<8||BITS>16||WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096||PIXELS>65536)
   $fatal(1,"raw_bad_pixel_frame invalid parameters");
 end
 always @(posedge clk) begin
  if(!rst_n)begin
   state<=CAPTURE;index<=0;x<=0;y<=0;threshold<=0;frame_error<=0;
   m_data<=0;m_corrected<=0;neighbor<=0;sort_pass<=0;sort_index<=0;center<=0;
  end else if(ce)begin
   case(state)
    CAPTURE:begin
     if(cfg_valid&&cfg_ready)threshold<=cfg_threshold;
     if(s_valid&&s_ready)begin
      if(s_sof!=(index==0)||s_eol!=(x==WIDTH-1))begin frame_error<=1;state<=DONE;end
      else begin
       memory[index]<=s_data;
       if(index==PIXELS-1)begin index<=0;x<=0;y<=0;state<=READ_CENTER;end
       else begin index<=index+1;if(x==WIDTH-1)begin x<=0;y<=y+1;end else x<=x+1;end
      end
     end
    end
    READ_CENTER:begin q<=memory[index];state<=CENTER;end
    CENTER:begin
     center<=q;
     if(border)begin m_data<=q;m_corrected<=0;state<=HOLD;end
     else begin neighbor<=0;state<=READ_RING;end
    end
    READ_RING:begin q<=memory[(y+dy(neighbor))*WIDTH+x+dx(neighbor)];state<=RING;end
    RING:begin
     neighbors[neighbor]<=q;
     if(neighbor==7)begin sort_pass<=0;sort_index<=0;state<=SORT;end
     else begin neighbor<=neighbor+1;state<=READ_RING;end
    end
    SORT:begin
     if(neighbors[sort_index]>neighbors[sort_index+1])begin
      neighbors[sort_index]<=neighbors[sort_index+1];neighbors[sort_index+1]<=neighbors[sort_index];
     end
     if(sort_index==6-sort_pass)begin
      sort_index<=0;
      if(sort_pass==6)state<=RESULT;else sort_pass<=sort_pass+1;
     end else sort_index<=sort_index+1;
    end
    RESULT:begin m_corrected<=delta>threshold;m_data<=delta>threshold?median:center;state<=HOLD;end
    HOLD:if(m_ready)begin
     if(index==PIXELS-1)state<=DONE;
     else begin index<=index+1;if(x==WIDTH-1)begin x<=0;y<=y+1;end else x<=x+1;state<=READ_CENTER;end
    end
    DONE:if(done_ready)begin state<=CAPTURE;index<=0;x<=0;y<=0;frame_error<=0;end
    default:begin state<=DONE;frame_error<=1;end
   endcase
  end
 end
endmodule
