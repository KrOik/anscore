// Shared fixed-point rounding/saturation: y = sat_OUT_W(RNE(v / 2**SHIFT)).
// Stream contract: II=1, latency 1 cycle, single clk, synchronous rst_n.
// m_tuser[0]=clip (output saturated), m_tuser[1]=inexact (bits discarded).
module sat_round #(
 parameter integer IN_W=32,parameter integer OUT_W=16,
 parameter integer SHIFT=15,parameter integer SIGNED_IN=1
)(
 input wire clk,rst_n,
 input wire [IN_W-1:0] s_tdata,input wire s_tvalid,output wire s_tready,
 output reg [OUT_W-1:0] m_tdata,output reg [1:0] m_tuser,
 output reg m_tvalid,input wire m_tready
);
 wire signed [IN_W:0] vin=SIGNED_IN!=0 ?
   $signed({s_tdata[IN_W-1],s_tdata}) : $signed({1'b0,s_tdata});
 wire signed [IN_W:0] q0=vin>>>SHIFT;
 wire signed [IN_W:0] rounded;
 wire inexact;
 generate if(SHIFT>0) begin:g_rne
  localparam [SHIFT-1:0] HALF={{(SHIFT-1){1'b0}},1'b1}<<(SHIFT-1);
  wire [SHIFT-1:0] frac=vin[SHIFT-1:0];
  assign rounded=q0+{{IN_W{1'b0}},((frac>HALF)||(frac==HALF&&q0[0]))};
  assign inexact=|frac;
 end else begin:g_nornd
  assign rounded=q0;
  assign inexact=1'b0;
 end endgenerate
 localparam signed [IN_W:0] OMAX={{(IN_W-OUT_W+2){1'b0}},{(OUT_W-1){1'b1}}};
 localparam signed [IN_W:0] OMIN={{(IN_W-OUT_W+2){1'b1}},{(OUT_W-1){1'b0}}};
 wire clip=rounded>OMAX || rounded<OMIN;
 wire signed [OUT_W-1:0] clipped=rounded>OMAX ? OMAX[OUT_W-1:0] :
   rounded<OMIN ? OMIN[OUT_W-1:0] : rounded[OUT_W-1:0];
 assign s_tready=rst_n && (!m_tvalid || m_tready);
 always @(posedge clk) begin
  if(!rst_n) m_tvalid<=1'b0;
  else if(s_tready) begin
   m_tvalid<=s_tvalid;
   if(s_tvalid) begin m_tdata<=clipped;m_tuser<={inexact,clip}; end
  end
 end
`ifndef SYNTHESIS
 initial begin
  if(IN_W<2 || OUT_W<2 || OUT_W>IN_W+1 || SHIFT<0 || SHIFT>IN_W)
   $fatal(1,"sat_round: unsupported static configuration");
 end
`endif
endmodule
