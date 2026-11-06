// SPDX-License-Identifier: Apache-2.0
// Exact symbol-frame energy/peak measurement; Q16.16 EVM squared, no alignment.
module symbol_evm_measure #(
 parameter integer DATA_W=16,MAX_SYMBOLS=1024,TAG_W=8,
 parameter integer COUNT_GROW=(MAX_SYMBOLS>1)?$clog2(MAX_SYMBOLS):0,
 parameter integer REF_W=2*DATA_W+COUNT_GROW,
 parameter integer ERR_W=2*DATA_W+1+COUNT_GROW,
 parameter integer PEAK_W=2*DATA_W+1
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,input wire[31:0]c_symbols,input wire[TAG_W-1:0]c_tag,
 input wire s_valid,output wire s_ready,
 input wire[2*DATA_W-1:0]s_rx,s_ref,input wire s_last,
 output wire m_valid,input wire m_ready,output reg[2:0]m_status,
 output reg[31:0]m_symbols,output reg[TAG_W-1:0]m_tag,
 output reg[ERR_W-1:0]m_error_energy,output reg[REF_W-1:0]m_reference_energy,
 output reg[PEAK_W-1:0]m_peak_error,output reg[31:0]m_peak_index,
 output reg[31:0]m_evm2_q16,output reg m_clip
);
 localparam integer CNT_W=(MAX_SYMBOLS>1)?$clog2(MAX_SYMBOLS+1):1;
 localparam integer IDLE=0,INPUT_SYMBOL=1,ISSUE=2,DRAIN=3,DECIDE=4,DIV_WAIT=5,OUT=6,FLUSH=7;
 localparam[2:0]OK=0,BAD_LENGTH=1,BAD_LAST=2,ZERO_REFERENCE=3,ARITH=4;
 reg[2:0]state;
 reg out_valid;
 reg[CNT_W-1:0]length,index;
 reg[TAG_W-1:0]tag;
 reg[2*DATA_W-1:0]rx,reference;
 reg[1:0]issue_index;
 reg norm_seen;
 reg[ERR_W-1:0]error_sum;
 reg[REF_W-1:0]reference_sum;
 reg[PEAK_W-1:0]symbol_error,peak_error;
 reg[31:0]peak_index;
 wire helper_reset=rst ||state==FLUSH;
 wire norm_ready,norm_valid,norm_tag,norm_overflow;
 wire[PEAK_W-1:0]norm_power;
 wire[DATA_W-1:0]norm_x=issue_index[1] ?
   (issue_index[0]?reference[2*DATA_W-1:DATA_W]:reference[DATA_W-1:0]) :
   (issue_index[0]?rx[2*DATA_W-1:DATA_W]:rx[DATA_W-1:0]);
 wire[DATA_W-1:0]norm_y=issue_index[1] ? {DATA_W{1'b0}} :
   (issue_index[0]?reference[2*DATA_W-1:DATA_W]:reference[DATA_W-1:0]);
 // Each two-scalar vector is one complex squared distance. The original
 // signed D+1 difference covers the entire signed-D paired input domain.
 vector_l2sq #(.DATA_W(DATA_W),.ACC_W(PEAK_W),.TAG_W(1),.SIGNED_INPUT(1)) distance_core(
   .clk(clk),.rst(helper_reset),.s_valid(state==ISSUE &&!rst),.s_ready(norm_ready),
   .s_x(norm_x),.s_y(norm_y),.s_tag(issue_index[1]),.s_last(issue_index[0]),
   .m_valid(norm_valid),.m_ready(state==DRAIN &&!rst),.m_distance(norm_power),
   .m_tag(norm_tag),.m_overflow(norm_overflow));
 wire[ERR_W:0]error_next={1'b0,error_sum}+{{(ERR_W+1-PEAK_W){1'b0}},symbol_error};
 wire[REF_W:0]reference_next={1'b0,reference_sum}+{{(REF_W+1-PEAK_W){1'b0}},norm_power};
 // One extra leading zero makes both exact unsigned sums positive signed
 // operands. Signed OUT_W=33 has positive endpoint 2^32-1: uint32 clipping.
 wire div_ready,div_valid;
 wire[32:0]div_data;
 wire[1:0]div_flags;
 fp_div_iter #(.AW(ERR_W+1),.BW(REF_W+1),.FB(16),.OUT_W(33)) ratio_core(
   .clk(clk),.rst_n(!helper_reset),.s_tdata({1'b0,reference_sum,1'b0,error_sum}),
   .s_tvalid(state==DECIDE &&reference_sum!=0 &&!rst),.s_tready(div_ready),
   .m_tdata(div_data),.m_tuser(div_flags),.m_tvalid(div_valid),.m_tready(state==DIV_WAIT &&!rst));
 assign m_valid=!rst &&out_valid;
 assign c_ready=!rst &&state==IDLE;
 assign s_ready=!rst &&state==INPUT_SYMBOL;
 task fatal_marker(input[2:0]code,input[31:0]count);
   begin
     m_status<=code;m_symbols<=count;m_tag<=tag;m_error_energy<=0;m_reference_energy<=0;
     m_peak_error<=0;m_peak_index<=0;m_evm2_q16<=0;m_clip<=0;out_valid<=1;state<=OUT;
   end
 endtask
 always @(posedge clk)begin
   if(rst)begin
     state<=IDLE;out_valid<=0;m_status<=0;m_symbols<=0;m_tag<=0;m_error_energy<=0;
     m_reference_energy<=0;m_peak_error<=0;m_peak_index<=0;m_evm2_q16<=0;m_clip<=0;
     length<=0;index<=0;tag<=0;rx<=0;reference<=0;issue_index<=0;norm_seen<=0;
     error_sum<=0;reference_sum<=0;symbol_error<=0;peak_error<=0;peak_index<=0;
   end else begin
     case(state)
       IDLE:if(c_valid)begin
         tag<=c_tag;length<=c_symbols[CNT_W-1:0];index<=0;
         error_sum<=0;reference_sum<=0;peak_error<=0;peak_index<=0;
         if(c_symbols==0 ||c_symbols>MAX_SYMBOLS)begin
           m_status<=BAD_LENGTH;m_symbols<=0;m_tag<=c_tag;m_error_energy<=0;m_reference_energy<=0;
           m_peak_error<=0;m_peak_index<=0;m_evm2_q16<=0;m_clip<=0;out_valid<=1;state<=OUT;
         end else state<=INPUT_SYMBOL;
       end
       INPUT_SYMBOL:if(s_valid)begin
         if(s_last!=(index==length-1'b1))fatal_marker(BAD_LAST,32'(index)+1);
         else begin rx<=s_rx;reference<=s_ref;issue_index<=0;norm_seen<=0;state<=ISSUE;end
       end
       ISSUE:if(norm_ready)begin
         if(issue_index==3)state<=DRAIN;
         else issue_index<=issue_index+1'b1;
       end
       DRAIN:if(norm_valid)begin
         if(norm_overflow ||norm_tag!=norm_seen)state<=FLUSH;
         else if(!norm_seen)begin
           symbol_error<=norm_power;norm_seen<=1;
           if(index==0 ||norm_power>peak_error)begin peak_error<=norm_power;peak_index<=32'(index);end
         end else if(error_next[ERR_W] ||reference_next[REF_W])state<=FLUSH;
         else begin
           error_sum<=error_next[ERR_W-1:0];reference_sum<=reference_next[REF_W-1:0];
           if(index==length-1'b1)state<=DECIDE;
           else begin index<=index+1'b1;state<=INPUT_SYMBOL;end
         end
       end
       DECIDE:begin
         m_symbols<=32'(length);m_tag<=tag;m_error_energy<=error_sum;m_reference_energy<=reference_sum;
         m_peak_error<=peak_error;m_peak_index<=peak_index;m_clip<=0;
         if(reference_sum==0)begin
           m_status<=ZERO_REFERENCE;m_evm2_q16<=0;out_valid<=1;state<=OUT;
         end else if(div_ready)state<=DIV_WAIT;
       end
       DIV_WAIT:if(div_valid)begin
         if(div_flags[1] ||div_data[32])state<=FLUSH;
         else begin m_status<=OK;m_evm2_q16<=div_data[31:0];m_clip<=div_flags[0];out_valid<=1;state<=OUT;end
       end
       OUT:if(m_valid &&m_ready)begin out_valid<=0;state<=IDLE;end
       FLUSH:fatal_marker(ARITH,32'(index)+1);
       default:state<=FLUSH;
     endcase
   end
 end
`ifndef SYNTHESIS
 initial begin
   if(DATA_W<8 ||DATA_W>16 ||MAX_SYMBOLS<1 ||MAX_SYMBOLS>4096 ||TAG_W<1 ||TAG_W>32 ||
      COUNT_GROW!=((MAX_SYMBOLS>1)?$clog2(MAX_SYMBOLS):0) ||REF_W!=2*DATA_W+COUNT_GROW ||
      ERR_W!=2*DATA_W+1+COUNT_GROW ||PEAK_W!=2*DATA_W+1)
     $fatal(1,"symbol_evm_measure: unsupported static configuration");
 end
`endif
endmodule
