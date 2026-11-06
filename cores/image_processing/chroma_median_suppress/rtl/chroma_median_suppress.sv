// SPDX-License-Identifier: Apache-2.0
// Same-resolution, luma-gated chroma median; ordinary ready/valid.
`timescale 1ns/1ps
module chroma_median_suppress #(
 parameter WIDTH=64,HEIGHT=48,BITS=8,TAG_W=8
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,input wire c_enable,
 input wire [BITS-1:0] c_luma_threshold,input wire [TAG_W-1:0] c_tag,
 input wire [3*BITS-1:0] s_data,input wire s_valid,output wire s_ready,
 input wire s_sof,s_eol,s_last,
 output wire [3*BITS-1:0] m_data,output wire m_valid,input wire m_ready,
 output wire m_sof,m_eol,m_last,m_applied,m_changed,
 output wire d_valid,input wire d_ready,output reg [1:0] d_error,
 output reg [TAG_W-1:0] d_tag,output reg [16:0] d_applied,d_changed,
 output wire busy
);
 localparam N=WIDTH*HEIGHT,STAGES=10;
 localparam XW=(WIDTH<2)?1:$clog2(WIDTH),YW=(HEIGHT<2)?1:$clog2(HEIGHT);
 reg active,done_q,enabled;
 reg [BITS-1:0] threshold;
 reg [1:0] error_q;
 reg [16:0] inputs,windows,outputs,applied_count,changed_count;
 reg [XW-1:0] ix,wx,ox;
 reg [YW-1:0] wy;
 wire run_n=!rst&&active;
 wire ingress=active&&(inputs<N);
 wire [2:0] input_ready,window_valid,window_sof,window_eol,window_error;
 wire [9*BITS-1:0] taps[0:2]; // plane0 Cr, plane1 Cb, plane2 Y
 wire all_input_ready=&input_ready,all_window_valid=&window_valid;
 wire [1:0] net_ready,net_valid,net_sof,net_eol;
 wire [BITS-1:0] median_cb,median_cr;
 wire advance=&net_ready;
 wire take_window=all_window_valid&&advance&&(windows<N)&&active;
 wire net_offer=all_window_valid&&(windows<N)&&active;
 assign c_ready=!rst&&!active&&!done_q;
 assign s_ready=!rst&&ingress&&all_input_ready;
 assign busy=!rst&&(active||done_q);
 assign d_valid=!rst&&done_q;
 genvar p;
 generate for(p=0;p<3;p=p+1)begin: plane
  // Atomic fanout; none of the window ready signals depends on input valid.
  wire other_valid=(p==0)?(&window_valid[2:1]):
   (p==1)?(window_valid[0]&&window_valid[2]):(&window_valid[1:0]);
  stream_window_padded #(.DATA_WIDTH(BITS),.WIDTH(WIDTH),.HEIGHT(HEIGHT),
   .K(3),.PAD_MODE(1),.MAX_WIDTH(WIDTH)) window_i(
   .clk(clk),.rst_n(run_n),.s_tdata(s_data[p*BITS+:BITS]),
   .s_tvalid(s_valid&&ingress&&all_input_ready),.s_tready(input_ready[p]),
   .s_tuser(inputs==0),.s_tlast(ix==WIDTH-1),
   .m_tdata(taps[p]),.m_tvalid(window_valid[p]),
   .m_tready(advance&&other_valid&&(windows<N)&&active),
   .m_tuser(window_sof[p]),.m_tlast(window_eol[p]),.marker_error(window_error[p]));
 end endgenerate
 median_network #(.BITS(BITS),.K(3)) cb_network(
  .clk(clk),.rst_n(run_n),.s_tdata(taps[1]),.s_tvalid(net_offer),
  .s_tready(net_ready[0]),.s_tuser(windows==0),.s_tlast(wx==WIDTH-1),
  .m_tdata(median_cb),.m_tvalid(net_valid[0]),.m_tuser(net_sof[0]),.m_tlast(net_eol[0]),
  .m_tready(m_ready&&active&&!rst));
 median_network #(.BITS(BITS),.K(3)) cr_network(
  .clk(clk),.rst_n(run_n),.s_tdata(taps[0]),.s_tvalid(net_offer),
  .s_tready(net_ready[1]),.s_tuser(windows==0),.s_tlast(wx==WIDTH-1),
  .m_tdata(median_cr),.m_tvalid(net_valid[1]),.m_tuser(net_sof[1]),.m_tlast(net_eol[1]),
  .m_tready(m_ready&&active&&!rst));
 // Same ten-stage, globally stalled schedule as the unchanged median networks.
 reg [3*BITS-1:0] original[0:STAGES-1];
 reg [STAGES-1:0] gate_pipe;
 wire [BITS-1:0] y_min,y_max;
 wire [BITS-1:0] ymin1[0:3],ymax1[0:3],ymin2[0:1],ymax2[0:1];
 genvar r;
 generate for(r=0;r<4;r=r+1)begin: luma_pair
  wire [BITS-1:0] a=taps[2][2*r*BITS+:BITS],b=taps[2][(2*r+1)*BITS+:BITS];
  assign ymin1[r]=(a<b)?a:b;assign ymax1[r]=(a>b)?a:b;
 end
 for(r=0;r<2;r=r+1)begin: luma_quad
  assign ymin2[r]=(ymin1[2*r]<ymin1[2*r+1])?ymin1[2*r]:ymin1[2*r+1];
  assign ymax2[r]=(ymax1[2*r]>ymax1[2*r+1])?ymax1[2*r]:ymax1[2*r+1];
 end endgenerate
 wire [BITS-1:0] min8=(ymin2[0]<ymin2[1])?ymin2[0]:ymin2[1];
 wire [BITS-1:0] max8=(ymax2[0]>ymax2[1])?ymax2[0]:ymax2[1];
 assign y_min=(min8<taps[2][8*BITS+:BITS])?min8:taps[2][8*BITS+:BITS];
 assign y_max=(max8>taps[2][8*BITS+:BITS])?max8:taps[2][8*BITS+:BITS];
 integer j;
 wire [BITS-1:0] y_range=y_max-y_min;
 wire interior=wx!=0&&wy!=0&&wx!=WIDTH-1&&wy!=HEIGHT-1;
 wire [3*BITS-1:0] center={taps[2][4*BITS+:BITS],taps[1][4*BITS+:BITS],taps[0][4*BITS+:BITS]};
 assign m_valid=!rst&&active&&(&net_valid);
 assign m_applied=gate_pipe[STAGES-1];
 assign m_data=m_applied?{original[STAGES-1][3*BITS-1:2*BITS],median_cb,median_cr}:original[STAGES-1];
 assign m_changed=m_data!=original[STAGES-1];
 assign m_sof=outputs==0;assign m_eol=ox==WIDTH-1;assign m_last=outputs==N-1;
 always @(posedge clk)begin
  if(rst)begin
   active<=0;done_q<=0;enabled<=0;threshold<=0;error_q<=0;
   inputs<=0;windows<=0;outputs<=0;applied_count<=0;changed_count<=0;
   ix<=0;wx<=0;wy<=0;ox<=0;d_error<=0;d_tag<=0;d_applied<=0;d_changed<=0;
   gate_pipe<=0;
  end else begin
   if(done_q&&d_ready)done_q<=0;
   if(c_valid&&c_ready)begin
    active<=1;enabled<=c_enable;threshold<=c_luma_threshold;d_tag<=c_tag;
    error_q<=0;d_error<=0;d_applied<=0;d_changed<=0;
    inputs<=0;windows<=0;outputs<=0;applied_count<=0;changed_count<=0;
    ix<=0;wx<=0;wy<=0;ox<=0;gate_pipe<=0;
   end
   if(active)begin
    if(s_valid&&s_ready)begin
     inputs<=inputs+1'b1;
     if(s_sof!=(inputs==0)||s_eol!=(ix==WIDTH-1)||s_last!=(inputs==N-1))error_q[0]<=1;
     ix<=(ix==WIDTH-1)?{XW{1'b0}}:ix+1'b1;
    end
    if((|window_error)||net_ready[0]!=net_ready[1]||net_valid[0]!=net_valid[1]||
       window_valid[0]!=window_valid[1]||window_valid[1]!=window_valid[2])error_q[1]<=1;
    if(advance)begin
     for(j=STAGES-1;j>0;j=j-1)begin original[j]<=original[j-1];gate_pipe[j]<=gate_pipe[j-1];end
     original[0]<=center;gate_pipe[0]<=enabled&&interior&&(y_range<=threshold);
    end
    if(take_window)begin
     windows<=windows+1'b1;
     if(window_sof!={3{windows==0}}||window_eol!={3{wx==WIDTH-1}})error_q[1]<=1;
     if(wx==WIDTH-1)begin wx<=0;wy<=(wy==HEIGHT-1)?{YW{1'b0}}:wy+1'b1;end
     else wx<=wx+1'b1;
    end
    if(m_valid&&m_ready)begin
     outputs<=outputs+1'b1;ox<=(ox==WIDTH-1)?{XW{1'b0}}:ox+1'b1;
     applied_count<=applied_count+{{16{1'b0}},m_applied};
     changed_count<=changed_count+{{16{1'b0}},m_changed};
     if(net_sof!={2{outputs==0}}||net_eol!={2{ox==WIDTH-1}})error_q[1]<=1;
     if(m_last)begin
      active<=0;done_q<=1;
      d_error<=error_q|{((|window_error)||(net_sof!={2{outputs==0}})||(net_eol!={2{ox==WIDTH-1}})),1'b0};
      d_applied<=applied_count+{{16{1'b0}},m_applied};
      d_changed<=changed_count+{{16{1'b0}},m_changed};
     end
    end
   end
  end
 end
 initial if(WIDTH<1||WIDTH>512||HEIGHT<1||HEIGHT>512||N>65536||
  (BITS!=8&&BITS!=10)||TAG_W<1||TAG_W>32)$fatal(1,"chroma_median_suppress parameters");
endmodule
