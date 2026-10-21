// Full-frame synchronous-RAM raster <-> 8x8 block rearranger.
`timescale 1ns/1ps
module img_raster_blocks #(
 parameter integer BITS=8,WIDTH=8,HEIGHT=8,TO_BLOCK=1
)(
 input wire clk,rst_n,clk_en,
 input wire [BITS-1:0] s_data,input wire s_valid,output wire s_ready,
 input wire s_sof,s_eol,s_block_first,s_block_last,
 output wire [BITS-1:0] m_data,output wire m_valid,input wire m_ready,
 output wire m_sof,m_eol,m_block_first,m_block_last,m_frame_last,
 output reg protocol_error,error_pulse
);
 function integer cw;
 input integer n;integer k;
 begin k=n-1;cw=0;while(k>0) begin cw=cw+1;k=k>>1;end if(cw==0) cw=1;end
 endfunction
 function [31:0] row_offset;
 input [31:0] row;integer bit_number;reg [31:0] sum;
 begin
  sum=0;
  // Explicit constant-stride shift/add prevents address math consuming DSPs.
  for(bit_number=0;bit_number<13;bit_number=bit_number+1)
   if((WIDTH>>bit_number)&1) sum=sum+(row<<bit_number);
  row_offset=sum;
 end
 endfunction
 localparam integer BX=(WIDTH+7)/8,BY=(HEIGHT+7)/8;
 localparam CAPTURE=0,ADDRESS=1,EMIT=2,RESYNC=3;
 reg [1:0] state;
 reg [cw(WIDTH)-1:0] x;
 reg [cw(HEIGHT)-1:0] y;
 reg [cw(BX)-1:0] bx;
 reg [cw(BY)-1:0] by;
 reg [2:0] ix,iy;
 reg [BITS-1:0] memory[0:WIDTH*HEIGHT-1];
 reg [BITS-1:0] ram_q;
 wire raster_first=x==0 && y==0;
 wire raster_last=x==WIDTH-1 && y==HEIGHT-1;
 wire block_first=ix==0 && iy==0;
 wire block_last=ix==7 && iy==7;
 wire blocks_first=bx==0 && by==0 && block_first;
 wire blocks_last=bx==BX-1 && by==BY-1 && block_last;
 wire input_first=TO_BLOCK ? raster_first:blocks_first;
 wire input_last=TO_BLOCK ? raster_last:blocks_last;
 wire input_eol=TO_BLOCK ? x==WIDTH-1:ix==7;
 wire markers_ok=s_sof==input_first && s_eol==input_eol &&
   s_block_first==(TO_BLOCK?1'b0:block_first) && s_block_last==(TO_BLOCK?1'b0:block_last);
 wire [31:0] block_x=bx*8+ix,block_y=by*8+iy;
 wire [31:0] capture_x=TO_BLOCK?x:block_x,capture_y=TO_BLOCK?y:block_y;
 wire capture_inside=capture_x<WIDTH && capture_y<HEIGHT;
 wire [31:0] write_address=row_offset(capture_y)+capture_x;
 wire [31:0] read_x=TO_BLOCK ? (block_x>=WIDTH ? WIDTH-1:block_x):x;
 wire [31:0] read_y=TO_BLOCK ? (block_y>=HEIGHT ? HEIGHT-1:block_y):y;
 wire [31:0] read_address=row_offset(read_y)+read_x;
 wire capture_transfer=s_valid && s_ready && markers_ok && (state==CAPTURE || s_sof);
 assign s_ready=rst_n && clk_en && (state==CAPTURE || state==RESYNC);
 assign m_valid=state==EMIT;
 assign m_data=ram_q;
 assign m_sof=m_valid && (TO_BLOCK?blocks_first:raster_first);
 assign m_eol=m_valid && (TO_BLOCK?ix==7:x==WIDTH-1);
 assign m_block_first=m_valid && TO_BLOCK && block_first;
 assign m_block_last=m_valid && TO_BLOCK && block_last;
 assign m_frame_last=m_valid && (TO_BLOCK?blocks_last:raster_last);
 // Neither frame RAM nor read register is reset: preserves block RAM inference.
 always @(posedge clk) if(clk_en) begin
  if(capture_transfer && capture_inside) memory[write_address]<=s_data;
  if(state==ADDRESS) ram_q<=memory[read_address];
 end
 task clear_position;
 begin x<=0;y<=0;bx<=0;by<=0;ix<=0;iy<=0;end
 endtask
 task advance_raster;
 begin
  if(x==WIDTH-1) begin x<=0;y<=y+1'b1;end else x<=x+1'b1;
 end
 endtask
 task advance_block;
 begin
  if(ix==7) begin
   ix<=0;
   if(iy==7) begin
    iy<=0;
    if(bx==BX-1) begin bx<=0;by<=by+1'b1;end else bx<=bx+1'b1;
   end else iy<=iy+1'b1;
  end else ix<=ix+1'b1;
 end
 endtask
 initial begin
  if((BITS!=8 && BITS!=10 && BITS!=12)||WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096||
    (TO_BLOCK!=0 && TO_BLOCK!=1)) $fatal(1,"invalid parameters");
 end
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin state<=RESYNC;protocol_error<=0;error_pulse<=0;clear_position();end
  else if(clk_en) begin
   error_pulse<=0;
   if((state==CAPTURE || state==RESYNC) && s_valid && s_ready) begin
    if(state==RESYNC && !s_sof) begin end // Drop until a new frame boundary.
    else if(!markers_ok) begin
     protocol_error<=1;error_pulse<=1;state<=RESYNC;clear_position();
    end else if(input_last) begin state<=ADDRESS;clear_position();end
    else begin state<=CAPTURE;if(TO_BLOCK) advance_raster();else advance_block();end
   end
   if(state==ADDRESS) state<=EMIT;
   if(state==EMIT && m_ready) begin
    if(TO_BLOCK?blocks_last:raster_last) begin state<=RESYNC;clear_position();end
    else begin state<=ADDRESS;if(TO_BLOCK) advance_block();else advance_raster();end
   end
  end
 end
endmodule
