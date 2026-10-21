// Generic unsigned-score 3x3 local NMS; not directional Canny suppression.
`timescale 1ns/1ps
module img_corner_nms #(
 parameter integer BITS=16,WIDTH=16,HEIGHT=16,KEEP_BORDER=0
)(
 input wire clk,rst_n,clk_en,
 input wire cfg_valid,output wire cfg_ready,
 input wire [BITS-1:0] cfg_threshold,output reg cfg_done,
 input wire [BITS-1:0] s_score,input wire s_valid,output wire s_ready,
 input wire s_sof,s_eol,
 output reg [BITS-1:0] m_score,output reg m_corner,
 output reg [1:0] m_reason,
 output wire m_valid,input wire m_ready,output wire m_sof,m_eol,
 output wire done_valid,input wire done_ready,
 output reg done_error,output reg [1:0] error_code
);
 function integer cw;
 input integer n;integer k;
 begin k=n-1;cw=0;while(k>0) begin cw=cw+1;k=k>>1;end if(cw==0) cw=1;end
 endfunction
 function [31:0] row_offset;
 input [31:0] row;integer k;reg [31:0] sum;
 begin sum=0;for(k=0;k<13;k=k+1) if((WIDTH>>k)&1) sum=sum+(row<<k);row_offset=sum;end
 endfunction
 localparam N=WIDTH*HEIGHT;
 localparam SYNC=0,CAPTURE=1,CREAD=2,CCHECK=3,NSELECT=4,NREAD=5,NCHECK=6,EMIT=7,COMPLETE=8;
 reg [3:0] state;
 reg [cw(WIDTH)-1:0] x,nx;
 reg [cw(HEIGHT)-1:0] y,ny;
 reg [cw(N)-1:0] position;
 reg [2:0] neighbor;
 reg neighbor_inside;
 reg [BITS-1:0] memory[0:N-1],ram_q,center,threshold,frame_threshold;
 wire border=x==0||y==0||x==WIDTH-1||y==HEIGHT-1;
 always @* begin
  nx=x;ny=y;neighbor_inside=1;
  case(neighbor)
   0:begin nx=x-1'b1;ny=y-1'b1;neighbor_inside=x!=0&&y!=0;end
   1:begin ny=y-1'b1;neighbor_inside=y!=0;end
   2:begin nx=x+1'b1;ny=y-1'b1;neighbor_inside=x<WIDTH-1&&y!=0;end
   3:begin nx=x-1'b1;neighbor_inside=x!=0;end
   4:begin nx=x+1'b1;neighbor_inside=x<WIDTH-1;end
   5:begin nx=x-1'b1;ny=y+1'b1;neighbor_inside=x!=0&&y<HEIGHT-1;end
   6:begin ny=y+1'b1;neighbor_inside=y<HEIGHT-1;end
   7:begin nx=x+1'b1;ny=y+1'b1;neighbor_inside=x<WIDTH-1&&y<HEIGHT-1;end
  endcase
 end
 wire [31:0] neighbor_address=row_offset(ny)+nx;
 wire [31:0] read_address=state==NREAD?neighbor_address:position;
 wire input_ok=s_sof==(position==0)&&s_eol==(x==WIDTH-1);
 wire capture_transfer=s_valid&&s_ready&&input_ok;
 assign cfg_ready=rst_n&&clk_en&&state==SYNC;
 assign s_ready=rst_n&&clk_en&&(state==SYNC||state==CAPTURE)&&!(state==SYNC&&cfg_valid);
 assign m_valid=state==EMIT;
 assign m_sof=m_valid&&position==0;
 assign m_eol=m_valid&&x==WIDTH-1;
 assign done_valid=state==COMPLETE;
 // Clocked read port and unreset RAM/read register permit BRAM mapping.
 always @(posedge clk) if(clk_en) begin
  if(capture_transfer) memory[position]<=s_score;
  if(state==CREAD||state==NREAD) ram_q<=memory[read_address];
 end
 task clear_position;
 begin x<=0;y<=0;position<=0;end
 endtask
 task advance_position;
 begin position<=position+1'b1;if(x==WIDTH-1) begin x<=0;y<=y+1'b1;end else x<=x+1'b1;end
 endtask
 initial begin
  if(BITS<8||BITS>32||WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096||N>65536||
    (KEEP_BORDER!=0&&KEEP_BORDER!=1)) $fatal(1,"invalid corner NMS parameters");
 end
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   state<=SYNC;clear_position();neighbor<=0;center<=0;threshold<=0;frame_threshold<=0;
   cfg_done<=0;m_score<=0;m_corner<=0;m_reason<=0;done_error<=0;error_code<=0;
  end else if(clk_en) begin
   cfg_done<=0;
   if(cfg_valid&&cfg_ready) begin threshold<=cfg_threshold;cfg_done<=1;end
   case(state)
    SYNC,CAPTURE:if(s_valid&&s_ready) begin
     if(!input_ok) begin state<=COMPLETE;done_error<=1;error_code<=1;end
     else begin
      if(position==0) begin frame_threshold<=threshold;done_error<=0;error_code<=0;end
      if(position==N-1) begin clear_position();state<=CREAD;end
      else begin advance_position();state<=CAPTURE;end
     end
    end
    CREAD:state<=CCHECK;
    CCHECK:begin
     center<=ram_q;m_score<=ram_q;m_corner<=0;
     if(ram_q<=frame_threshold) begin m_reason<=1;state<=EMIT;end
     else if(!KEEP_BORDER&&border) begin m_reason<=2;state<=EMIT;end
     else begin neighbor<=0;m_corner<=1;m_reason<=0;state<=NSELECT;end
    end
    NSELECT:if(neighbor_inside) state<=NREAD;
            else if(neighbor==7) state<=EMIT;
            else neighbor<=neighbor+1'b1;
    NREAD:state<=NCHECK;
    NCHECK:if(ram_q>center||(ram_q==center&&neighbor_address<position)) begin
     m_corner<=0;m_reason<=3;state<=EMIT;
    end else if(neighbor==7) state<=EMIT;
    else begin neighbor<=neighbor+1'b1;state<=NSELECT;end
    EMIT:if(m_ready) begin
     if(position==N-1) state<=COMPLETE;
     else begin advance_position();state<=CREAD;end
    end
    COMPLETE:if(done_ready) begin clear_position();state<=SYNC;done_error<=0;error_code<=0;end
   endcase
  end
 end
endmodule
