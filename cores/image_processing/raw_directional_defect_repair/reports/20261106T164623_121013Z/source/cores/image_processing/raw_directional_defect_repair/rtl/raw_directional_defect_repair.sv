// SPDX-License-Identifier: Apache-2.0
// Same-phase envelope detector and four-direction adaptive RAW repair.
`timescale 1ns/1ps
module raw_directional_defect_repair #(
 parameter WIDTH=64, HEIGHT=48, BITS=12, TAG_W=8
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,input wire c_enable,
 input wire [BITS-1:0] c_base_threshold,input wire [1:0] c_gradient_shift,
 input wire [TAG_W-1:0] c_tag,
 input wire [BITS-1:0] s_data,input wire s_valid,output wire s_ready,
 input wire s_sof,s_eol,s_last,
 output wire [BITS-1:0] m_data,output wire m_valid,input wire m_ready,
 output wire m_sof,m_eol,m_last,m_repaired,output wire [1:0] m_direction,
 output wire d_valid,input wire d_ready,output reg [1:0] d_error,
 output reg [TAG_W-1:0] d_tag,output reg [16:0] d_repaired,output wire busy
);
 localparam N=WIDTH*HEIGHT;
 localparam XW=(WIDTH<2)?1:$clog2(WIDTH);
 localparam YW=(HEIGHT<2)?1:$clog2(HEIGHT);
 reg active,done_q,enabled;
 reg [BITS-1:0] base_threshold;
 reg [1:0] gradient_shift,error_q;
 reg [16:0] inputs,windows,outputs,repaired_count;
 reg [XW-1:0] ix,wx;
 reg [YW-1:0] wy;
 wire [25*BITS-1:0] taps;
 wire wi_ready,w_valid,w_ready,w_sof,w_eol,w_error;
 wire ingress=active&&(inputs<N);
 assign c_ready=!rst&&!active&&!done_q;
 assign s_ready=!rst&&ingress&&wi_ready;
 assign d_valid=!rst&&done_q;
 assign busy=!rst&&(active||done_q);
 // Only control is reset between owned frames. All visible taps come from
 // the next fully overwritten row history before any window is admitted.
 stream_window_padded #(.DATA_WIDTH(BITS),.WIDTH(WIDTH),.HEIGHT(HEIGHT),
  .K(5),.PAD_MODE(1),.MAX_WIDTH(WIDTH)) window_i(
  .clk(clk),.rst_n(!rst&&active),.s_tdata(s_data),
  .s_tvalid(s_valid&&ingress),.s_tready(wi_ready),
  .s_tuser(inputs==0),.s_tlast(ix==WIDTH-1),
  .m_tdata(taps),.m_tvalid(w_valid),.m_tready(w_ready),
  .m_tuser(w_sof),.m_tlast(w_eol),.marker_error(w_error));
 wire [BITS-1:0] nw=taps[0*BITS+:BITS],nn=taps[2*BITS+:BITS],ne=taps[4*BITS+:BITS];
 wire [BITS-1:0] ww=taps[10*BITS+:BITS],cc=taps[12*BITS+:BITS],ee=taps[14*BITS+:BITS];
 wire [BITS-1:0] sw=taps[20*BITS+:BITS],ss=taps[22*BITS+:BITS],se=taps[24*BITS+:BITS];
 wire [BITS-1:0] p0lo=(ww<ee)?ww:ee,p0hi=(ww>ee)?ww:ee;
 wire [BITS-1:0] p1lo=(nn<ss)?nn:ss,p1hi=(nn>ss)?nn:ss;
 wire [BITS-1:0] p2lo=(nw<se)?nw:se,p2hi=(nw>se)?nw:se;
 wire [BITS-1:0] p3lo=(ne<sw)?ne:sw,p3hi=(ne>sw)?ne:sw;
 wire [BITS-1:0] lo01=(p0lo<p1lo)?p0lo:p1lo,lo23=(p2lo<p3lo)?p2lo:p3lo;
 wire [BITS-1:0] hi01=(p0hi>p1hi)?p0hi:p1hi,hi23=(p2hi>p3hi)?p2hi:p3hi;
 wire interior=(WIDTH>=5)&&(HEIGHT>=5)&&(wx>=2)&&(wy>=2)&&(wx<WIDTH-2)&&(wy<HEIGHT-2);
 reg a_valid,b_valid,z_valid;
 reg [BITS-1:0] a_center,a_low,a_high;
 reg [BITS-1:0] a_grad[0:3];
 reg [BITS:0] a_sum[0:3];
 reg a_eligible,a_sof,a_eol,a_last;
 reg [BITS-1:0] b_center,b_low,b_high,b_grad,b_predictor;
 reg [1:0] b_direction;
 reg b_eligible,b_sof,b_eol,b_last;
 reg [BITS-1:0] z_data;
 reg [1:0] z_direction;
 reg z_repaired,z_sof,z_eol,z_last;
 wire z_ready=!z_valid||m_ready;
 wire b_ready=!b_valid||z_ready;
 wire a_ready=!a_valid||b_ready;
 assign w_ready=!rst&&active&&a_ready&&(windows<N);
 reg [BITS-1:0] chosen_grad;
 reg [BITS:0] chosen_sum;
 reg [1:0] chosen_direction;
 integer k;
 // Strict replacement preserves H,V,backslash,slash priority on ties.
 always @* begin
  chosen_grad=a_grad[0];chosen_sum=a_sum[0];chosen_direction=0;
  for(k=1;k<4;k=k+1)if(a_grad[k]<chosen_grad)begin
   chosen_grad=a_grad[k];chosen_sum=a_sum[k];chosen_direction=k[1:0];
  end
 end
 wire [BITS:0] predictor_bias=chosen_sum+{{BITS{1'b0}},1'b1};
 // The unsaturated BITS+1 threshold can reach 2*(2^BITS-1).
 // Comparing in that full width avoids an overflow-induced false defect.
 wire [BITS:0] threshold={1'b0,base_threshold}+{1'b0,(b_grad>>gradient_shift)};
 wire [BITS-1:0] excess=(b_center<b_low)?b_low-b_center:
  (b_center>b_high)?b_center-b_high:{BITS{1'b0}};
 wire repair=b_eligible&&({1'b0,excess}>threshold);
 assign m_valid=!rst&&active&&z_valid;
 assign m_data=z_data;assign m_direction=z_direction;assign m_repaired=z_repaired;
 assign m_sof=z_sof;assign m_eol=z_eol;assign m_last=z_last;
 integer r;
 always @(posedge clk)begin
  if(rst)begin
   active<=0;done_q<=0;enabled<=0;base_threshold<=0;gradient_shift<=0;error_q<=0;
   inputs<=0;windows<=0;outputs<=0;repaired_count<=0;ix<=0;wx<=0;wy<=0;
   d_error<=0;d_tag<=0;d_repaired<=0;a_valid<=0;b_valid<=0;z_valid<=0;
   a_center<=0;a_low<=0;a_high<=0;a_eligible<=0;a_sof<=0;a_eol<=0;a_last<=0;
   for(r=0;r<4;r=r+1)begin a_grad[r]<=0;a_sum[r]<=0;end
   b_center<=0;b_low<=0;b_high<=0;b_grad<=0;b_predictor<=0;b_direction<=0;
   b_eligible<=0;b_sof<=0;b_eol<=0;b_last<=0;
   z_data<=0;z_direction<=0;z_repaired<=0;z_sof<=0;z_eol<=0;z_last<=0;
  end else begin
   if(done_q&&d_ready)done_q<=0;
   if(c_valid&&c_ready)begin
    active<=1;enabled<=c_enable;base_threshold<=c_base_threshold;gradient_shift<=c_gradient_shift;
    d_tag<=c_tag;error_q<=0;d_error<=0;d_repaired<=0;
    inputs<=0;windows<=0;outputs<=0;repaired_count<=0;ix<=0;wx<=0;wy<=0;
   end
   if(!active)begin a_valid<=0;b_valid<=0;z_valid<=0;end
   else begin
    if(s_valid&&s_ready)begin
     inputs<=inputs+1'b1;
     if(s_sof!=(inputs==0)||s_eol!=(ix==WIDTH-1)||s_last!=(inputs==N-1))error_q[0]<=1;
     ix<=(ix==WIDTH-1)?{XW{1'b0}}:ix+1'b1;
    end
    if(w_error)error_q[1]<=1;
    if(a_ready)begin
     a_valid<=w_valid&&(windows<N);
     if(w_valid&&(windows<N))begin
      a_center<=cc;a_low<=(lo01<lo23)?lo01:lo23;a_high<=(hi01>hi23)?hi01:hi23;
      a_grad[0]<=p0hi-p0lo;a_grad[1]<=p1hi-p1lo;a_grad[2]<=p2hi-p2lo;a_grad[3]<=p3hi-p3lo;
      a_sum[0]<={1'b0,ww}+{1'b0,ee};a_sum[1]<={1'b0,nn}+{1'b0,ss};
      a_sum[2]<={1'b0,nw}+{1'b0,se};a_sum[3]<={1'b0,ne}+{1'b0,sw};
      a_eligible<=enabled&&interior;
      a_sof<=windows==0;a_eol<=wx==WIDTH-1;a_last<=windows==N-1;
      if(w_sof!=(windows==0)||w_eol!=(wx==WIDTH-1))error_q[1]<=1;
      windows<=windows+1'b1;
      if(wx==WIDTH-1)begin wx<=0;wy<=(wy==HEIGHT-1)?{YW{1'b0}}:wy+1'b1;end
      else wx<=wx+1'b1;
     end
    end
    if(b_ready)begin
     b_valid<=a_valid;
     if(a_valid)begin
      b_center<=a_center;b_low<=a_low;b_high<=a_high;b_grad<=chosen_grad;
      b_predictor<=predictor_bias[BITS:1];b_direction<=chosen_direction;
      b_eligible<=a_eligible;b_sof<=a_sof;b_eol<=a_eol;b_last<=a_last;
     end
    end
    if(z_ready)begin
     z_valid<=b_valid;
     if(b_valid)begin
      z_data<=repair?b_predictor:b_center;z_repaired<=repair;
      z_direction<=repair?b_direction:2'd0;
      z_sof<=b_sof;z_eol<=b_eol;z_last<=b_last;
     end
    end
    if(m_valid&&m_ready)begin
     outputs<=outputs+1'b1;repaired_count<=repaired_count+{{16{1'b0}},z_repaired};
     if(z_last)begin
      active<=0;done_q<=1;d_error<=error_q|{w_error,1'b0};
      d_repaired<=repaired_count+{{16{1'b0}},z_repaired};
     end
    end
   end
  end
 end
 initial if(WIDTH<1||WIDTH>512||HEIGHT<1||HEIGHT>512||N>65536||
  (BITS!=8&&BITS!=10&&BITS!=12)||TAG_W<1||TAG_W>32)
  $fatal(1,"raw_directional_defect_repair parameters");
endmodule
