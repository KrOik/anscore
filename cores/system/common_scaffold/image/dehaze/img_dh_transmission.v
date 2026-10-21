// Exact Q1.15 transmission; bounded restoring divider, no combinational divide.
module img_dh_transmission (
 input wire clk,rst_n,clk_en,
 input wire [7:0] s_dark,s_airlight_gray,
 input wire [23:0] s_rgb,s_airlight_rgb,
 input wire [15:0] s_omega,s_t0,
 input wire s_valid,s_sof,s_eol,output wire s_ready,
 output reg [15:0] m_t,m_t0,
 output reg [23:0] m_rgb,m_airlight_rgb,
 output reg m_valid,m_sof,m_eol,input wire m_ready,
 output wire unsupported,output reg error
);
localparam IDLE=0,NUMERATOR=1,DIVIDE=2;
reg [1:0] state;
reg [23:0] product,quotient;
reg [7:0] denominator;
reg [8:0] remainder;
reg [4:0] bit_index;
wire [8:0] shifted={remainder[7:0],quotient[23]};
wire subtract=shifted>={1'b0,denominator};
wire [8:0] next_remainder=subtract?shifted-{1'b0,denominator}:shifted;
wire [23:0] next_quotient={quotient[22:0],subtract};
assign unsupported=s_airlight_gray==0 || s_omega>32768 || s_t0==0 || s_t0>32768;
assign s_ready=clk_en && state==IDLE && (!m_valid || m_ready) && !unsupported;
always @(posedge clk or negedge rst_n)begin
 if(!rst_n)begin
  state<=IDLE;product<=0;quotient<=0;denominator<=1;remainder<=0;bit_index<=0;
  m_t<=0;m_t0<=1;m_rgb<=0;m_airlight_rgb<=0;m_valid<=0;m_sof<=0;m_eol<=0;error<=0;
 end else if(clk_en)begin
  if(s_valid && unsupported)error<=1;
  if(m_valid && m_ready)m_valid<=0;
  case(state)
   IDLE:if(s_valid && s_ready)begin
    product<=s_omega*s_dark;denominator<=s_airlight_gray;
    m_t0<=s_t0;m_rgb<=s_rgb;m_airlight_rgb<=s_airlight_rgb;m_sof<=s_sof;m_eol<=s_eol;
    state<=NUMERATOR;
   end
   NUMERATOR:begin
    quotient<=product+(denominator>>1);remainder<=0;bit_index<=23;state<=DIVIDE;
   end
   DIVIDE:begin
    quotient<=next_quotient;remainder<=next_remainder;
    if(bit_index==0)begin
     m_t<=next_quotient>=32768?16'd0:16'd32768-next_quotient;
     m_valid<=1;state<=IDLE;
    end else bit_index<=bit_index-1'b1;
   end
   default:state<=IDLE;
  endcase
 end
end
endmodule
