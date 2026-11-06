// SPDX-License-Identifier: Apache-2.0
// Local cross-green equalization; ordinary ready/valid, sync high reset.
`timescale 1ns/1ps
module raw_green_equalize #(
 parameter WIDTH=64,HEIGHT=48,BITS=12,TAG_W=8
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,
 input wire c_enable,input wire [1:0] c_pattern,
 input wire [BITS-1:0] c_imbalance_threshold,c_edge_threshold,
 input wire [TAG_W-1:0] c_tag,
 input wire [BITS-1:0] s_data,input wire s_valid,output wire s_ready,
 input wire s_sof,s_eol,s_last,
 output wire [BITS-1:0] m_data,output wire m_valid,input wire m_ready,
 output wire m_sof,m_eol,m_last,m_applied,m_changed,
 output wire d_valid,input wire d_ready,output reg [1:0] d_error,
 output reg [TAG_W-1:0] d_tag,
 output reg [16:0] d_applied,d_changed,output wire busy
);
 localparam N=WIDTH*HEIGHT;
 localparam XW=(WIDTH<2)?1:$clog2(WIDTH);
 localparam YW=(HEIGHT<2)?1:$clog2(HEIGHT);
 reg active,done_q,enabled;
 reg [1:0] pattern,error_q;
 reg [BITS-1:0] imbalance_threshold,edge_threshold;
 reg [16:0] inputs,windows,outputs,applied_count,changed_count;
 reg [XW-1:0] ix,wx;
 reg [YW-1:0] wy;
 wire window_rst_n=!rst&&active;
 wire [9*BITS-1:0] taps;
 wire w_valid,w_ready,w_sof,w_eol,w_error,wi_ready;
 wire ingress=active&&(inputs<N);
 assign c_ready=!rst&&!active&&!done_q;
 assign s_ready=!rst&&ingress&&wi_ready;
 assign d_valid=!rst&&done_q;
 assign busy=!rst&&(active||done_q);
 // Canonical markers preserve deterministic window alignment even when the
 // caller supplies a malformed marker. Such a frame is reported bad at DONE.
 stream_window_padded #(.DATA_WIDTH(BITS),.WIDTH(WIDTH),.HEIGHT(HEIGHT),
  .K(3),.PAD_MODE(1),.MAX_WIDTH(WIDTH)) window_i(
  .clk(clk),.rst_n(window_rst_n),.s_tdata(s_data),
  .s_tvalid(s_valid&&ingress),.s_tready(wi_ready),
  .s_tuser(inputs==0),.s_tlast(ix==WIDTH-1),
  .m_tdata(taps),.m_tvalid(w_valid),.m_tready(w_ready),
  .m_tuser(w_sof),.m_tlast(w_eol),.marker_error(w_error));
 wire [BITS-1:0] tl=taps[0*BITS+:BITS],tr=taps[2*BITS+:BITS];
 wire [BITS-1:0] center=taps[4*BITS+:BITS];
 wire [BITS-1:0] bl=taps[6*BITS+:BITS],br=taps[8*BITS+:BITS];
 wire [BITS+1:0] diagonal_sum={2'b0,tl}+{2'b0,tr}+{2'b0,bl}+{2'b0,br};
 wire [BITS-1:0] low_top=(tl<tr)?tl:tr,low_bottom=(bl<br)?bl:br;
 wire [BITS-1:0] high_top=(tl>tr)?tl:tr,high_bottom=(bl>br)?bl:br;
 wire [BITS-1:0] low=(low_top<low_bottom)?low_top:low_bottom;
 wire [BITS-1:0] high=(high_top>high_bottom)?high_top:high_bottom;
 wire [1:0] site={wy[0],wx[0]}^pattern;
 wire interior=(wx!=0)&&(wy!=0)&&(wx!=WIDTH-1)&&(wy!=HEIGHT-1);
 reg a_valid,b_valid;
 reg [BITS-1:0] a_center,a_range,b_data;
 reg [BITS+1:0] a_sum;
 reg a_eligible,a_sof,a_eol,a_last;
 reg b_applied,b_changed,b_sof,b_eol,b_last;
 wire b_ready=!b_valid||m_ready;
 wire a_ready=!a_valid||b_ready;
 assign w_ready=!rst&&active&&a_ready&&(windows<N);
 wire [BITS+1:0] average_bias=a_sum+{{BITS{1'b0}},2'd2};
 wire [BITS-1:0] diagonal_average=average_bias[BITS+1:2];
 wire [BITS-1:0] delta=(a_center>=diagonal_average)?
  a_center-diagonal_average:diagonal_average-a_center;
 wire apply_q=a_eligible&&(a_range<=edge_threshold)&&(delta<=imbalance_threshold);
 // Convex mixture maximum is 8*(2^BITS-1)+4 < 2^(BITS+3).
 wire [BITS+2:0] mixture={1'b0,a_center,2'b0}+{1'b0,a_sum}+{{BITS{1'b0}},3'd4};
 wire [BITS-1:0] corrected=mixture[BITS+2:3];
 assign m_valid=!rst&&active&&b_valid;
 assign m_data=b_data;assign m_applied=b_applied;assign m_changed=b_changed;
 assign m_sof=b_sof;assign m_eol=b_eol;assign m_last=b_last;
 always @(posedge clk) begin
  if(rst)begin
   active<=0;done_q<=0;enabled<=0;pattern<=0;error_q<=0;
   imbalance_threshold<=0;edge_threshold<=0;d_tag<=0;d_error<=0;
   inputs<=0;windows<=0;outputs<=0;applied_count<=0;changed_count<=0;
   d_applied<=0;d_changed<=0;ix<=0;wx<=0;wy<=0;
   a_valid<=0;b_valid<=0;a_center<=0;a_sum<=0;a_range<=0;
   a_eligible<=0;a_sof<=0;a_eol<=0;a_last<=0;
   b_data<=0;b_applied<=0;b_changed<=0;b_sof<=0;b_eol<=0;b_last<=0;
  end else begin
   if(done_q&&d_ready)done_q<=0;
   if(c_valid&&c_ready)begin
    active<=1;enabled<=c_enable;pattern<=c_pattern;
    imbalance_threshold<=c_imbalance_threshold;edge_threshold<=c_edge_threshold;
    d_tag<=c_tag;error_q<=0;d_error<=0;d_applied<=0;d_changed<=0;
    inputs<=0;windows<=0;outputs<=0;applied_count<=0;changed_count<=0;
    ix<=0;wx<=0;wy<=0;
   end
   if(!active)begin a_valid<=0;b_valid<=0;end
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
      a_center<=center;a_sum<=diagonal_sum;a_range<=high-low;
      a_eligible<=enabled&&(site[0]^site[1])&&interior;
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
      b_data<=apply_q?corrected:a_center;b_applied<=apply_q;
      b_changed<=apply_q&&(corrected!=a_center);
      b_sof<=a_sof;b_eol<=a_eol;b_last<=a_last;
     end
    end
    if(m_valid&&m_ready)begin
     outputs<=outputs+1'b1;
     applied_count<=applied_count+{{16{1'b0}},b_applied};
     changed_count<=changed_count+{{16{1'b0}},b_changed};
     if(b_last)begin
      active<=0;done_q<=1;d_error<=error_q|{w_error,1'b0};
      d_applied<=applied_count+{{16{1'b0}},b_applied};
      d_changed<=changed_count+{{16{1'b0}},b_changed};
     end
    end
   end
  end
 end
 initial if(WIDTH<1||WIDTH>512||HEIGHT<1||HEIGHT>512||N>65536||
  (BITS!=8&&BITS!=10&&BITS!=12)||TAG_W<1||TAG_W>32)
  $fatal(1,"raw_green_equalize parameters");
endmodule
