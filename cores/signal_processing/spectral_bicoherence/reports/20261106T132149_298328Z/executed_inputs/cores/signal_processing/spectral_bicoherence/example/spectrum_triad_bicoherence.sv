// SPDX-License-Identifier: Apache-2.0
// An actual whole-spectrum frame selector feeding the serialized measurement.
// Input bins must be in natural order 0..BINS-1 and share a common scale.
module spectrum_triad_bicoherence #(
 parameter integer DATA_W=12,MAX_AVERAGES=64,TAG_W=8,
 parameter integer BINS=64,BIN1=3,BIN2=7,
 parameter integer LG=(MAX_AVERAGES<2?0:$clog2(MAX_AVERAGES)),
 parameter integer B_W=3*DATA_W+2+LG,U_W=4*DATA_W+3+LG,V_W=2*DATA_W+1+LG
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,input wire [31:0] c_averages,
 input wire [TAG_W-1:0] c_tag,
 input wire s_valid,output wire s_ready,input wire [2*DATA_W-1:0] s_data,input wire s_last,
 output wire m_valid,input wire m_ready,output wire [2:0] m_status,
 output wire [16:0] m_bicoherence_q16,output wire signed [B_W-1:0] m_b_re,m_b_im,
 output wire [U_W-1:0] m_u,output wire [V_W-1:0] m_v,
 output wire [TAG_W-1:0] m_tag,output wire m_last
);
 localparam integer BIN3=BIN1+BIN2,IW=(BINS<2?1:$clog2(BINS));
 localparam integer CW=(MAX_AVERAGES<2?1:$clog2(MAX_AVERAGES+1));
 localparam [2:0] IDLE=0,COLLECT=1,SEND=2,DRAIN=3,FLUSH=4,ERROR_OUT=5;
 reg [2:0] state;
 reg [IW-1:0] index;
 reg [CW-1:0] frame,averages;
 reg [2*DATA_W-1:0] x,y,z;
 reg [TAG_W-1:0] tag;
 wire core_c_ready,core_s_ready,core_m_valid;
 wire [2:0] core_status;
 wire [16:0] core_q;
 wire signed [B_W-1:0] core_br,core_bi;
 wire [U_W-1:0] core_u;
 wire [V_W-1:0] core_v;
 wire [TAG_W-1:0] core_tag;
 wire core_last;
 wire core_rst=rst || state==FLUSH;
 spectral_bicoherence #(.DATA_W(DATA_W),.MAX_AVERAGES(MAX_AVERAGES),.TAG_W(TAG_W)) measure(
  .clk(clk),.rst(core_rst),.c_valid(!rst && state==IDLE && c_valid),.c_ready(core_c_ready),
  .c_averages(c_averages),.c_tag(c_tag),
  .s_valid(!rst && state==SEND),.s_ready(core_s_ready),.s_data({z,y,x}),.s_last(frame==averages-1'b1),
  .m_valid(core_m_valid),.m_ready(state==DRAIN && m_ready),.m_status(core_status),
  .m_bicoherence_q16(core_q),.m_b_re(core_br),.m_b_im(core_bi),.m_u(core_u),.m_v(core_v),
  .m_tag(core_tag),.m_last(core_last));
 assign c_ready=!rst && state==IDLE && core_c_ready;
 assign s_ready=!rst && state==COLLECT;
 assign m_valid=!rst && ((state==DRAIN && core_m_valid) || state==ERROR_OUT);
 assign m_status=state==ERROR_OUT?3'd5:core_status;
 assign m_bicoherence_q16=state==ERROR_OUT?17'd0:core_q;
 assign m_b_re=state==ERROR_OUT?{B_W{1'b0}}:core_br;
 assign m_b_im=state==ERROR_OUT?{B_W{1'b0}}:core_bi;
 assign m_u=state==ERROR_OUT?{U_W{1'b0}}:core_u;
 assign m_v=state==ERROR_OUT?{V_W{1'b0}}:core_v;
 assign m_tag=state==ERROR_OUT?tag:core_tag;
 assign m_last=m_valid;
 always @(posedge clk)begin
  if(rst)begin state<=IDLE;index<=0;frame<=0;averages<=0;tag<=0;end
  else case(state)
   IDLE:if(c_valid && core_c_ready)begin
    tag<=c_tag;index<=0;frame<=0;averages<=c_averages[CW-1:0];
    if(c_averages==0 || c_averages>MAX_AVERAGES)state<=DRAIN;
    else state<=COLLECT;
   end
   COLLECT:if(s_valid)begin
    if(s_last!=(index==BINS-1))state<=FLUSH;
    else begin
     if(index==BIN1)x<=s_data;
     if(index==BIN2)y<=s_data;
     if(index==BIN3)z<=s_data;
     if(index==BINS-1)begin index<=0;state<=SEND;end
     else index<=index+1'b1;
    end
   end
   SEND:if(core_s_ready)begin
    if(frame==averages-1'b1)state<=DRAIN;
    else begin frame<=frame+1'b1;state<=COLLECT;end
   end
   DRAIN:if(core_m_valid && m_ready)state<=IDLE;
   FLUSH:state<=ERROR_OUT;
   ERROR_OUT:if(m_ready)state<=IDLE;
   default:state<=FLUSH;
  endcase
 end
`ifndef SYNTHESIS
 initial begin
  if(BINS<1 || BINS>256 || BIN1<0 || BIN2<0 || BIN1>=BINS || BIN2>=BINS || BIN3>=BINS ||
   DATA_W<2 || DATA_W>16 || MAX_AVERAGES<1 || MAX_AVERAGES>256 || TAG_W<1 || TAG_W>32 ||
   LG!=(MAX_AVERAGES<2?0:$clog2(MAX_AVERAGES)) || B_W!=3*DATA_W+2+LG ||
   U_W!=4*DATA_W+3+LG || V_W!=2*DATA_W+1+LG)
   $fatal(1,"spectrum_triad_bicoherence: unsupported static configuration");
 end
`endif
endmodule
