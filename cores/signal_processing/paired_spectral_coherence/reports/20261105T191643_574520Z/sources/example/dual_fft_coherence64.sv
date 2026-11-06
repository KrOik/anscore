// SPDX-License-Identifier: Apache-2.0
// Independent ordered complex-spectrum streams, one holding slot per channel.
module dual_fft_coherence64(
 input wire clk,rst,c_valid,output wire c_ready,input wire[31:0]c_bins,c_averages,input wire[7:0]c_tag,
 input wire x_valid,output wire x_ready,input wire[31:0]x_data,input wire x_last,
 input wire y_valid,output wire y_ready,input wire[31:0]y_data,input wire y_last,
 output wire m_valid,input wire m_ready,output wire[2:0]m_status,output wire[31:0]m_index,
 output wire m_last,output wire[7:0]m_tag,output wire[35:0]m_sxx,m_syy,
 output wire signed[36:0]m_cross_re,m_cross_im,output wire[16:0]m_coherence_q16
);
 reg xv,yv,xl,yl;
 reg[31:0]xd,yd;
 reg[10:0]x_left,y_left;
 wire pair_ready;
 wire pair_valid=xv &&yv;
 assign x_ready=!rst &&!m_valid &&!xv &&x_left!=0;
 assign y_ready=!rst &&!m_valid &&!yv &&y_left!=0;
 always @(posedge clk)begin
   if(rst)begin xv<=0;yv<=0;xl<=0;yl<=0;xd<=0;yd<=0;x_left<=0;y_left<=0;end
   else if(c_valid &&c_ready)begin
     xv<=0;yv<=0;
     if(c_bins>=1 &&c_bins<=64 &&c_averages>=1 &&c_averages<=16)begin
       x_left<=c_bins[6:0]*c_averages[4:0];y_left<=c_bins[6:0]*c_averages[4:0];
     end else begin x_left<=0;y_left<=0;end
   end else if(m_valid &&m_last)begin
     // A fatal LAST/ARITH marker discards at most one prefetched word per lane.
     xv<=0;yv<=0;x_left<=0;y_left<=0;
   end else begin
     if(x_valid &&x_ready)begin xv<=1;xd<=x_data;xl<=x_last;x_left<=x_left-1'b1;end
     if(y_valid &&y_ready)begin yv<=1;yd<=y_data;yl<=y_last;y_left<=y_left-1'b1;end
     if(pair_valid &&pair_ready)begin xv<=0;yv<=0;end
   end
 end
 paired_spectral_coherence #(.MAX_BINS(64),.MAX_AVERAGES(16),.TAG_W(8)) instrument(
   .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_bins(c_bins),.c_averages(c_averages),.c_tag(c_tag),
   .s_valid(pair_valid),.s_ready(pair_ready),.s_xy({yd,xd}),.s_x_last(xl),.s_y_last(yl),
   .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_index(m_index),.m_last(m_last),.m_tag(m_tag),
   .m_sxx(m_sxx),.m_syy(m_syy),.m_cross_re(m_cross_re),.m_cross_im(m_cross_im),.m_coherence_q16(m_coherence_q16));
endmodule
