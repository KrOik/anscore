// Multi-level pyrDown: [1 4 6 4 1]^T*[1 4 6 4 1]/256, REFLECT_101 border.
module img_gaussian_pyramid_frame #(parameter BITS=8,WIDTH=16,HEIGHT=16,LEVELS=3)(
 input wire clk,rst_n,ce,
 input wire [BITS-1:0] s_data,input wire s_valid,output wire s_ready,input wire s_sof,s_eol,
 output reg [BITS-1:0] m_data,
 output reg [(LEVELS<=1?1:$clog2(LEVELS))-1:0] m_level,
 output wire m_valid,input wire m_ready,output wire m_sof,m_eol,
 output wire done_valid,input wire done_ready,output reg frame_error
);
 localparam CAPTURE=0,READ=1,ACCUMULATE=2,STORE=3,HOLD=4,DONE=5;
 reg [2:0] state;
 reg [BITS-1:0] bank_a[0:WIDTH*HEIGHT-1],bank_b[0:WIDTH*HEIGHT-1],q;
 reg bank;
 localparam XW=(WIDTH<2?1:$clog2(WIDTH+1)),YW=(HEIGHT<2?1:$clog2(HEIGHT+1));
 localparam AW=(WIDTH*HEIGHT<2?1:$clog2(WIDTH*HEIGHT));
 reg [AW-1:0] index;
 reg [XW-1:0] x,current_width,out_width;
 reg [YW-1:0] y,current_height,out_height;
 reg [2:0] tx,ty;
 reg [BITS+7:0] accumulator;
 wire [BITS+7:0] weighted=q*weight(tx)*weight(ty);
 wire [BITS+7:0] rounded=accumulator+128;
 wire [BITS-1:0] result_pixel=rounded[BITS+7:8];
 wire [AW-1:0] read_address=reflect101(2*y+ty-2,current_height)*current_width+reflect101(2*x+tx-2,current_width);
 wire [AW:0] level_pixels=out_width*out_height;
 assign s_ready=rst_n&&state==CAPTURE;
 assign m_valid=rst_n&&state==HOLD;
 assign m_sof=m_valid&&index==0;
 assign m_eol=m_valid&&x==out_width-1;
 assign done_valid=rst_n&&state==DONE;
 function [2:0] weight;
 input [2:0] t;
 begin case(t)0,4:weight=1;1,3:weight=4;default:weight=6;endcase end
 endfunction
 function integer reflect101;
 input integer position,size;integer v,k;
 begin
  v=position;
  if(size<=1)v=0;
  else for(k=0;k<3;k=k+1)begin
   if(v<0)v=-v;else if(v>=size)v=2*size-2-v;
  end
  reflect101=v;
 end
 endfunction
 initial begin
  if(BITS<8||BITS>16||WIDTH<1||HEIGHT<1||WIDTH>4096||HEIGHT>4096||WIDTH*HEIGHT>65536||LEVELS<1||LEVELS>4)
   $fatal(1,"img_gaussian_pyramid_frame invalid parameters");
 end
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=CAPTURE;index<=0;x<=0;y<=0;m_data<=0;m_level<=0;frame_error<=0;
   bank<=0;tx<=0;ty<=0;accumulator<=0;current_width<=WIDTH;current_height<=HEIGHT;
   out_width<=(WIDTH+1)/2;out_height<=(HEIGHT+1)/2;
  end else if(ce)begin
   case(state)
    CAPTURE:if(s_valid)begin
     if(s_sof!=(index==0)||s_eol!=(x==WIDTH-1))begin state<=DONE;frame_error<=1;end
     else begin
      bank_a[index]<=s_data;
      if(index==WIDTH*HEIGHT-1)begin index<=0;x<=0;y<=0;state<=READ;end
      else begin index<=index+1;if(x==WIDTH-1)begin x<=0;y<=y+1;end else x<=x+1;end
     end
    end
    READ:begin
     if(!bank)q<=bank_a[read_address];else q<=bank_b[read_address];
     state<=ACCUMULATE;
    end
    ACCUMULATE:begin
     accumulator<=accumulator+weighted;
     if(tx==4)begin tx<=0;if(ty==4)begin ty<=0;state<=STORE;end else begin ty<=ty+1;state<=READ;end end
     else begin tx<=tx+1;state<=READ;end
    end
    STORE:begin
     m_data<=result_pixel;
     if(!bank)bank_b[index]<=result_pixel;else bank_a[index]<=result_pixel;
     state<=HOLD;
    end
    HOLD:if(m_ready)begin
     accumulator<=0;
     if(index==level_pixels-1)begin
      if(m_level==LEVELS-1)state<=DONE;
      else begin
       m_level<=m_level+1;bank<=!bank;current_width<=out_width;current_height<=out_height;
       out_width<=(out_width+1)/2;out_height<=(out_height+1)/2;
       index<=0;x<=0;y<=0;state<=READ;
      end
     end else begin index<=index+1;if(x==out_width-1)begin x<=0;y<=y+1;end else x<=x+1;state<=READ;end
    end
    DONE:if(done_ready)begin
     state<=CAPTURE;index<=0;x<=0;y<=0;m_level<=0;frame_error<=0;bank<=0;
     current_width<=WIDTH;current_height<=HEIGHT;out_width<=(WIDTH+1)/2;out_height<=(HEIGHT+1)/2;
     tx<=0;ty<=0;accumulator<=0;
    end
    default:begin state<=DONE;frame_error<=1;end
   endcase
  end
 end
endmodule
