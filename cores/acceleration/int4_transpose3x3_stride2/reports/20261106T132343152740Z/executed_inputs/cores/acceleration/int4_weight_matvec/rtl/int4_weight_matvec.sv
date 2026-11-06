// SPDX-License-Identifier: Apache-2.0
// Resident packed signed-INT4 matrix x cached asymmetric U8 vector.
module int4_weight_matvec #(
 parameter MAX_ROWS=8, MAX_COLS=64, TAG_W=16
)(
 input wire clk,rst,
 input wire c_valid, output wire c_ready,
 input wire [1:0] c_op, input wire [15:0] c_row,c_word,
 input wire [31:0] c_weights, input wire signed [31:0] c_bias,
 input wire [15:0] c_scale, input wire [4:0] c_shift,
 input wire signed [7:0] c_zero,
 output wire c_rsp_valid, input wire c_rsp_ready, output reg [1:0] c_error,
 input wire cmd_valid, output wire cmd_ready,
 input wire [15:0] cmd_rows,cmd_cols, input wire [7:0] cmd_x_zero,
 input wire [TAG_W-1:0] cmd_tag,
 input wire s_valid, output wire s_ready, input wire [7:0] s_data,input wire s_last,
 output wire m_valid,input wire m_ready, output wire signed [7:0] m_data,
 output wire [15:0] m_row, output wire [TAG_W-1:0] m_tag,
 output wire m_last,m_clip,m_inexact, output wire [1:0] m_error,
 output wire busy
);
 localparam WORDS=(MAX_COLS+7)/8, SLOTS=MAX_ROWS*WORDS;
 localparam IDLE=0,CFG_RSP=1,CHECK=2,LOAD=3,ROW=4,RD=5,MAC=6,
            SCALE=7,SEND=9,DRAIN=10,ERROR_RSP=11;
 reg [3:0] state;
 reg [SLOTS-1:0] weight_valid;
 reg [MAX_ROWS-1:0] row_valid;
 reg [31:0] weight_mem [0:SLOTS-1];
 reg [7:0] vector_mem [0:MAX_COLS-1];
 reg signed [31:0] bias_mem [0:MAX_ROWS-1];
 reg [15:0] scale_mem [0:MAX_ROWS-1];
 reg [4:0] shift_mem [0:MAX_ROWS-1];
 reg signed [7:0] zero_mem [0:MAX_ROWS-1];
 reg [15:0] rows,cols,row_index,col_index,check_word;
 reg [7:0] x_zero,x_read;
 reg [31:0] weight_read;
 reg [TAG_W-1:0] tag;
 reg [1:0] error_code;
 reg signed [39:0] accumulator;
 reg [15:0] scale;
 reg [4:0] shift;
 reg signed [7:0] zero;
 reg signed [56:0] scaled;
 wire signed [8:0] centered=$signed({1'b0,x_read})-$signed({1'b0,x_zero});
 wire signed [3:0] weight=$signed(weight_read[(col_index[2:0]*4)+:4]);
 wire signed [12:0] product=centered*weight;
 wire signed [39:0] product_wide={{27{product[12]}},product};
 wire signed [16:0] scale_positive=$signed({1'b0,scale});
 wire q_ready,q_valid,q_clip,q_inexact;
 wire [15:0] q_data;
 wire [TAG_W+24:0] q_tag;
 wire signed [7:0] output_zero=$signed(q_tag[7:0]);
 wire signed [16:0] output_sum=$signed({q_data[15],q_data})+
                             $signed({{9{output_zero[7]}},output_zero});
 wire output_clip=q_clip || output_sum>17'sd127 || output_sum< -17'sd128;
 assign c_ready=!rst && state==IDLE;
 // Configuration wins arbitration; an unaccepted command must stay offered.
 assign cmd_ready=!rst && state==IDLE && !c_valid;
 assign c_rsp_valid=!rst && state==CFG_RSP;
 assign s_ready=!rst && state==LOAD;
 assign busy=state!=IDLE;
 assign m_valid=!rst && ((state==ERROR_RSP) || q_valid);
 assign m_data=state==ERROR_RSP?8'sd0:output_sum>127?8'sd127:
               output_sum< -128?-8'sd128:output_sum[7:0];
 assign m_row=state==ERROR_RSP?16'd0:q_tag[24:9];
 assign m_tag=state==ERROR_RSP?tag:q_tag[TAG_W+24:25];
 assign m_last=state==ERROR_RSP?1'b1:q_tag[8];
 assign m_clip=state==ERROR_RSP?1'b0:output_clip;
 assign m_inexact=state==ERROR_RSP?1'b0:q_inexact;
 assign m_error=state==ERROR_RSP?error_code:2'd0;
 // Round BEFORE adding output zero: ties-to-even does not commute with
 // translation by odd integers. A signed16 intermediate can only clip when
 // every possible signed8 zero offset still leaves the final signed8 clipped.
 stream_requantize #(.IN_W(64),.OUT_W(16),.TAG_W(TAG_W+25)) requant(
  .clk(clk),.rst(rst),.s_valid(state==SEND),.s_ready(q_ready),
  .s_data({{7{scaled[56]}},scaled}),.s_shift({2'b0,shift}),
  .s_tag({tag,row_index,(row_index==rows-1'b1),zero}),
  .m_valid(q_valid),.m_ready(m_ready && state!=ERROR_RSP),
  .m_data(q_data),.m_clip(q_clip),.m_inexact(q_inexact),.m_tag(q_tag));
 always @(posedge clk) begin
  if(rst) begin
   state<=IDLE;weight_valid<=0;row_valid<=0;c_error<=0;
   rows<=0;cols<=0;row_index<=0;col_index<=0;check_word<=0;
   x_zero<=0;x_read<=0;weight_read<=0;tag<=0;error_code<=0;
   accumulator<=0;scale<=0;shift<=0;zero<=0;scaled<=0;
  end else case(state)
   IDLE: begin
    if(c_valid) begin
     c_error<=0;state<=CFG_RSP;
     case(c_op)
      0: if(c_row>=MAX_ROWS || c_word>=WORDS) c_error<=1;
         else begin weight_mem[c_row*WORDS+c_word]<=c_weights;weight_valid[c_row*WORDS+c_word]<=1;end
      1: if(c_row>=MAX_ROWS) c_error<=1;
         else begin bias_mem[c_row]<=c_bias;scale_mem[c_row]<=c_scale;
          shift_mem[c_row]<=c_shift;zero_mem[c_row]<=c_zero;row_valid[c_row]<=1;end
      2: begin weight_valid<=0;row_valid<=0;end
      default: c_error<=2;
     endcase
    end else if(cmd_valid) begin
     rows<=cmd_rows;cols<=cmd_cols;x_zero<=cmd_x_zero;tag<=cmd_tag;
     row_index<=0;col_index<=0;check_word<=0;
     if(cmd_rows==0 || cmd_rows>MAX_ROWS || cmd_cols==0 || cmd_cols>MAX_COLS) begin
      error_code<=1;state<=ERROR_RSP;
     end else state<=CHECK;
    end
   end
   CFG_RSP: if(c_rsp_ready) state<=IDLE;
   CHECK: begin
    if(!row_valid[row_index] || !weight_valid[row_index*WORDS+check_word]) begin
     error_code<=2;state<=ERROR_RSP;
    end else if(check_word==((cols-1'b1)>>3)) begin
     check_word<=0;
     if(row_index==rows-1'b1) begin row_index<=0;state<=LOAD;end
     else row_index<=row_index+1'b1;
    end else check_word<=check_word+1'b1;
   end
   LOAD: if(s_valid) begin
    vector_mem[col_index]<=s_data;
    if(s_last!=(col_index==cols-1'b1)) begin error_code<=3;state<=ERROR_RSP;end
    else if(col_index==cols-1'b1) begin col_index<=0;state<=ROW;end
    else col_index<=col_index+1'b1;
   end
   ROW: begin
    accumulator<={{8{bias_mem[row_index][31]}},bias_mem[row_index]};
    scale<=scale_mem[row_index];shift<=shift_mem[row_index];zero<=zero_mem[row_index];
    col_index<=0;state<=RD;
   end
   RD: begin
    x_read<=vector_mem[col_index];weight_read<=weight_mem[row_index*WORDS+(col_index>>3)];
    state<=MAC;
   end
   MAC: begin
    accumulator<=accumulator+product_wide;
    if(col_index==cols-1'b1) state<=SCALE;
    else begin col_index<=col_index+1'b1;state<=RD;end
   end
   SCALE: begin scaled<=accumulator*scale_positive;state<=SEND;end
   SEND: if(q_ready) begin
    if(row_index==rows-1'b1) state<=DRAIN;
    else begin row_index<=row_index+1'b1;state<=ROW;end
   end
   DRAIN: if(q_valid && m_ready && q_tag[8]) state<=IDLE;
   ERROR_RSP: if(m_ready) state<=IDLE;
   default: state<=IDLE;
  endcase
 end
endmodule
