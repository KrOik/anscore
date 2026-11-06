// SPDX-License-Identifier: Apache-2.0
// Exact total-variation distance between adjacent valid normalized power frames.
`default_nettype none
module spectral_shape_change #(
 parameter integer MAX_BINS=256,TAG_W=8,
 localparam integer INDEX_W=(MAX_BINS>1)?$clog2(MAX_BINS):1,
 localparam integer COUNT_W=$clog2(MAX_BINS+1),
 localparam integer SUM_W=32+((MAX_BINS>1)?$clog2(MAX_BINS):0),
 localparam integer STAT_W=2*SUM_W
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,input wire [31:0] c_bins,
 input wire c_restart,input wire [TAG_W-1:0] c_tag,
 input wire s_valid,output wire s_ready,input wire [31:0] s_power,
 input wire s_last,s_invalid,
 output wire m_valid,input wire m_ready,output reg [3:0] m_status,
 output reg [TAG_W-1:0] m_tag,output reg [31:0] m_bins,
 output reg [COUNT_W-1:0] m_received,
 output wire [SUM_W-1:0] m_total,m_reference_total,
 output wire [STAT_W-1:0] m_numerator,m_denominator,
 output reg [16:0] m_change_q16,output reg m_metric_valid,m_inexact,
 output wire busy
);
 localparam integer DIV_W=STAT_W+16;
 localparam [4:0] IDLE=0,LOAD=1,CLASSIFY=2,READ_REQ=3,READ_WAIT=4,
  MUL_P_REQ=5,MUL_P_WAIT=6,MUL_Q_REQ=7,MUL_Q_WAIT=8,
  MUL_D_REQ=9,MUL_D_WAIT=10,DIV_REQ=11,DIV_WAIT=12,FLUSH=13,HOLD=14;
 localparam [3:0] OK=0,WARMUP=1,BOTH_ZERO=2,REFERENCE_ZERO=3,CURRENT_ZERO=4,
  BAD_LENGTH=5,EARLY_LAST=6,MISSING_LAST=7,INVALID_INPUT=8,ARITH=9;
 reg [4:0] state;
 // The legacy helpers see reset transitions only at clock edges. A complete
 // reset edge precedes public reopening; no payload memory is reset.
 reg helper_n;
 reg history_valid,reference_bank,comparable,commit_candidate;
 reg [COUNT_W-1:0] length,reference_length;
 reg [INDEX_W-1:0] write_index,read_index;
 reg [SUM_W-1:0] current_total,previous_total,reference_total;
 reg [31:0] current_power,previous_power;
 reg [STAT_W-1:0] first_product,numerator,denominator;
 wire candidate_bank=!reference_bank;
 wire ram0_ready,ram1_ready,ram0_valid,ram1_valid,ram0_error,ram1_error;
 wire [31:0] ram0_data,ram1_data;
 wire both_ready=ram0_ready && ram1_ready;
 wire candidate_ready=candidate_bank?ram1_ready:ram0_ready;
 wire load_request=!rst && helper_n && state==LOAD && s_valid;
 wire read_request=!rst && helper_n && state==READ_REQ && both_ready;
 wire ram0_request=read_request || (load_request && !candidate_bank);
 wire ram1_request=read_request || (load_request && candidate_bank);
 wire [INDEX_W-1:0] memory_address=(state==LOAD)?write_index:read_index;
 cip_sync_sp_ram #(.DATA_WIDTH(32),.ADDR_WIDTH(INDEX_W),.DEPTH(MAX_BINS)) bank0(
  .clk(clk),.rst_n(helper_n),.clk_en(1'b1),.req_valid(ram0_request),.req_ready(ram0_ready),
  .req_write(state==LOAD),.req_addr(memory_address),.req_wdata(s_power),.req_wstrb(4'b1111),
  .rsp_valid(ram0_valid),.rsp_ready(1'b1),.rsp_rdata(ram0_data),.rsp_error(ram0_error));
 cip_sync_sp_ram #(.DATA_WIDTH(32),.ADDR_WIDTH(INDEX_W),.DEPTH(MAX_BINS)) bank1(
  .clk(clk),.rst_n(helper_n),.clk_en(1'b1),.req_valid(ram1_request),.req_ready(ram1_ready),
  .req_write(state==LOAD),.req_addr(memory_address),.req_wdata(s_power),.req_wstrb(4'b1111),
  .rsp_valid(ram1_valid),.rsp_ready(1'b1),.rsp_rdata(ram1_data),.rsp_error(ram1_error));
 wire [SUM_W:0] load_sum={1'b0,current_total}+{{(SUM_W-31){1'b0}},s_power};
 wire mul_ready,mul_valid;
 wire [STAT_W-1:0] product;
 wire [SUM_W-1:0] mul_a=(state==MUL_D_REQ)?current_total:
  (state==MUL_P_REQ)?{{(SUM_W-32){1'b0}},current_power}:{{(SUM_W-32){1'b0}},previous_power};
 wire [SUM_W-1:0] mul_b=(state==MUL_Q_REQ)?current_total:previous_total;
 img_hist_serial_multiply #(.A_W(SUM_W),.B_W(SUM_W)) multiply(
  .clk(clk),.rst_n(helper_n),.clk_en(1'b1),
  .s_valid(!rst && helper_n && (state==MUL_P_REQ || state==MUL_Q_REQ || state==MUL_D_REQ)),
  .s_ready(mul_ready),.s_a(mul_a),.s_b(mul_b),
  .m_valid(mul_valid),.m_ready(state==MUL_P_WAIT || state==MUL_Q_WAIT || state==MUL_D_WAIT),
  .m_product(product));
 // Compare before unsigned subtraction. This is the positive part of the exact
 // signed (STAT_W+1)-bit difference, without wrapping a negative result.
 wire [STAT_W-1:0] positive_difference=(first_product>product)?first_product-product:{STAT_W{1'b0}};
 wire [STAT_W:0] added_numerator={1'b0,numerator}+{1'b0,positive_difference};
 wire div_ready,div_valid,div_zero;
 wire [DIV_W-1:0] quotient,remainder;
 wire [DIV_W-1:0] div_numerator={numerator,16'b0};
 wire [DIV_W-1:0] div_denominator={{16{1'b0}},denominator};
 integer_divider #(.W(DIV_W)) divide(
  .clk(clk),.rst(rst || !helper_n),
  .s_valid(!rst && helper_n && state==DIV_REQ),.s_ready(div_ready),
  .s_numerator(div_numerator),.s_denominator(div_denominator),
  .m_valid(div_valid),.m_ready(state==DIV_WAIT),
  .m_quotient(quotient),.m_remainder(remainder),.m_divzero(div_zero));
 wire [DIV_W:0] twice_remainder={remainder,1'b0};
 wire round_up=(twice_remainder>{1'b0,div_denominator}) ||
  (twice_remainder=={1'b0,div_denominator} && quotient[0]);
 wire [DIV_W:0] rounded={1'b0,quotient}+{{DIV_W{1'b0}},round_up};
 assign c_ready=!rst && helper_n && state==IDLE;
 assign s_ready=!rst && helper_n && state==LOAD && candidate_ready;
 assign m_valid=!rst && state==HOLD;
 assign busy=!rst && state!=IDLE;
 assign m_total=current_total;assign m_reference_total=previous_total;
 assign m_numerator=numerator;assign m_denominator=denominator;
 task frame_error(input [3:0] status);
  begin
   m_status<=status;current_total<=0;previous_total<=0;numerator<=0;denominator<=0;
   m_change_q16<=0;m_metric_valid<=0;m_inexact<=0;commit_candidate<=0;
   history_valid<=0;helper_n<=0;state<=FLUSH;
  end
 endtask
 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;helper_n<=0;history_valid<=0;reference_bank<=0;comparable<=0;commit_candidate<=0;
   length<=0;reference_length<=0;write_index<=0;read_index<=0;
   current_total<=0;previous_total<=0;reference_total<=0;current_power<=0;previous_power<=0;
   first_product<=0;numerator<=0;denominator<=0;
   m_status<=0;m_tag<=0;m_bins<=0;m_received<=0;m_change_q16<=0;m_metric_valid<=0;m_inexact<=0;
  end else begin
   helper_n<=1;
   case(state)
    IDLE:if(c_valid && c_ready)begin
     m_tag<=c_tag;m_bins<=c_bins;m_received<=0;m_status<=OK;
     m_change_q16<=0;m_metric_valid<=0;m_inexact<=0;
     current_total<=0;previous_total<=0;numerator<=0;denominator<=0;
     write_index<=0;read_index<=0;commit_candidate<=0;
     comparable<=history_valid && !c_restart && c_bins==reference_length;
     if(c_bins==0 || c_bins>MAX_BINS)begin m_status<=BAD_LENGTH;state<=HOLD;end
     else begin
      length<=c_bins[COUNT_W-1:0];
      if(history_valid && !c_restart && c_bins==reference_length)previous_total<=reference_total;
      state<=LOAD;
     end
    end
    LOAD:if(s_valid && s_ready)begin
     m_received<=m_received+1'b1;
     if(s_invalid)frame_error(INVALID_INPUT);
     else if(s_last && write_index!=length-1'b1)frame_error(EARLY_LAST);
     else if(!s_last && write_index==length-1'b1)frame_error(MISSING_LAST);
     else if(load_sum[SUM_W])frame_error(ARITH);
     else begin
      current_total<=load_sum[SUM_W-1:0];
      if(write_index==length-1'b1)state<=CLASSIFY;
      else write_index<=write_index+1'b1;
     end
    end
    // Also drains the final write response before the first paired read.
    CLASSIFY:begin
     if((candidate_bank?ram1_valid:ram0_valid) && (candidate_bank?ram1_error:ram0_error))frame_error(ARITH);
     else if(!comparable)begin m_status<=WARMUP;commit_candidate<=1;state<=HOLD;end
     else if(current_total==0 || previous_total==0)begin
      m_status<=(current_total==0 && previous_total==0)?BOTH_ZERO:
       (previous_total==0)?REFERENCE_ZERO:CURRENT_ZERO;
      commit_candidate<=1;state<=HOLD;
     end else state<=READ_REQ;
    end
    READ_REQ:if(both_ready)state<=READ_WAIT;
    READ_WAIT:if(ram0_valid && ram1_valid)begin
     if(ram0_error || ram1_error)frame_error(ARITH);
     else begin
      current_power<=candidate_bank?ram1_data:ram0_data;
      previous_power<=reference_bank?ram1_data:ram0_data;state<=MUL_P_REQ;
     end
    end
    MUL_P_REQ:if(mul_ready)state<=MUL_P_WAIT;
    MUL_P_WAIT:if(mul_valid)begin first_product<=product;state<=MUL_Q_REQ;end
    MUL_Q_REQ:if(mul_ready)state<=MUL_Q_WAIT;
    MUL_Q_WAIT:if(mul_valid)begin
     if(added_numerator[STAT_W])frame_error(ARITH);
     else begin
      numerator<=added_numerator[STAT_W-1:0];
      if(read_index==length-1'b1)state<=MUL_D_REQ;
      else begin read_index<=read_index+1'b1;state<=READ_REQ;end
     end
    end
    MUL_D_REQ:if(mul_ready)state<=MUL_D_WAIT;
    MUL_D_WAIT:if(mul_valid)begin
     if(product==0 || numerator>product)frame_error(ARITH);
     else begin denominator<=product;state<=DIV_REQ;end
    end
    DIV_REQ:if(div_ready)state<=DIV_WAIT;
    DIV_WAIT:if(div_valid)begin
     if(div_zero || remainder>=div_denominator || rounded>65536)frame_error(ARITH);
     else begin
      m_status<=OK;m_change_q16<=rounded[16:0];m_metric_valid<=1;m_inexact<=(remainder!=0);
      commit_candidate<=1;state<=HOLD;
     end
    end
    FLUSH:state<=HOLD;
    HOLD:if(m_ready)begin
     // The old reference survives every held result. Ownership changes only
     // at the public summary transfer, even for a legitimate zero-power frame.
     if(commit_candidate)begin
      reference_bank<=candidate_bank;reference_length<=length;
      reference_total<=current_total;history_valid<=1;
     end
     state<=IDLE;
    end
    default:frame_error(ARITH);
   endcase
  end
 end
 generate if(MAX_BINS<1 || MAX_BINS>256 || TAG_W<1 || TAG_W>32)begin:invalid_parameters
  spectral_shape_change_invalid_parameters__see_README invalid_configuration();
 end endgenerate
endmodule
`default_nettype wire
