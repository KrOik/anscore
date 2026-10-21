// Rectified integer-disparity left/right consistency check; positive magnitudes.
`timescale 1ns/1ps
module img_stereo_lr_check #(
 parameter integer WIDTH=8,HEIGHT=6,DISP_BITS=8
)(
 input wire clk,rst_n,clk_en,
 input wire cfg_valid,output wire cfg_ready,
 input wire [DISP_BITS-1:0] cfg_threshold,output reg cfg_done,
 input wire [DISP_BITS-1:0] s_left_disp,s_right_disp,
 input wire s_left_invalid,s_right_invalid,
 input wire s_valid,output wire s_ready,input wire s_sof,s_eol,
 output reg [DISP_BITS-1:0] m_left_disp,
 output wire m_valid,input wire m_ready,
 output reg m_invalid,output reg [2:0] m_reason,
 output wire m_sof,m_eol,
 output wire done_valid,input wire done_ready,
 output reg done_error,output reg [1:0] error_code
);
 function integer cw;
 input integer n;integer k;
 begin k=n-1;cw=0;while(k>0) begin cw=cw+1;k=k>>1;end if(cw==0) cw=1;end
 endfunction
 localparam integer N=WIDTH*HEIGHT;
 localparam SYNC=0,CAPTURE=1,LADDR=2,LCHECK=3,RADDR=4,RCHECK=5,EMIT=6,COMPLETE=7;
 reg [2:0] state;
 reg [cw(WIDTH)-1:0] x;
 reg [cw(HEIGHT)-1:0] y;
 reg [cw(N)-1:0] position,right_address,row_base;
 reg [DISP_BITS-1:0] threshold,frame_threshold,left_hold;
 reg [DISP_BITS:0] left_memory[0:N-1],right_memory[0:N-1];
 reg [DISP_BITS:0] left_q,right_q;
 wire first_pixel=position==0;
 wire input_ok=s_sof==first_pixel && s_eol==(x==WIDTH-1);
 wire capture_transfer=s_valid&&s_ready&&input_ok&&(state==CAPTURE||s_sof);
 wire [DISP_BITS-1:0] right_disp=right_q[DISP_BITS-1:0];
 wire [DISP_BITS-1:0] difference=left_hold>=right_disp?left_hold-right_disp:right_disp-left_hold;
 assign cfg_ready=rst_n&&clk_en&&state==SYNC;
 assign s_ready=rst_n&&clk_en&&(state==SYNC||state==CAPTURE)&&!(cfg_valid&&state==SYNC);
 assign m_valid=state==EMIT;
 assign m_sof=m_valid&&position==0;
 assign m_eol=m_valid&&x==WIDTH-1;
 assign done_valid=state==COMPLETE;
 // Synchronous RAM read ports; no RAM or read-register reset.
 always @(posedge clk) if(clk_en) begin
  if(capture_transfer) begin
   left_memory[position]<={s_left_invalid,s_left_disp};
   right_memory[position]<={s_right_invalid,s_right_disp};
  end
  if(state==LADDR) left_q<=left_memory[position];
  if(state==RADDR) right_q<=right_memory[right_address];
 end
 task clear_position;
 begin x<=0;y<=0;position<=0;row_base<=0;end
 endtask
 task advance_position;
 begin
  position<=position+1'b1;
  if(x==WIDTH-1) begin x<=0;y<=y+1'b1;row_base<=row_base+WIDTH;end
  else x<=x+1'b1;
 end
 endtask
 initial begin
  if(WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096||N>65536||DISP_BITS<1||DISP_BITS>16)
   $fatal(1,"invalid geometry/disparity parameters");
 end
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   state<=SYNC;clear_position();right_address<=0;threshold<=0;frame_threshold<=0;
   left_hold<=0;m_left_disp<=0;m_invalid<=0;m_reason<=0;cfg_done<=0;done_error<=0;error_code<=0;
  end else if(clk_en) begin
   cfg_done<=0;
   if(cfg_valid&&cfg_ready) begin threshold<=cfg_threshold;cfg_done<=1;end
   case(state)
    SYNC,CAPTURE:if(s_valid&&s_ready) begin
     if(!input_ok) begin state<=COMPLETE;done_error<=1;error_code<=1;end
     else begin
      if(first_pixel) begin frame_threshold<=threshold;done_error<=0;error_code<=0;end
      if(position==N-1) begin clear_position();state<=LADDR;end
      else begin advance_position();state<=CAPTURE;end
     end
    end
    LADDR:state<=LCHECK;
    LCHECK:begin
     left_hold<=left_q[DISP_BITS-1:0];m_left_disp<=left_q[DISP_BITS-1:0];
     if(left_q[DISP_BITS]) begin m_invalid<=1;m_reason<=1;state<=EMIT;end
     else if(left_q[DISP_BITS-1:0]>x) begin m_invalid<=1;m_reason<=2;state<=EMIT;end
     else begin right_address<=row_base+x-left_q[DISP_BITS-1:0];state<=RADDR;end
    end
    RADDR:state<=RCHECK;
    RCHECK:begin
     if(right_q[DISP_BITS]) begin m_invalid<=1;m_reason<=3;end
     else if(difference>frame_threshold) begin m_invalid<=1;m_reason<=4;end
     else begin m_invalid<=0;m_reason<=0;end
     state<=EMIT;
    end
    EMIT:if(m_ready) begin
     if(position==N-1) state<=COMPLETE;
     else begin advance_position();state<=LADDR;end
    end
    COMPLETE:if(done_ready) begin state<=SYNC;clear_position();done_error<=0;error_code<=0;end
   endcase
  end
 end
endmodule
