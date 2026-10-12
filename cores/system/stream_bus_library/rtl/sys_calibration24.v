// Signed24 sample * signed16 Q2.14 gain + signed24 offset, saturating24.
// Serial shift-add:0DSP;16 iterations plus3 registered finishing stages.
module sys_calibration24(
 input wire clk,rst_n,input wire signed [23:0] s_data,s_offset,
 input wire signed [15:0] s_gain,input wire [1:0] s_channel,input wire [31:0] s_tag,
 input wire s_valid,output wire s_ready,
 output reg signed [23:0] m_data,output reg [1:0] m_channel,output reg [31:0] m_tag,
 output reg m_saturated,m_valid,input wire m_ready
);
reg busy,negative;
reg [1:0] finish;
reg [3:0] iteration;
reg [39:0] acc,multiplicand;
reg [15:0] multiplier;
reg signed [23:0] offset;
reg [1:0] channel;
reg [31:0] tag;
wire [39:0] sum=acc+(multiplier[0]?multiplicand:40'd0);
reg signed [39:0] product;
wire signed [39:0] shifted=product>>>14;
wire signed [39:0] extended_offset={{16{offset[23]}},offset};
reg signed [39:0] calibrated;
assign s_ready=rst_n&&!busy&&(!m_valid||m_ready);
always @(posedge clk or negedge rst_n) begin
 if(!rst_n) begin
  busy<=0; negative<=0; finish<=0; product<=0; calibrated<=0; iteration<=0; acc<=0; multiplicand<=0; multiplier<=0; offset<=0;
  channel<=0; tag<=0; m_data<=0; m_channel<=0; m_tag<=0; m_saturated<=0; m_valid<=0;
 end else begin
  if(m_valid&&m_ready) m_valid<=0;
  if(s_valid&&s_ready) begin
   busy<=1; finish<=0; negative<=s_data[23]^s_gain[15]; iteration<=0; acc<=0;
   multiplicand<={16'd0,(s_data[23]?(~s_data+24'd1):s_data)};
   multiplier<=s_gain[15]?(~s_gain+16'd1):s_gain;
   offset<=s_offset; channel<=s_channel; tag<=s_tag;
  end
  if(busy&&finish==0) begin
   acc<=sum; multiplicand<=multiplicand<<1; multiplier<=multiplier>>1;
   iteration<=iteration+1'b1;
   if(iteration==15) finish<=1;
  end
  if(busy&&finish==1) begin product<=negative?-$signed(acc):$signed(acc); finish<=2; end
  if(busy&&finish==2) begin calibrated<=shifted+extended_offset; finish<=3; end
  if(busy&&finish==3) begin
    busy<=0; m_valid<=1; m_channel<=channel; m_tag<=tag;
    if(calibrated>40'sd8388607) begin m_data<=24'h7fffff; m_saturated<=1; end
    else if(calibrated< -40'sd8388608) begin m_data<=24'h800000; m_saturated<=1; end
    else begin m_data<=calibrated[23:0]; m_saturated<=0; end
  end
 end
end
endmodule
