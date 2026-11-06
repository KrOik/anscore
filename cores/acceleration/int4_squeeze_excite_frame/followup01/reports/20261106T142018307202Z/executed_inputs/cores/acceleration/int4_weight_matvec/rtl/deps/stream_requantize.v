// Signed y=sat_OUT_W(RNE(x/2^shift)), with runtime unsigned shift.
// Three elastic registers; input-to-round-to-clamp paths are internally timed.
module stream_requantize #(parameter IN_W=32,OUT_W=8,TAG_W=16)(
 input wire clk,rst,s_valid,output wire s_ready,
 input wire [IN_W-1:0] s_data,
 input wire [((IN_W<2)?1:$clog2(IN_W+1))-1:0] s_shift,
 input wire [TAG_W-1:0] s_tag,
 output wire m_valid,input wire m_ready,
 output reg [OUT_W-1:0] m_data,output reg m_clip,m_inexact,
 output reg [TAG_W-1:0] m_tag
);
 localparam SHIFT_W=(IN_W<2)?1:$clog2(IN_W+1);
 localparam CLAMP_W=(IN_W+1>OUT_W)?IN_W+1:OUT_W;
 reg v0,v1,v2;
 reg [IN_W-1:0] x0;reg [SHIFT_W-1:0] shift0;
 reg [TAG_W-1:0] tag0,tag1;
 reg signed [IN_W:0] rounded1;reg inexact1;
 wire r2=!v2 || m_ready;
 wire r1=!v1 || r2;
 wire r0=!v0 || r1;
 assign s_ready=!rst && r0;assign m_valid=!rst && v2;
 // Prefix reductions provide sticky bits without constructing a variable mask.
 wire [IN_W:0] prefix;
 assign prefix[0]=0;
 genvar bit_index;
 generate for(bit_index=0;bit_index<IN_W;bit_index=bit_index+1)begin: sticky
  assign prefix[bit_index+1]=prefix[bit_index]|x0[bit_index];
 end endgenerate
 wire signed [IN_W:0] floor_q=$signed({x0[IN_W-1],x0}) >>> shift0;
 reg signed [IN_W:0] rounded;
 reg inexact,increment;
 always @* begin
  rounded=$signed({x0[IN_W-1],x0});inexact=0;increment=0;
  if(shift0>=IN_W)begin
   // |x/2^shift|<=1/2; the signed minimum at shift=IN_W ties to even zero.
   rounded=0;inexact=|x0;
  end else if(shift0!=0)begin
   increment=x0[shift0-1'b1] && (prefix[shift0-1'b1] || floor_q[0]);
   rounded=floor_q+{{IN_W{1'b0}},increment};
   inexact=prefix[shift0];
  end
 end
 wire signed [CLAMP_W-1:0] wide={{(CLAMP_W-IN_W-1){rounded1[IN_W]}},rounded1};
 localparam signed [CLAMP_W-1:0] MAXIMUM={{(CLAMP_W-OUT_W+1){1'b0}},{(OUT_W-1){1'b1}}};
 localparam signed [CLAMP_W-1:0] MINIMUM={{(CLAMP_W-OUT_W+1){1'b1}},{(OUT_W-1){1'b0}}};
 always @(posedge clk)begin
  if(rst)begin v0<=0;v1<=0;v2<=0;end
  else begin
   if(r0)begin v0<=s_valid;if(s_valid)begin x0<=s_data;shift0<=s_shift;tag0<=s_tag;end end
   if(r1)begin v1<=v0;if(v0)begin rounded1<=rounded;inexact1<=inexact;tag1<=tag0;end end
   if(r2)begin
    v2<=v1;
    if(v1)begin
     m_data<=wide>MAXIMUM?MAXIMUM[OUT_W-1:0]:wide<MINIMUM?MINIMUM[OUT_W-1:0]:wide[OUT_W-1:0];
     m_clip<=wide>MAXIMUM || wide<MINIMUM;m_inexact<=inexact1;m_tag<=tag1;
    end
   end
  end
 end
endmodule
