// SPDX-License-Identifier: Apache-2.0
// Persistent paired INT4 projections, ReLU gate, and final signed8 quantization.
module int4_reglu #(
 parameter MAX_HIDDEN=8, MAX_COLS=64, TAG_W=8
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,
 input wire [2:0] c_op,input wire c_branch,
 input wire [15:0] c_row,c_word,input wire [31:0] c_weights,
 input wire signed [31:0] c_bias,input wire [15:0] c_scale,
 input wire [4:0] c_shift,input wire signed [7:0] c_zero,
 output wire c_rsp_valid,input wire c_rsp_ready,output wire [1:0] c_error,
 input wire cmd_valid,output wire cmd_ready,
 input wire [15:0] cmd_hidden,cmd_cols,input wire [7:0] cmd_x_zero,
 input wire [TAG_W-1:0] cmd_tag,
 input wire s_valid,output wire s_ready,input wire [7:0] s_data,input wire s_last,
 output wire m_valid,input wire m_ready,output wire signed [7:0] m_data,
 output wire [15:0] m_index,output wire [TAG_W-1:0] m_tag,
 output wire m_last,m_clip,m_inexact,m_project_clip,m_project_inexact,m_gate_closed,
 output wire [2:0] m_error,output wire busy
);
 generate if(MAX_HIDDEN<1 || MAX_HIDDEN>32 || MAX_COLS<1 || MAX_COLS>256 || TAG_W<1 || TAG_W>32)begin:bad_parameters
  INT4_REGLU_UNSUPPORTED_PARAMETERS invalid();
 end endgenerate
 localparam IDLE=0,CFG_CHILD=1,CFG_LOCAL=2,PRECHECK=3,START=4,RUN=5,
            PRODUCT=6,SCALE=7,SEND=8,WAIT_OUT=9,ERROR_RSP=10;
 reg [3:0] state;
 reg [MAX_HIDDEN-1:0] output_valid;
 reg [15:0] output_scale [0:MAX_HIDDEN-1];
 reg [4:0] output_shift [0:MAX_HIDDEN-1];
 reg signed [7:0] output_zero [0:MAX_HIDDEN-1];
 reg [1:0] local_error;
 reg [2:0] error_code;
 reg [15:0] hidden,cols,check_index,index;
 reg [7:0] x_zero;
 reg [TAG_W-1:0] tag;
 reg signed [7:0] gate,value,zero;
 reg [15:0] scale;
 reg [4:0] shift;
 reg last,project_clip,project_inexact,gate_clip,gate_inexact,gate_closed;
 reg signed [15:0] product;
 reg signed [32:0] scaled;
 wire signed [7:0] positive_gate=gate[7]?8'sd0:gate;
 wire signed [16:0] positive_scale=$signed({1'b0,scale});
 wire row_ok=c_row<MAX_HIDDEN;
 wire child_cfg=(c_op<=2) && (c_op==2 || row_ok);
 wire child_c_ready,child_rsp_valid;
 wire [1:0] child_c_error;
 wire child_cmd_ready,child_s_ready,child_m_valid;
 wire signed [7:0] child_data;
 wire [15:0] child_row;
 wire [TAG_W-1:0] child_tag;
 wire child_last,child_clip,child_inexact;
 wire [1:0] child_error;
 wire [15:0] child_config_row={c_row[14:0],c_branch};
 wire q_ready,q_valid,q_clip,q_inexact;
 wire [15:0] q_data;
 wire q_unused;
 wire signed [16:0] output_sum=$signed({q_data[15],q_data})+$signed({{9{zero[7]}},zero});
 assign c_ready=!rst && state==IDLE && (!child_cfg || child_c_ready);
 assign c_rsp_valid=!rst && (state==CFG_LOCAL || (state==CFG_CHILD && child_rsp_valid));
 assign c_error=state==CFG_CHILD?child_c_error:local_error;
 assign cmd_ready=!rst && state==IDLE && !c_valid;
 assign s_ready=!rst && state==RUN && child_s_ready;
 assign m_valid=!rst && (state==ERROR_RSP || (state==WAIT_OUT && q_valid));
 assign m_data=state==ERROR_RSP?8'sd0:output_sum>127?8'sd127:output_sum< -128?-8'sd128:output_sum[7:0];
 assign m_index=state==ERROR_RSP?16'd0:index;
 assign m_tag=tag;
 assign m_last=state==ERROR_RSP?1'b1:last;
 assign m_clip=state==ERROR_RSP?1'b0:(q_clip || output_sum>127 || output_sum< -128);
 assign m_inexact=state==ERROR_RSP?1'b0:q_inexact;
 assign m_project_clip=state==ERROR_RSP?1'b0:project_clip;
 assign m_project_inexact=state==ERROR_RSP?1'b0:project_inexact;
 assign m_gate_closed=state==ERROR_RSP?1'b0:gate_closed;
 assign m_error=state==ERROR_RSP?error_code:3'd0;
 assign busy=state!=IDLE;
 int4_weight_matvec #(.MAX_ROWS(2*MAX_HIDDEN),.MAX_COLS(MAX_COLS),.TAG_W(TAG_W)) projections(
  .clk(clk),.rst(rst),.c_valid(!rst && state==IDLE && c_valid && child_cfg),.c_ready(child_c_ready),
  .c_op(c_op[1:0]),.c_row(child_config_row),.c_word(c_word),.c_weights(c_weights),
  .c_bias(c_bias),.c_scale(c_scale),.c_shift(c_shift),.c_zero(c_zero),
  .c_rsp_valid(child_rsp_valid),.c_rsp_ready(state==CFG_CHILD && c_rsp_ready),.c_error(child_c_error),
  .cmd_valid(state==START),.cmd_ready(child_cmd_ready),.cmd_rows({hidden[14:0],1'b0}),
  .cmd_cols(cols),.cmd_x_zero(x_zero),.cmd_tag(tag),
  .s_valid(state==RUN && s_valid),.s_ready(child_s_ready),.s_data(s_data),.s_last(s_last),
  .m_valid(child_m_valid),.m_ready(state==RUN),.m_data(child_data),.m_row(child_row),
  .m_tag(child_tag),.m_last(child_last),.m_clip(child_clip),.m_inexact(child_inexact),.m_error(child_error),.busy());
 stream_requantize #(.IN_W(64),.OUT_W(16),.TAG_W(1)) post_quant(
  .clk(clk),.rst(rst),.s_valid(state==SEND),.s_ready(q_ready),
  .s_data({{31{scaled[32]}},scaled}),.s_shift({2'b0,shift}),.s_tag(1'b0),
  .m_valid(q_valid),.m_ready(state==WAIT_OUT && m_ready),.m_data(q_data),.m_clip(q_clip),.m_inexact(q_inexact),.m_tag(q_unused));
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;output_valid<=0;local_error<=0;error_code<=0;hidden<=0;cols<=0;
   check_index<=0;index<=0;x_zero<=0;tag<=0;gate<=0;value<=0;zero<=0;scale<=0;shift<=0;
   last<=0;project_clip<=0;project_inexact<=0;gate_clip<=0;gate_inexact<=0;gate_closed<=0;product<=0;scaled<=0;
  end else case(state)
   IDLE: if(c_valid && c_ready)begin
    if(child_cfg)begin
     if(c_op==2)output_valid<=0;
     state<=CFG_CHILD;
    end else begin
     local_error<=0;state<=CFG_LOCAL;
     if(c_op>=4)local_error<=2;
     else if(!row_ok)local_error<=1;
     else begin output_scale[c_row]<=c_scale;output_shift[c_row]<=c_shift;output_zero[c_row]<=c_zero;output_valid[c_row]<=1;end
    end
   end else if(cmd_valid && cmd_ready)begin
    hidden<=cmd_hidden;cols<=cmd_cols;x_zero<=cmd_x_zero;tag<=cmd_tag;check_index<=0;
    if(cmd_hidden==0 || cmd_hidden>MAX_HIDDEN || cmd_cols==0 || cmd_cols>MAX_COLS)begin error_code<=1;state<=ERROR_RSP;end
    else state<=PRECHECK;
   end
   CFG_CHILD:if(child_rsp_valid && c_rsp_ready)state<=IDLE;
   CFG_LOCAL:if(c_rsp_ready)state<=IDLE;
   PRECHECK:if(!output_valid[check_index])begin error_code<=4;state<=ERROR_RSP;end
    else if(check_index==hidden-1'b1)state<=START;
    else check_index<=check_index+1'b1;
   START:if(child_cmd_ready)state<=RUN;
   RUN:if(child_m_valid)begin
    if(child_error!=0)begin error_code<={1'b0,child_error};state<=ERROR_RSP;end
    else if(!child_row[0])begin gate<=child_data;gate_clip<=child_clip;gate_inexact<=child_inexact;end
    else begin
     value<=child_data;index<=child_row>>1;last<=child_last;
     project_clip<=gate_clip || child_clip;project_inexact<=gate_inexact || child_inexact;
     gate_closed<=(gate<=0);scale<=output_scale[child_row>>1];shift<=output_shift[child_row>>1];zero<=output_zero[child_row>>1];
     state<=PRODUCT;
    end
   end
   PRODUCT:begin product<=positive_gate*value;state<=SCALE;end
   SCALE:begin scaled<=product*positive_scale;state<=SEND;end
   SEND:if(q_ready)state<=WAIT_OUT;
   WAIT_OUT:if(q_valid && m_ready)state<=last?IDLE:RUN;
   ERROR_RSP:if(m_ready)state<=IDLE;
   default:state<=IDLE;
  endcase
 end
endmodule
