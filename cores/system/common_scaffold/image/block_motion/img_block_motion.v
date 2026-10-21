// Serial exhaustive integer block motion, actual partial-edge blocks supported.
`timescale 1ns/1ps
module img_block_motion #(
 parameter integer WIDTH=16,HEIGHT=12,BITS=8,BLOCK_W=8,BLOCK_H=8,SEARCH_RANGE=2
)(
 input wire clk,rst_n,clk_en,
 input wire cfg_valid,output wire cfg_ready,
 input wire [31:0] cfg_max_sad,cfg_min_gap,output reg cfg_done,
 input wire [BITS-1:0] s_current,s_reference,
 input wire s_valid,output wire s_ready,input wire s_sof,s_eol,
 output wire m_valid,input wire m_ready,
 output reg signed [15:0] m_dx,m_dy,
 output reg [31:0] m_sad,m_second_sad,m_gap,
 output wire [15:0] m_x,m_y,m_width,m_height,
 output reg m_invalid,output reg [1:0] m_reason,
 output wire m_sof,m_last,
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
 localparam N=WIDTH*HEIGHT,COST_W=cw(BLOCK_W*BLOCK_H*((1<<BITS)-1)+2),TW=cw(SEARCH_RANGE+1)+1;
 localparam [COST_W-1:0] SENTINEL={COST_W{1'b1}};
 localparam SYNC=0,CAPTURE=1,BINIT=2,CANDIDATE=3,ADDRESS=4,DIFFERENCE=5,ACCUMULATE=6,
            UPDATE=7,NEXT=8,REPORT=9,EMIT=10,COMPLETE=11;
 reg [3:0] state;
 reg [cw(WIDTH)-1:0] capture_x,origin_x;
 reg [cw(HEIGHT)-1:0] capture_y,origin_y;
 reg [cw(N)-1:0] capture_address;
 reg [cw(BLOCK_W)-1:0] ix;
 reg [cw(BLOCK_H)-1:0] iy;
 reg signed [TW-1:0] trial_dx,trial_dy,best_dx,best_dy;
 reg [BITS-1:0] current_mem[0:N-1],reference_mem[0:N-1];
 reg [BITS-1:0] current_q,reference_q,difference_q;
 reg [COST_W-1:0] accumulator,best,second;
 reg [31:0] max_sad,min_gap,frame_max_sad,frame_min_gap;
 wire [15:0] actual_width=WIDTH-origin_x<BLOCK_W ? WIDTH-origin_x:BLOCK_W;
 wire [15:0] actual_height=HEIGHT-origin_y<BLOCK_H ? HEIGHT-origin_y:BLOCK_H;
 wire signed [31:0] reference_x=$signed({1'b0,origin_x})+$signed(trial_dx);
 wire signed [31:0] reference_y=$signed({1'b0,origin_y})+$signed(trial_dy);
 wire candidate_inside=reference_x>=0&&reference_y>=0&&
                         reference_x+actual_width<=WIDTH&&reference_y+actual_height<=HEIGHT;
 wire [31:0] current_address=row_offset(origin_y+iy)+origin_x+ix;
 wire [31:0] reference_address=row_offset(reference_y+iy)+reference_x+ix;
 wire [TW:0] trial_ax=trial_dx<0 ? -trial_dx:trial_dx;
 wire [TW:0] trial_ay=trial_dy<0 ? -trial_dy:trial_dy;
 wire [TW:0] best_ax=best_dx<0 ? -best_dx:best_dx;
 wire [TW:0] best_ay=best_dy<0 ? -best_dy:best_dy;
 wire [TW+1:0] trial_magnitude=trial_ax+trial_ay,best_magnitude=best_ax+best_ay;
 wire tie_better=trial_magnitude<best_magnitude || (trial_magnitude==best_magnitude&&
                 (trial_dy<best_dy || (trial_dy==best_dy&&trial_dx<best_dx)));
 wire [31:0] public_best=best;
 wire [31:0] public_second=second==SENTINEL ? 32'hffffffff:second;
 wire [31:0] public_gap=second==SENTINEL ? 32'hffffffff:second-best;
 wire input_ok=s_sof==(capture_address==0)&&s_eol==(capture_x==WIDTH-1);
 wire capture_transfer=s_valid&&s_ready&&input_ok;
 assign cfg_ready=rst_n&&clk_en&&state==SYNC;
 assign s_ready=rst_n&&clk_en&&(state==SYNC||state==CAPTURE)&&!(state==SYNC&&cfg_valid);
 assign m_valid=state==EMIT;
 assign m_x=origin_x;assign m_y=origin_y;
 assign m_width=actual_width;assign m_height=actual_height;
 assign m_sof=m_valid&&origin_x==0&&origin_y==0;
 assign m_last=m_valid&&origin_x+BLOCK_W>=WIDTH&&origin_y+BLOCK_H>=HEIGHT;
 assign done_valid=state==COMPLETE;
 // Frame memories and synchronous read registers are intentionally not reset.
 always @(posedge clk) if(clk_en) begin
  if(capture_transfer) begin current_mem[capture_address]<=s_current;reference_mem[capture_address]<=s_reference;end
  if(state==ADDRESS) begin current_q<=current_mem[current_address];reference_q<=reference_mem[reference_address];end
 end
 task clear_capture;
 begin capture_x<=0;capture_y<=0;capture_address<=0;end
 endtask
 initial begin
  if(WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096||N>65536||BITS<8||BITS>12||
     BLOCK_W<1||BLOCK_H<1||BLOCK_W>64||BLOCK_H>64||SEARCH_RANGE<0||SEARCH_RANGE>15)
   $fatal(1,"invalid block-motion parameters");
 end
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   state<=SYNC;clear_capture();origin_x<=0;origin_y<=0;ix<=0;iy<=0;
   trial_dx<=0;trial_dy<=0;best_dx<=0;best_dy<=0;difference_q<=0;
   accumulator<=0;best<=SENTINEL;second<=SENTINEL;
   max_sad<=32'hffffffff;min_gap<=0;frame_max_sad<=32'hffffffff;frame_min_gap<=0;
   cfg_done<=0;m_dx<=0;m_dy<=0;m_sad<=0;m_second_sad<=0;m_gap<=0;m_invalid<=0;m_reason<=0;
   done_error<=0;error_code<=0;
  end else if(clk_en) begin
   cfg_done<=0;
   if(cfg_valid&&cfg_ready) begin max_sad<=cfg_max_sad;min_gap<=cfg_min_gap;cfg_done<=1;end
   case(state)
    SYNC,CAPTURE:if(s_valid&&s_ready) begin
     if(!input_ok) begin state<=COMPLETE;done_error<=1;error_code<=1;end
     else begin
      if(capture_address==0) begin frame_max_sad<=max_sad;frame_min_gap<=min_gap;done_error<=0;error_code<=0;end
      if(capture_address==N-1) begin origin_x<=0;origin_y<=0;clear_capture();state<=BINIT;end
      else begin
       capture_address<=capture_address+1'b1;
       if(capture_x==WIDTH-1) begin capture_x<=0;capture_y<=capture_y+1'b1;end else capture_x<=capture_x+1'b1;
       state<=CAPTURE;
      end
     end
    end
    BINIT:begin
     best<=SENTINEL;second<=SENTINEL;best_dx<=0;best_dy<=0;
     trial_dx<=-SEARCH_RANGE;trial_dy<=-SEARCH_RANGE;state<=CANDIDATE;
    end
    CANDIDATE:if(candidate_inside) begin ix<=0;iy<=0;accumulator<=0;state<=ADDRESS;end else state<=NEXT;
    ADDRESS:state<=DIFFERENCE;
    DIFFERENCE:begin difference_q<=current_q>=reference_q?current_q-reference_q:reference_q-current_q;state<=ACCUMULATE;end
    ACCUMULATE:begin
     accumulator<=accumulator+difference_q;
     if(ix==actual_width-1) begin
      ix<=0;
      if(iy==actual_height-1) state<=UPDATE;else begin iy<=iy+1'b1;state<=ADDRESS;end
     end else begin ix<=ix+1'b1;state<=ADDRESS;end
    end
    UPDATE:begin
     if(accumulator<best || (accumulator==best&&tie_better)) begin
      second<=best;best<=accumulator;best_dx<=trial_dx;best_dy<=trial_dy;
     end else if(accumulator<second) second<=accumulator;
     state<=NEXT;
    end
    NEXT:if(trial_dx==SEARCH_RANGE) begin
     trial_dx<=-SEARCH_RANGE;
     if(trial_dy==SEARCH_RANGE) state<=REPORT;else begin trial_dy<=trial_dy+1'b1;state<=CANDIDATE;end
    end else begin trial_dx<=trial_dx+1'b1;state<=CANDIDATE;end
    REPORT:begin
     m_dx<=best_dx;m_dy<=best_dy;m_sad<=public_best;m_second_sad<=public_second;m_gap<=public_gap;
     m_reason<={(public_gap<frame_min_gap),(public_best>frame_max_sad)};
     m_invalid<=public_gap<frame_min_gap || public_best>frame_max_sad;
     state<=EMIT;
    end
    EMIT:if(m_ready) begin
     if(origin_x+BLOCK_W>=WIDTH) begin
      origin_x<=0;
      if(origin_y+BLOCK_H>=HEIGHT) state<=COMPLETE;
      else begin origin_y<=origin_y+BLOCK_H;state<=BINIT;end
     end else begin origin_x<=origin_x+BLOCK_W;state<=BINIT;end
    end
    COMPLETE:if(done_ready) begin clear_capture();state<=SYNC;done_error<=0;error_code<=0;end
   endcase
  end
 end
endmodule
