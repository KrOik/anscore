// SPDX-License-Identifier: Apache-2.0
// Resident 2:4 S4 matrix, cached U8 vector, exact integer quantization.
module int4_sparse2of4_matvec #(
 parameter MAX_ROWS=8, MAX_COLS=64, TAG_W=16
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,
 input wire [1:0] c_op,input wire [15:0] c_row,c_group,
 input wire [2:0] c_pattern,input wire [7:0] c_weights,
 input wire signed [31:0] c_bias,input wire [15:0] c_scale,
 input wire [4:0] c_shift,input wire signed [7:0] c_zero,
 output wire c_rsp_valid,input wire c_rsp_ready,output reg [1:0] c_error,
 input wire cmd_valid,output wire cmd_ready,
 input wire [15:0] cmd_rows,cmd_cols,input wire [7:0] cmd_x_zero,
 input wire [TAG_W-1:0] cmd_tag,
 input wire s_valid,output wire s_ready,input wire [7:0] s_data,input wire s_last,
 output wire m_valid,input wire m_ready,output wire signed [7:0] m_data,
 output wire [15:0] m_row,output wire [TAG_W-1:0] m_tag,
 output wire m_last,m_clip,m_inexact,output wire [1:0] m_error,
 output wire busy
);
 generate if(MAX_ROWS<1 || MAX_ROWS>64 || MAX_COLS<1 || MAX_COLS>1024 || TAG_W<1 || TAG_W>32)begin:bad_parameters
  INT4_SPARSE2OF4_MATVEC_UNSUPPORTED_PARAMETERS invalid();
 end endgenerate
 localparam GROUPS=(MAX_COLS+3)/4,SLOTS=MAX_ROWS*GROUPS;
 localparam IDLE=0,CFG_RSP=1,CHECK=2,LOAD=3,ROW=4,WRD=5,X0=6,
            P0=7,M0P1=8,M1=9,SCALE=10,SEND=11,DRAIN=12,ERROR_RSP=13;
 reg [3:0] state;
 // One synchronous read per array; payload memories are never reset.
 (* ram_style="block" *) reg [10:0] weight_mem[0:SLOTS-1];
 (* ram_style="block" *) reg [7:0] vector_mem[0:MAX_COLS-1];
 reg [10:0] weight_read;
 reg [15:0] configured_groups[0:MAX_ROWS-1];
 reg [MAX_ROWS-1:0] meta_valid;
 reg signed [31:0] bias_mem[0:MAX_ROWS-1];
 reg [15:0] scale_mem[0:MAX_ROWS-1];
 reg [4:0] shift_mem[0:MAX_ROWS-1];
 reg signed [7:0] zero_mem[0:MAX_ROWS-1];
 reg [15:0] rows,cols,groups,row_index,group_index,input_index;
 reg [7:0] x_zero,x_read;
 reg signed [3:0] active_weight;
 reg signed [12:0] product_reg;
 reg signed [39:0] accumulator;
 reg [15:0] scale;
 reg [4:0] shift;
 reg signed [7:0] zero;
 reg signed [56:0] scaled;
 reg [TAG_W-1:0] tag;
 reg [1:0] error_code;
 integer r;
 reg [1:0] position0,position1;
 always @* begin
  case(weight_read[10:8])
   0:begin position0=0;position1=1;end
   1:begin position0=0;position1=2;end
   2:begin position0=0;position1=3;end
   3:begin position0=1;position1=2;end
   4:begin position0=1;position1=3;end
   5:begin position0=2;position1=3;end
   default:begin position0=0;position1=1;end
  endcase
 end
 wire [15:0] column0=(group_index<<2)+{14'd0,position0};
 wire [15:0] column1=(group_index<<2)+{14'd0,position1};
 wire [15:0] vector_column=state==P0?column1:column0;
 wire signed [8:0] centered=$signed({1'b0,x_read})-$signed({1'b0,x_zero});
 wire signed [12:0] product=centered*active_weight;
 wire signed [39:0] product_wide={{27{product_reg[12]}},product_reg};
 wire signed [16:0] scale_positive=$signed({1'b0,scale});
 wire q_ready,q_valid,q_clip,q_inexact;
 wire [15:0] q_data;
 wire [TAG_W+24:0] q_tag;
 wire signed [7:0] output_zero=$signed(q_tag[7:0]);
 wire signed [16:0] output_sum=$signed({q_data[15],q_data})+
                              $signed({{9{output_zero[7]}},output_zero});
 assign c_ready=!rst && state==IDLE;
 assign cmd_ready=!rst && state==IDLE && !c_valid;
 assign c_rsp_valid=!rst && state==CFG_RSP;
 assign s_ready=!rst && state==LOAD;
 assign busy=state!=IDLE;
 assign m_valid=!rst && (state==ERROR_RSP || q_valid);
 assign m_data=state==ERROR_RSP?8'sd0:output_sum>127?8'sd127:
               output_sum< -128?-8'sd128:output_sum[7:0];
 assign m_row=state==ERROR_RSP?16'd0:q_tag[24:9];
 assign m_tag=state==ERROR_RSP?tag:q_tag[TAG_W+24:25];
 assign m_last=state==ERROR_RSP?1'b1:q_tag[8];
 assign m_clip=state==ERROR_RSP?1'b0:(q_clip || output_sum>127 || output_sum< -128);
 assign m_inexact=state==ERROR_RSP?1'b0:q_inexact;
 assign m_error=state==ERROR_RSP?error_code:2'd0;
 stream_requantize #(.IN_W(64),.OUT_W(16),.TAG_W(TAG_W+25)) requant(
  .clk(clk),.rst(rst),.s_valid(state==SEND),.s_ready(q_ready),
  .s_data({{7{scaled[56]}},scaled}),.s_shift({2'b0,shift}),
  .s_tag({tag,row_index,(row_index==rows-1'b1),zero}),
  .m_valid(q_valid),.m_ready(m_ready && state!=ERROR_RSP),
  .m_data(q_data),.m_clip(q_clip),.m_inexact(q_inexact),.m_tag(q_tag));
 // One explicit synchronous vector read site, shared by both selected positions.
 always @(posedge clk)begin
  if(rst)x_read<=0;
  else if(state==X0 || state==P0)begin
   if(vector_column<cols)x_read<=vector_mem[vector_column];else x_read<=x_zero;
  end
 end
 always @(posedge clk) begin
  if(rst)begin
   state<=IDLE;meta_valid<=0;
   for(r=0;r<MAX_ROWS;r=r+1)configured_groups[r]<=0;
   c_error<=0;rows<=0;cols<=0;groups<=0;row_index<=0;group_index<=0;input_index<=0;
   x_zero<=0;weight_read<=0;active_weight<=0;product_reg<=0;
   accumulator<=0;scale<=0;shift<=0;zero<=0;scaled<=0;tag<=0;error_code<=0;
  end else case(state)
   IDLE:begin
    if(c_valid)begin
     c_error<=0;state<=CFG_RSP;
     case(c_op)
      0:if(c_row>=MAX_ROWS || c_group>=GROUPS)c_error<=1;
        else if(c_pattern>=6)c_error<=2;
        else if(c_group>configured_groups[c_row])c_error<=3;
        else begin
         weight_mem[c_row*GROUPS+c_group]<={c_pattern,c_weights};
         if(c_group==0)configured_groups[c_row]<=1;
         else if(c_group==configured_groups[c_row])configured_groups[c_row]<=c_group+1'b1;
        end
      1:if(c_row>=MAX_ROWS)c_error<=1;
        else begin
         bias_mem[c_row]<=c_bias;scale_mem[c_row]<=c_scale;
         shift_mem[c_row]<=c_shift;zero_mem[c_row]<=c_zero;meta_valid[c_row]<=1;
        end
      2:begin
         meta_valid<=0;
         for(r=0;r<MAX_ROWS;r=r+1)configured_groups[r]<=0;
        end
      default:c_error<=2;
     endcase
    end else if(cmd_valid)begin
     rows<=cmd_rows;cols<=cmd_cols;groups<=((cmd_cols-1'b1)>>2)+1'b1;
     x_zero<=cmd_x_zero;tag<=cmd_tag;row_index<=0;input_index<=0;group_index<=0;
     if(cmd_rows==0 || cmd_rows>MAX_ROWS || cmd_cols==0 || cmd_cols>MAX_COLS)begin
      error_code<=1;state<=ERROR_RSP;
     end else state<=CHECK;
    end
   end
   CFG_RSP:if(c_rsp_ready)state<=IDLE;
   CHECK:begin
    if(!meta_valid[row_index] || configured_groups[row_index]<groups)begin
     error_code<=2;state<=ERROR_RSP;
    end else if(row_index==rows-1'b1)begin row_index<=0;state<=LOAD;end
    else row_index<=row_index+1'b1;
   end
   LOAD:if(s_valid)begin
    vector_mem[input_index]<=s_data;
    if(s_last!=(input_index==cols-1'b1))begin error_code<=3;state<=ERROR_RSP;end
    else if(input_index==cols-1'b1)begin input_index<=0;state<=ROW;end
    else input_index<=input_index+1'b1;
   end
   ROW:begin
    accumulator<={{8{bias_mem[row_index][31]}},bias_mem[row_index]};
    scale<=scale_mem[row_index];shift<=shift_mem[row_index];zero<=zero_mem[row_index];
    group_index<=0;state<=WRD;
   end
   WRD:begin weight_read<=weight_mem[row_index*GROUPS+group_index];state<=X0;end
   X0:begin
    active_weight<=$signed(weight_read[3:0]);state<=P0;
   end
   P0:begin
    product_reg<=product;
    active_weight<=$signed(weight_read[7:4]);state<=M0P1;
   end
   M0P1:begin accumulator<=accumulator+product_wide;product_reg<=product;state<=M1;end
   M1:begin
    accumulator<=accumulator+product_wide;
    if(group_index==groups-1'b1)state<=SCALE;
    else begin group_index<=group_index+1'b1;state<=WRD;end
   end
   SCALE:begin scaled<=accumulator*scale_positive;state<=SEND;end
   SEND:if(q_ready)begin
    if(row_index==rows-1'b1)state<=DRAIN;
    else begin row_index<=row_index+1'b1;state<=ROW;end
   end
   DRAIN:if(q_valid && m_ready && q_tag[8])state<=IDLE;
   ERROR_RSP:if(m_ready)state<=IDLE;
   default:state<=IDLE;
  endcase
 end
endmodule
