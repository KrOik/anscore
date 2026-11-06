// SPDX-License-Identifier: Apache-2.0
// Frame-global signed8 channel recalibration, resident INT4 bottleneck.
`default_nettype none
module int4_squeeze_excite_frame #(
 parameter MAX_CHANNELS=16, MAX_HIDDEN=4, MAX_PIXELS=256, TAG_W=8
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,input wire c_bank,
 input wire [1:0] c_op,input wire [15:0] c_row,c_word,
 input wire [31:0] c_weights,input wire signed [31:0] c_bias,
 input wire [15:0] c_scale,input wire [4:0] c_shift,
 input wire signed [7:0] c_zero,
 output wire c_rsp_valid,input wire c_rsp_ready,output wire [1:0] c_error,
 input wire cmd_valid,output wire cmd_ready,
 input wire [15:0] cmd_pixels,cmd_channels,cmd_hidden,
 input wire [TAG_W-1:0] cmd_tag,
 input wire s_valid,output wire s_ready,input wire signed [7:0] s_data,
 input wire s_last,
 output wire m_valid,input wire m_ready,output reg signed [7:0] m_data,
 output wire [15:0] m_pixel,m_channel,output wire [8:0] m_gate,
 output wire m_last,output wire [TAG_W-1:0] m_tag,
 output reg m_inexact,
 output reg m_mean_inexact,m_projection_clip,m_projection_inexact,
 output reg m_gate_inexact,m_gate_clamped,
 output wire rsp_valid,input wire rsp_ready,output reg [2:0] rsp_error,
 output reg [1:0] rsp_stage,rsp_child_error,
 output reg [23:0] rsp_inputs,rsp_outputs,
 output wire [TAG_W-1:0] rsp_tag,output wire busy
);
 localparam W0=(MAX_CHANNELS+7)/8,W1=(MAX_HIDDEN+7)/8;
 localparam FRAME_WORDS=MAX_PIXELS*MAX_CHANNELS;
 localparam AW=FRAME_WORDS<2?1:$clog2(FRAME_WORDS);
 localparam IDLE=0,CFG=1,CHECK0=2,CHECK1=3,POOL_CMD=4,LOAD=5,
   POOL_OUT=6,D0_CMD=7,D0_READ=8,D0_FEED=9,D0_OUT=10,
   D1_CMD=11,D1_READ=12,D1_FEED=13,D1_OUT=14,GATE_SEND=15,
   GATE_WAIT=16,REPLAY_READ=17,REPLAY_MUL=18,REPLAY_ROUND=19,
   OUTPUT_WORD=20,DONE=21;
 reg [4:0] state;
 reg [MAX_HIDDEN*W0-1:0] weight_valid0;
 reg [MAX_CHANNELS*W1-1:0] weight_valid1;
 reg [MAX_HIDDEN-1:0] meta_valid0;
 reg [MAX_CHANNELS-1:0] meta_valid1;
 reg cfg_bank;
 reg [1:0] cfg_op;
 reg [15:0] cfg_row,cfg_word;
 reg [15:0] pixels,channels,hidden,pixel,channel,check_row,check_word,feed_index;
 reg [TAG_W-1:0] tag;
 reg [AW-1:0] frame_address;
 reg signed [7:0] frame_mem[0:FRAME_WORDS-1];
 reg signed [7:0] descriptor_mem[0:MAX_CHANNELS-1];
 reg [7:0] hidden_mem[0:MAX_HIDDEN-1];
 reg [8:0] gate_mem[0:MAX_CHANNELS-1];
 reg signed [7:0] frame_q,descriptor_q;
 reg [7:0] hidden_q;
 reg [8:0] gate_q;
 reg signed [17:0] replay_product;
 reg [9:0] gate_numerator;
 reg [15:0] gate_channel;
 reg gate_last;
 wire last_sample=pixel==pixels-1'b1 && channel==channels-1'b1;
 wire d0_cr,d1_cr,d0_cv,d1_cv;
 wire [1:0] d0_ce,d1_ce;
 wire d0_cmdready,d1_cmdready,d0_sr,d1_sr,d0_mv,d1_mv;
 wire signed [7:0] d0_data,d1_data;
 wire [15:0] d0_row,d1_row;
 wire d0_last,d1_last,d0_clip,d1_clip,d0_inexact,d1_inexact;
 wire [1:0] d0_error,d1_error;
 wire pool_cmdready,pool_sr,pool_mv,pool_last,pool_inexact,pool_rv;
 wire signed [7:0] pool_data;
 wire [15:0] pool_channel;
 wire [1:0] pool_error;
 wire div_ready,div_valid,div_zero;
 wire [9:0] div_quotient,div_remainder;
 wire [8:0] gate_rounded={1'b0,div_quotient[7:0]}+(div_remainder==10'd2);
 wire signed [9:0] shifted_logit=$signed({{2{d1_data[7]}},d1_data})+10'sd96;
 wire signed [9:0] positive_gate=$signed({1'b0,gate_q});
 wire signed [17:0] replay_multiply=frame_q*positive_gate;
 wire [17:0] replay_magnitude=replay_product[17]?
                                   (~replay_product+18'd1):replay_product;
 wire round_up=replay_magnitude[7:0]>8'd128 ||
              (replay_magnitude[7:0]==8'd128 && replay_magnitude[8]);
 wire [10:0] rounded_magnitude={1'b0,replay_magnitude[17:8]}+round_up;
 wire signed [11:0] signed_rounded=replay_product[17]?
              -$signed({1'b0,rounded_magnitude}):$signed({1'b0,rounded_magnitude});
 assign c_ready=!rst && state==IDLE && (c_bank?d1_cr:d0_cr);
 assign c_rsp_valid=!rst && state==CFG && (cfg_bank?d1_cv:d0_cv);
 assign c_error=cfg_bank?d1_ce:d0_ce;
 assign cmd_ready=!rst && state==IDLE && !c_valid;
 assign s_ready=!rst && state==LOAD && pool_sr;
 assign m_valid=!rst && state==OUTPUT_WORD;
 assign m_pixel=pixel;assign m_channel=channel;assign m_gate=gate_q;
 assign m_last=last_sample;assign m_tag=tag;assign rsp_tag=tag;
 assign rsp_valid=!rst && state==DONE;
 assign busy=state!=IDLE;
 generate if(MAX_CHANNELS<1 || MAX_CHANNELS>64 || MAX_HIDDEN<1 ||
   MAX_HIDDEN>32 || MAX_PIXELS<1 || MAX_PIXELS>4096 || TAG_W<1 || TAG_W>32)
 begin:bad_parameters
  INT4_SQUEEZE_EXCITE_FRAME_UNSUPPORTED_PARAMETERS invalid();
 end endgenerate

 int4_weight_matvec #(.MAX_ROWS(MAX_HIDDEN),.MAX_COLS(MAX_CHANNELS),.TAG_W(TAG_W)) reduce(
  .clk(clk),.rst(rst),.c_valid(c_valid && !c_bank && state==IDLE && !rst),.c_ready(d0_cr),
  .c_op(c_op),.c_row(c_row),.c_word(c_word),.c_weights(c_weights),.c_bias(c_bias),
  .c_scale(c_scale),.c_shift(c_shift),.c_zero(c_zero),
  .c_rsp_valid(d0_cv),.c_rsp_ready(state==CFG && !cfg_bank && c_rsp_ready),.c_error(d0_ce),
  .cmd_valid(state==D0_CMD && !rst),.cmd_ready(d0_cmdready),
  .cmd_rows(hidden),.cmd_cols(channels),.cmd_x_zero(8'd128),.cmd_tag(tag),
  .s_valid(state==D0_FEED && !rst),.s_ready(d0_sr),
  .s_data(descriptor_q^8'h80),.s_last(feed_index==channels-1'b1),
  .m_valid(d0_mv),.m_ready(state==D0_OUT),.m_data(d0_data),.m_row(d0_row),.m_tag(),
  .m_last(d0_last),.m_clip(d0_clip),.m_inexact(d0_inexact),.m_error(d0_error),.busy());
 int4_weight_matvec #(.MAX_ROWS(MAX_CHANNELS),.MAX_COLS(MAX_HIDDEN),.TAG_W(TAG_W)) expand(
  .clk(clk),.rst(rst),.c_valid(c_valid && c_bank && state==IDLE && !rst),.c_ready(d1_cr),
  .c_op(c_op),.c_row(c_row),.c_word(c_word),.c_weights(c_weights),.c_bias(c_bias),
  .c_scale(c_scale),.c_shift(c_shift),.c_zero(c_zero),
  .c_rsp_valid(d1_cv),.c_rsp_ready(state==CFG && cfg_bank && c_rsp_ready),.c_error(d1_ce),
  .cmd_valid(state==D1_CMD && !rst),.cmd_ready(d1_cmdready),
  .cmd_rows(channels),.cmd_cols(hidden),.cmd_x_zero(8'd0),.cmd_tag(tag),
  .s_valid(state==D1_FEED && !rst),.s_ready(d1_sr),
  .s_data(hidden_q),.s_last(feed_index==hidden-1'b1),
  .m_valid(d1_mv),.m_ready(state==D1_OUT),.m_data(d1_data),.m_row(d1_row),.m_tag(),
  .m_last(d1_last),.m_clip(d1_clip),.m_inexact(d1_inexact),.m_error(d1_error),.busy());
 signed8_global_average_pool #(.MAX_CHANNELS(MAX_CHANNELS),.MAX_PIXELS(MAX_PIXELS),.TAG_W(TAG_W)) squeeze(
  .clk(clk),.rst(rst),.cmd_valid(state==POOL_CMD && !rst),.cmd_ready(pool_cmdready),
  .cmd_pixels({1'b0,pixels}),.cmd_channels(channels),.cmd_tag(tag),
  .s_valid(state==LOAD && s_valid && !rst),.s_ready(pool_sr),.s_data(s_data),.s_last(s_last),
  .m_valid(pool_mv),.m_ready(state==POOL_OUT),.m_data(pool_data),.m_sum(),
  .m_channel(pool_channel),.m_tag(),.m_last(pool_last),.m_inexact(pool_inexact),
  .rsp_valid(pool_rv),.rsp_ready(state==POOL_OUT),.rsp_error(pool_error),
  .rsp_outputs(),.rsp_inputs(),.rsp_tag(),.busy());
 integer_divider #(.W(10)) hard_sigmoid_divide(
  .clk(clk),.rst(rst),.s_valid(state==GATE_SEND && !rst),.s_ready(div_ready),
  .s_numerator(gate_numerator),.s_denominator(10'd3),
  .m_valid(div_valid),.m_ready(state==GATE_WAIT),
  .m_quotient(div_quotient),.m_remainder(div_remainder),.m_divzero(div_zero));

 // Payload memories have registered reads, no reset, and disjoint phase owners.
 always @(posedge clk) if(!rst) begin
  if(state==LOAD && s_valid && pool_sr) frame_mem[frame_address]<=s_data;
  if(state==POOL_OUT && pool_mv) descriptor_mem[pool_channel]<=pool_data;
  if(state==D0_READ) descriptor_q<=descriptor_mem[feed_index];
  if(state==D0_OUT && d0_mv && d0_error==0)
   hidden_mem[d0_row]<=d0_data[7]?8'd0:d0_data;
  if(state==D1_READ) hidden_q<=hidden_mem[feed_index];
  if(state==D1_OUT && d1_mv && d1_error==0) begin
   if(d1_data<=-8'sd96) gate_mem[d1_row]<=0;
   else if(d1_data>=8'sd96) gate_mem[d1_row]<=9'd256;
  end
  if(state==GATE_WAIT && div_valid && !div_zero && div_quotient<10'd256)
   gate_mem[gate_channel]<=gate_rounded;
  if(state==REPLAY_READ) begin
   frame_q<=frame_mem[frame_address];gate_q<=gate_mem[channel];
  end
 end
 always @(posedge clk) begin
  if(rst) begin
   state<=IDLE;weight_valid0<=0;weight_valid1<=0;meta_valid0<=0;meta_valid1<=0;
   cfg_bank<=0;cfg_op<=0;cfg_row<=0;cfg_word<=0;
   pixels<=0;channels<=0;hidden<=0;pixel<=0;channel<=0;check_row<=0;check_word<=0;feed_index<=0;
   tag<=0;frame_address<=0;replay_product<=0;gate_numerator<=0;gate_channel<=0;gate_last<=0;
   m_data<=0;m_inexact<=0;m_mean_inexact<=0;m_projection_clip<=0;m_projection_inexact<=0;
   m_gate_inexact<=0;m_gate_clamped<=0;rsp_error<=0;rsp_stage<=3;rsp_child_error<=0;
   rsp_inputs<=0;rsp_outputs<=0;
  end else case(state)
   IDLE:begin
    if(c_valid && c_ready) begin
     cfg_bank<=c_bank;cfg_op<=c_op;cfg_row<=c_row;cfg_word<=c_word;state<=CFG;
    end else if(cmd_valid && cmd_ready) begin
     pixels<=cmd_pixels;channels<=cmd_channels;hidden<=cmd_hidden;tag<=cmd_tag;
     pixel<=0;channel<=0;frame_address<=0;check_row<=0;check_word<=0;feed_index<=0;
     rsp_error<=0;rsp_stage<=3;rsp_child_error<=0;rsp_inputs<=0;rsp_outputs<=0;
     m_mean_inexact<=0;m_projection_clip<=0;m_projection_inexact<=0;m_gate_inexact<=0;m_gate_clamped<=0;
     if(cmd_pixels==0 || cmd_pixels>MAX_PIXELS || cmd_channels==0 ||
       cmd_channels>MAX_CHANNELS || cmd_hidden==0 || cmd_hidden>MAX_HIDDEN) begin
      rsp_error<=1;state<=DONE;
     end else state<=CHECK0;
    end
   end
   CFG:if(c_rsp_valid && c_rsp_ready)begin
    if(c_error==0)begin
     if(!cfg_bank)case(cfg_op)
      0:weight_valid0[cfg_row*W0+cfg_word]<=1;
      1:meta_valid0[cfg_row]<=1;
      2:begin weight_valid0<=0;meta_valid0<=0;end
     endcase
     else case(cfg_op)
      0:weight_valid1[cfg_row*W1+cfg_word]<=1;
      1:meta_valid1[cfg_row]<=1;
      2:begin weight_valid1<=0;meta_valid1<=0;end
     endcase
    end
    state<=IDLE;
   end
   CHECK0:begin
    if(!meta_valid0[check_row] || !weight_valid0[check_row*W0+check_word])begin
     rsp_error<=2;rsp_stage<=0;state<=DONE;
    end else if(check_word==((channels-1'b1)>>3))begin
     check_word<=0;
     if(check_row==hidden-1'b1)begin check_row<=0;state<=CHECK1;end
     else check_row<=check_row+1'b1;
    end else check_word<=check_word+1'b1;
   end
   CHECK1:begin
    if(!meta_valid1[check_row] || !weight_valid1[check_row*W1+check_word])begin
     rsp_error<=2;rsp_stage<=1;state<=DONE;
    end else if(check_word==((hidden-1'b1)>>3))begin
     check_word<=0;
     if(check_row==channels-1'b1)begin check_row<=0;state<=POOL_CMD;end
     else check_row<=check_row+1'b1;
    end else check_word<=check_word+1'b1;
   end
   POOL_CMD:if(pool_cmdready)state<=LOAD;
   LOAD:if(s_valid && pool_sr)begin
    rsp_inputs<=rsp_inputs+1'b1;
    if(s_last!=last_sample || last_sample)state<=POOL_OUT;
    else begin
     frame_address<=frame_address+1'b1;
     if(channel==channels-1'b1)begin channel<=0;pixel<=pixel+1'b1;end
     else channel<=channel+1'b1;
    end
   end
   POOL_OUT:begin
    if(pool_mv)m_mean_inexact<=m_mean_inexact|pool_inexact;
    if(pool_rv)begin
     if(pool_error!=0)begin
      rsp_error<=pool_error==2?3'd3:3'd4;rsp_stage<=2;rsp_child_error<=pool_error;state<=DONE;
     end else begin feed_index<=0;state<=D0_CMD;end
    end
   end
   D0_CMD:if(d0_cmdready)state<=D0_READ;
   D0_READ:state<=D0_FEED;
   D0_FEED:if(d0_sr)begin
    if(feed_index==channels-1'b1)begin feed_index<=0;state<=D0_OUT;end
    else begin feed_index<=feed_index+1'b1;state<=D0_READ;end
   end
   D0_OUT:if(d0_mv)begin
    if(d0_error!=0)begin rsp_error<=4;rsp_stage<=0;rsp_child_error<=d0_error;state<=DONE;end
    else begin
     m_projection_clip<=m_projection_clip|d0_clip;m_projection_inexact<=m_projection_inexact|d0_inexact;
     if(d0_last)begin feed_index<=0;state<=D1_CMD;end
    end
   end
   D1_CMD:if(d1_cmdready)state<=D1_READ;
   D1_READ:state<=D1_FEED;
   D1_FEED:if(d1_sr)begin
    if(feed_index==hidden-1'b1)begin feed_index<=0;state<=D1_OUT;end
    else begin feed_index<=feed_index+1'b1;state<=D1_READ;end
   end
   D1_OUT:if(d1_mv)begin
    if(d1_error!=0)begin rsp_error<=4;rsp_stage<=1;rsp_child_error<=d1_error;state<=DONE;end
    else begin
     m_projection_clip<=m_projection_clip|d1_clip;m_projection_inexact<=m_projection_inexact|d1_inexact;
     m_gate_clamped<=m_gate_clamped|(d1_data< -8'sd96 || d1_data>8'sd96);
     if(d1_data<= -8'sd96 || d1_data>=8'sd96)begin
      if(d1_last)begin frame_address<=0;pixel<=0;channel<=0;state<=REPLAY_READ;end
     end else begin
      gate_numerator<={shifted_logit[7:0],2'b00};gate_channel<=d1_row;gate_last<=d1_last;state<=GATE_SEND;
     end
    end
   end
   GATE_SEND:if(div_ready)state<=GATE_WAIT;
   GATE_WAIT:if(div_valid)begin
    if(div_zero || div_quotient>=10'd256)begin rsp_error<=4;rsp_stage<=1;rsp_child_error<=0;state<=DONE;end
    else begin
     m_gate_inexact<=m_gate_inexact|(div_remainder!=0);
     if(gate_last)begin frame_address<=0;pixel<=0;channel<=0;state<=REPLAY_READ;end
     else state<=D1_OUT;
    end
   end
   REPLAY_READ:state<=REPLAY_MUL;
   REPLAY_MUL:begin replay_product<=replay_multiply;state<=REPLAY_ROUND;end
   REPLAY_ROUND:begin m_data<=signed_rounded[7:0];m_inexact<=|replay_magnitude[7:0];state<=OUTPUT_WORD;end
   OUTPUT_WORD:if(m_ready)begin
    rsp_outputs<=rsp_outputs+1'b1;
    if(last_sample)state<=DONE;
    else begin
     frame_address<=frame_address+1'b1;
     if(channel==channels-1'b1)begin channel<=0;pixel<=pixel+1'b1;end
     else channel<=channel+1'b1;
     state<=REPLAY_READ;
    end
   end
   DONE:if(rsp_ready)state<=IDLE;
   default:state<=IDLE;
  endcase
 end
endmodule
`default_nettype wire
