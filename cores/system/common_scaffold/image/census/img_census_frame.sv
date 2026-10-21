// Row-major Census bits, center omitted; bit zero is top-left neighbor.
module img_census_frame #(parameter BITS=8,WIDTH=16,HEIGHT=16,RADIUS=2)(
 input wire clk,rst_n,ce,
 input wire cfg_valid,output wire cfg_ready,input wire [BITS-1:0] cfg_threshold,
 input wire [BITS-1:0] s_data,input wire s_valid,output wire s_ready,input wire s_sof,s_eol,
 output reg [(2*RADIUS+1)*(2*RADIUS+1)-2:0] m_descriptor,output reg m_border,
 output wire m_valid,input wire m_ready,output wire m_sof,m_eol,
 output wire done_valid,input wire done_ready,output reg frame_error
);
 localparam SIDE=2*RADIUS+1,COUNT=SIDE*SIDE-1,PIXELS=WIDTH*HEIGHT;
 localparam CAPTURE=0,CENTER_READ=1,CENTER=2,NEIGHBOR_READ=3,NEIGHBOR=4,HOLD=5,DONE=6;
 reg [2:0] state;
 reg [BITS-1:0] memory[0:PIXELS-1],q,center,threshold;
 reg [COUNT-1:0] descriptor;
 integer index,x,y;
 reg [4:0] tap;
 wire border=x<RADIUS||y<RADIUS||x>=WIDTH-RADIUS||y>=HEIGHT-RADIUS;
 wire [BITS-1:0] difference=center-q;
 wire bit_value=center>q&&difference>threshold;
 wire [COUNT-1:0] next_descriptor=descriptor|({{(COUNT-1){1'b0}},bit_value}<<tap);
 assign cfg_ready=rst_n&&state==CAPTURE&&index==0;
 assign s_ready=rst_n&&state==CAPTURE&&!cfg_valid;
 assign m_valid=rst_n&&state==HOLD;
 assign m_sof=m_valid&&index==0;
 assign m_eol=m_valid&&x==WIDTH-1;
 assign done_valid=rst_n&&state==DONE;
 function integer offset_x;
 input [4:0] n;integer k;
 begin
  offset_x=0;
  for(k=0;k<COUNT;k=k+1)if(n==k)offset_x=(k<COUNT/2?k:k+1)%SIDE-RADIUS;
 end
 endfunction
 function integer offset_y;
 input [4:0] n;integer k;
 begin
  offset_y=0;
  for(k=0;k<COUNT;k=k+1)if(n==k)offset_y=(k<COUNT/2?k:k+1)/SIDE-RADIUS;
 end
 endfunction
 initial begin
  if(BITS<8||BITS>16||WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096||PIXELS>65536||(RADIUS!=1&&RADIUS!=2))
   $fatal(1,"img_census_frame invalid parameters");
 end
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=CAPTURE;index<=0;x<=0;y<=0;tap<=0;threshold<=0;
   descriptor<=0;m_descriptor<=0;m_border<=0;frame_error<=0;center<=0;
  end else if(ce)begin
   case(state)
    CAPTURE:begin
     if(cfg_valid&&cfg_ready)threshold<=cfg_threshold;
     if(s_valid&&s_ready)begin
      if(s_sof!=(index==0)||s_eol!=(x==WIDTH-1))begin state<=DONE;frame_error<=1;end
      else begin
       memory[index]<=s_data;
       if(index==PIXELS-1)begin index<=0;x<=0;y<=0;state<=CENTER_READ;end
       else begin index<=index+1;if(x==WIDTH-1)begin x<=0;y<=y+1;end else x<=x+1;end
      end
     end
    end
    CENTER_READ:begin q<=memory[index];state<=CENTER;end
    CENTER:begin
     center<=q;descriptor<=0;tap<=0;m_border<=border;
     if(border)begin m_descriptor<=0;state<=HOLD;end else state<=NEIGHBOR_READ;
    end
    NEIGHBOR_READ:begin q<=memory[(y+offset_y(tap))*WIDTH+x+offset_x(tap)];state<=NEIGHBOR;end
    NEIGHBOR:begin
     descriptor<=next_descriptor;
     if(tap==COUNT-1)begin m_descriptor<=next_descriptor;state<=HOLD;end
     else begin tap<=tap+1;state<=NEIGHBOR_READ;end
    end
    HOLD:if(m_ready)begin
     if(index==PIXELS-1)state<=DONE;
     else begin index<=index+1;if(x==WIDTH-1)begin x<=0;y<=y+1;end else x<=x+1;state<=CENTER_READ;end
    end
    DONE:if(done_ready)begin state<=CAPTURE;index<=0;x<=0;y<=0;frame_error<=0;end
    default:begin state<=DONE;frame_error<=1;end
   endcase
  end
 end
endmodule
