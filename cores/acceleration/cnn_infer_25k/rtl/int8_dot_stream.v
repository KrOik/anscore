// Signed INT8 dot product: raw products, signed32 bias/result, no per-term shift.
// One accepted product per clock. Invalid length/framing/overflow returns error.
module int8_dot_stream #(parameter MAX_TERMS=392)(
 input wire clk,rst_n,
 input wire cmd_valid,output wire cmd_ready,input wire [15:0] cmd_terms,
 input wire signed [31:0] cmd_bias,
 input wire s_valid,output wire s_ready,input wire signed [7:0] s_x,s_w,input wire s_last,
 output wire m_valid,input wire m_ready,output wire signed [31:0] m_result,
 output wire [1:0] m_error
);
 localparam IDLE=0,RUN=1,DRAIN=2,RESPONSE=3;
 reg [1:0] state;
 reg [15:0] terms,count;
 reg signed [31:0] accumulator,result;
 reg signed [15:0] product;
 reg product_valid;
 reg [1:0] error;
 wire signed [32:0] total={accumulator[31],accumulator}+{{17{product[15]}},product};
 wire overflow=total[32]!=total[31];
 assign cmd_ready=rst_n&&state==IDLE;
 assign s_ready=rst_n&&state==RUN;
 assign m_valid=rst_n&&state==RESPONSE;
 assign m_result=result;assign m_error=error;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;terms<=0;count<=0;accumulator<=0;result<=0;
   product<=0;product_valid<=0;error<=0;end
  else case(state)
   IDLE:if(cmd_valid)begin
    terms<=cmd_terms;count<=0;accumulator<=cmd_bias;product_valid<=0;error<=0;
    if(cmd_terms==0||cmd_terms>MAX_TERMS)begin result<=0;error<=1;state<=RESPONSE;end
    else state<=RUN;
   end
   RUN:begin
    product_valid<=s_valid;
    if(product_valid)accumulator<=total[31:0];
    if(s_valid)begin
     product<=s_x*s_w;count<=count+1'b1;
     if(count==terms-1)state<=DRAIN;
    end
    if((product_valid&&overflow)||(s_valid&&(s_last!=(count==terms-1))))begin
     result<=0;error<=product_valid&&overflow?3:2;state<=RESPONSE;product_valid<=0;
    end
   end
   DRAIN:begin
    result<=overflow?32'sd0:total[31:0];error<=overflow?3:0;
    product_valid<=0;state<=RESPONSE;
   end
   RESPONSE:if(m_ready)state<=IDLE;
   default:state<=IDLE;
  endcase
 end
endmodule
