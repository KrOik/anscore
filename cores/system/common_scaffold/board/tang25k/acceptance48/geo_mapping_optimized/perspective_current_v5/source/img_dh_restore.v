// Exact signed truncation toward zero with a shared bounded serial divider.
module img_dh_restore (
 input wire clk,rst_n,clk_en,input wire [23:0] s_rgb,s_airlight_rgb,
 input wire [15:0] s_t,s_t0,input wire s_valid,s_sof,s_eol,
 output wire s_ready,output reg [23:0] m_data,
 output reg m_valid,m_sof,m_eol,input wire m_ready,
 output wire unsupported,output reg error
);
localparam IDLE=0,CHANNEL=1,DIVIDE=2,RESULT=3;
reg [1:0] state,channel;
reg [23:0] rgb,airlight,result_rgb;
reg [15:0] denominator;
reg [22:0] quotient;
reg [16:0] remainder;
reg [4:0] bit_index;
reg negative;
wire [7:0] pixel=rgb[channel*8+:8],air=airlight[channel*8+:8];
wire [7:0] magnitude=pixel<air?air-pixel:pixel-air;
wire [16:0] shifted={remainder[15:0],quotient[22]};
wire subtract=shifted>={1'b0,denominator};
wire [16:0] next_remainder=subtract?shifted-{1'b0,denominator}:shifted;
wire signed [24:0] recovered=negative ? $signed({17'd0,air})-$signed({2'd0,quotient}) :
                                                       $signed({17'd0,air})+$signed({2'd0,quotient});
wire [7:0] clipped=recovered<0?8'd0:recovered>255?8'd255:recovered[7:0];
wire [23:0] completed=(result_rgb & ~(24'hff<<(channel*8))) | ({16'd0,clipped}<<(channel*8));
assign unsupported=s_t>32768 || s_t0==0 || s_t0>32768;
assign s_ready=clk_en && state==IDLE && (!m_valid || m_ready) && !unsupported;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=IDLE;channel<=0;rgb<=0;airlight<=0;result_rgb<=0;
  denominator<=1;quotient<=0;remainder<=0;bit_index<=0;negative<=0;
  m_data<=0;m_valid<=0;m_sof<=0;m_eol<=0;error<=0;
 end else if(clk_en)begin
  if(s_valid && unsupported)error<=1;
  if(m_valid && m_ready)m_valid<=0;
  case(state)
   IDLE:if(s_valid && s_ready)begin
    rgb<=s_rgb;airlight<=s_airlight_rgb;denominator<=s_t<s_t0?s_t0:s_t;
    channel<=0;result_rgb<=0;m_sof<=s_sof;m_eol<=s_eol;state<=CHANNEL;
   end
   CHANNEL:begin
    negative<=pixel<air;quotient<={magnitude,15'd0};remainder<=0;bit_index<=22;state<=DIVIDE;
   end
   DIVIDE:begin
    quotient<={quotient[21:0],subtract};remainder<=next_remainder;
    if(bit_index==0)state<=RESULT;else bit_index<=bit_index-1'b1;
   end
   RESULT:begin
    result_rgb<=completed;
    if(channel==2)begin m_data<=completed;m_valid<=1;state<=IDLE;end
    else begin channel<=channel+1'b1;state<=CHANNEL;end
   end
   default:state<=IDLE;
  endcase
 end
end
endmodule
