// SPDX-License-Identifier: Apache-2.0
// Exact per-bin sums of paired spectra, then RNE magnitude-squared coherence.
module paired_spectral_coherence #(
 parameter integer MAX_BINS=64,MAX_AVERAGES=16,TAG_W=8,
 localparam integer A=(MAX_AVERAGES>1)?$clog2(MAX_AVERAGES):0,
 localparam integer POWER_W=32+A,CROSS_W=33+A,
 localparam integer INDEX_W=(MAX_BINS>1)?$clog2(MAX_BINS):1,
 localparam integer LENGTH_W=$clog2(MAX_BINS+1),
 localparam integer FRAME_W=(MAX_AVERAGES>1)?$clog2(MAX_AVERAGES):1,
 localparam integer AVERAGES_W=$clog2(MAX_AVERAGES+1)
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,input wire[31:0]c_bins,c_averages,
 input wire[TAG_W-1:0]c_tag,
 input wire s_valid,output wire s_ready,input wire[63:0]s_xy,
 input wire s_x_last,s_y_last,
 output wire m_valid,input wire m_ready,output reg[2:0]m_status,
 output reg[31:0]m_index,output reg m_last,output wire[TAG_W-1:0]m_tag,
 output reg[POWER_W-1:0]m_sxx,m_syy,
 output reg signed[CROSS_W-1:0]m_cross_re,m_cross_im,
 output reg[16:0]m_coherence_q16
);
 localparam integer WORD_W=2*POWER_W+2*CROSS_W;
 localparam integer PRODUCT_W=2*CROSS_W,NUM_W=PRODUCT_W+1,DIV_W=NUM_W+1;
 localparam[4:0]IDLE=0,LOAD=1,ISSUE_X=2,ISSUE_Y=3,ISSUE_C=4,WAIT_PRODUCTS=5,
   WRITE=6,FINAL_READ=7,CHECK_ENERGY=8,MUL_ISSUE=9,MUL_WAIT=10,CHECK_RATIO=11,
   DIV_ISSUE=12,DIV_WAIT=13,OUTPUT=14,FAULT_RESET=15,FAULT_RECOVER=16;
 reg[4:0]state;
 reg[WORD_W-1:0]sum_ram[0:MAX_BINS-1];
 reg[WORD_W-1:0]old_word;
 reg[63:0]pair;
 reg[INDEX_W-1:0]bin_index,read_index;
 reg[LENGTH_W-1:0]length;
 reg[FRAME_W-1:0]frame_index;
 reg[AVERAGES_W-1:0]averages;
 reg[TAG_W-1:0]tag;
 reg[1:0]received,multiply_phase;
 reg[POWER_W-1:0]next_xx,next_yy;
 reg signed[CROSS_W-1:0]next_re,next_im;
 reg[NUM_W-1:0]numerator,denominator;
 reg helper_flush,helper_rst_n;
 // This register converts the multiplier's async reset into edge-only reset
 // changes. All helpers observe a full reset edge before command readiness.
 always @(posedge clk)begin
   if(rst ||helper_flush)helper_rst_n<=0;
   else helper_rst_n<=1;
 end
 assign c_ready=!rst &&helper_rst_n &&state==IDLE;
 assign s_ready=!rst &&helper_rst_n &&state==LOAD;
 assign m_valid=!rst &&state==OUTPUT;
 assign m_tag=tag;

 wire signed[16:0]xr={pair[15],pair[15:0]},xi={pair[31],pair[31:16]};
 wire signed[16:0]yr={pair[47],pair[47:32]},yi={pair[63],pair[63:48]};
 wire signed[16:0]neg_xi=-xi,neg_yi=-yi;
 // Actual cplx_mac lane order is {b_im,b_re,a_im,a_re}. Widen before conj.
 wire[67:0]mac_input=(state==ISSUE_X)?{xi,xr,neg_xi,xr}:
   (state==ISSUE_Y)?{yi,yr,neg_yi,yr}:{yi,yr,neg_xi,xr};
 wire mac_ready,mac_valid;
 wire[65:0]mac_output;
 wire[1:0]mac_flags;
 wire mac_issue=!rst &&helper_rst_n &&(state==ISSUE_X ||state==ISSUE_Y ||state==ISSUE_C);
 cplx_mac #(.DATA_W(17),.ACC_W(35),.OUT_W(33),.SHIFT(0)) product_core(
   .clk(clk),.rst_n(helper_rst_n),.s_tdata(mac_input),.s_tlast(1'b1),
   .s_tvalid(mac_issue),.s_tready(mac_ready),.m_tdata(mac_output),.m_tuser(mac_flags),
   .m_tvalid(mac_valid),.m_tready(1'b1));
 wire signed[32:0]term_re=mac_output[32:0],term_im=mac_output[65:33];
 wire[POWER_W-1:0]old_xx=old_word[POWER_W-1:0],old_yy=old_word[2*POWER_W-1:POWER_W];
 wire signed[CROSS_W-1:0]old_re=old_word[2*POWER_W+CROSS_W-1:2*POWER_W];
 wire signed[CROSS_W-1:0]old_im=old_word[WORD_W-1:2*POWER_W+CROSS_W];
 wire signed[CROSS_W-1:0]extended_re={{A{term_re[32]}},term_re};
 wire signed[CROSS_W-1:0]extended_im={{A{term_im[32]}},term_im};

 wire[CROSS_W-1:0]abs_re=m_cross_re[CROSS_W-1]?(~m_cross_re+1'b1):m_cross_re;
 wire[CROSS_W-1:0]abs_im=m_cross_im[CROSS_W-1]?(~m_cross_im+1'b1):m_cross_im;
 wire[CROSS_W-1:0]mul_a=(multiply_phase==0)?abs_re:(multiply_phase==1)?abs_im:{1'b0,m_sxx};
 wire[CROSS_W-1:0]mul_b=(multiply_phase==0)?abs_re:(multiply_phase==1)?abs_im:{1'b0,m_syy};
 wire mul_ready,mul_valid;
 wire[PRODUCT_W-1:0]mul_product;
 img_hist_serial_multiply #(.A_W(CROSS_W),.B_W(CROSS_W)) wide_product(
   .clk(clk),.rst_n(helper_rst_n),.clk_en(1'b1),
   .s_valid(!rst &&helper_rst_n &&state==MUL_ISSUE),.s_ready(mul_ready),.s_a(mul_a),.s_b(mul_b),
   .m_valid(mul_valid),.m_ready(!rst &&state==MUL_WAIT),.m_product(mul_product));
 wire div_ready,div_valid;
 wire[17:0]div_quotient;
 wire[1:0]div_flags;
 fp_div_iter #(.AW(DIV_W),.BW(DIV_W),.FB(16),.OUT_W(18)) ratio_core(
   .clk(clk),.rst_n(helper_rst_n),.s_tdata({1'b0,denominator,1'b0,numerator}),
   .s_tvalid(!rst &&helper_rst_n &&state==DIV_ISSUE),.s_tready(div_ready),
   .m_tdata(div_quotient),.m_tuser(div_flags),.m_tvalid(div_valid),
   .m_tready(!rst &&state==DIV_WAIT));

 // Faults terminate the whole remaining batch. Reset every helper before an
 // ARITH marker can retire, preventing queued products leaking into recovery.
 task arithmetic_abort;
   begin
     m_status<=5;m_last<=1;m_sxx<=0;m_syy<=0;m_cross_re<=0;m_cross_im<=0;m_coherence_q16<=0;
     helper_flush<=1;state<=FAULT_RESET;
   end
 endtask
 always @(posedge clk)begin
   if(rst)begin
     state<=IDLE;old_word<=0;pair<=0;bin_index<=0;read_index<=0;length<=0;frame_index<=0;
     averages<=0;tag<=0;received<=0;multiply_phase<=0;next_xx<=0;next_yy<=0;next_re<=0;next_im<=0;
     numerator<=0;denominator<=0;helper_flush<=0;m_status<=0;m_index<=0;m_last<=0;
     m_sxx<=0;m_syy<=0;m_cross_re<=0;m_cross_im<=0;m_coherence_q16<=0;
   end else case(state)
     IDLE:if(c_valid &&c_ready)begin
       length<=c_bins[LENGTH_W-1:0];averages<=c_averages[AVERAGES_W-1:0];tag<=c_tag;
       bin_index<=0;read_index<=0;frame_index<=0;m_status<=0;m_index<=0;m_last<=0;
       m_sxx<=0;m_syy<=0;m_cross_re<=0;m_cross_im<=0;m_coherence_q16<=0;
       if(c_bins==0 ||c_bins>MAX_BINS)begin m_status<=1;m_last<=1;state<=OUTPUT;end
       else if(c_averages==0 ||c_averages>MAX_AVERAGES)begin m_status<=2;m_last<=1;state<=OUTPUT;end
       else state<=LOAD;
     end
     LOAD:if(s_valid &&s_ready)begin
       if(s_x_last!=(bin_index==length-1'b1) ||s_y_last!=(bin_index==length-1'b1))begin
         m_status<=3;m_index<=bin_index;m_last<=1;state<=OUTPUT;
       end else begin pair<=s_xy;received<=0;state<=ISSUE_X;end
     end
     ISSUE_X:if(mac_ready)begin
       old_word<=(frame_index==0)?{WORD_W{1'b0}}:sum_ram[bin_index];state<=ISSUE_Y;
     end
     ISSUE_Y:if(mac_ready)state<=ISSUE_C;
     ISSUE_C:if(mac_ready)state<=WAIT_PRODUCTS;
     WAIT_PRODUCTS:if(mac_valid)begin
       if(mac_flags!=0 ||(received<2 &&(term_im!=0 ||term_re[32])))begin
         m_index<=bin_index;arithmetic_abort();
       end else begin
         case(received)
           0:next_xx<=old_xx+{{A{1'b0}},term_re[31:0]};
           1:next_yy<=old_yy+{{A{1'b0}},term_re[31:0]};
           default:begin next_re<=old_re+extended_re;next_im<=old_im+extended_im;state<=WRITE;end
         endcase
         received<=received+1'b1;
       end
     end
     WRITE:begin
       sum_ram[bin_index]<={next_im,next_re,next_yy,next_xx};
       if(bin_index==length-1'b1)begin
         if(frame_index==averages-1'b1)begin read_index<=0;state<=FINAL_READ;end
         else begin frame_index<=frame_index+1'b1;bin_index<=0;state<=LOAD;end
       end else begin bin_index<=bin_index+1'b1;state<=LOAD;end
     end
     FINAL_READ:begin
       {m_cross_im,m_cross_re,m_syy,m_sxx}<=sum_ram[read_index];
       m_index<=read_index;m_last<=(read_index==length-1'b1);m_status<=0;m_coherence_q16<=0;
       state<=CHECK_ENERGY;
     end
     CHECK_ENERGY:begin
       if(m_sxx==0 ||m_syy==0)begin
         if(m_cross_re!=0 ||m_cross_im!=0)arithmetic_abort();
         else begin m_status<=4;state<=OUTPUT;end
       end else begin multiply_phase<=0;state<=MUL_ISSUE;end
     end
     MUL_ISSUE:if(mul_ready)state<=MUL_WAIT;
     MUL_WAIT:if(mul_valid)begin
       if(multiply_phase==0)numerator<={1'b0,mul_product};
       else if(multiply_phase==1)numerator<=numerator+{1'b0,mul_product};
       else denominator<={1'b0,mul_product};
       if(multiply_phase==2)state<=CHECK_RATIO;
       else begin multiply_phase<=multiply_phase+1'b1;state<=MUL_ISSUE;end
     end
     CHECK_RATIO:begin
       if(denominator==0 ||numerator>denominator)arithmetic_abort();
       else state<=DIV_ISSUE;
     end
     DIV_ISSUE:if(div_ready)state<=DIV_WAIT;
     DIV_WAIT:if(div_valid)begin
       if(div_flags!=0 ||div_quotient>18'd65536)arithmetic_abort();
       else begin m_coherence_q16<=div_quotient[16:0];state<=OUTPUT;end
     end
     OUTPUT:if(m_ready)begin
       if(m_last)state<=IDLE;
       else begin read_index<=read_index+1'b1;state<=FINAL_READ;end
     end
     FAULT_RESET:begin helper_flush<=0;state<=FAULT_RECOVER;end
     FAULT_RECOVER:if(helper_rst_n)state<=OUTPUT;
     default:state<=IDLE;
   endcase
 end
 generate if(MAX_BINS<1 ||MAX_BINS>256 ||MAX_AVERAGES<1 ||MAX_AVERAGES>64 ||TAG_W<1 ||TAG_W>32)begin:bad_parameters
   paired_spectral_coherence_invalid_parameters__see_README invalid();
 end endgenerate
endmodule
