// SPDX-License-Identifier: Apache-2.0
// Exact accepted-sample-time repeated-half metric, with consecutive-hit events.
module repeated_half_sync #(
 parameter integer DATA_W=16,L=16,MAX_SAMPLES=1024,TAG_W=8,
 localparam integer A=(L>1)?$clog2(L):0,
 localparam integer CROSS_W=2*DATA_W+1+A
)(
 input wire clk,rst,
 input wire c_valid,output wire c_ready,
 input wire[31:0]c_samples,c_threshold_q16,c_hold,
 input wire[63:0]c_min_energy,input wire[TAG_W-1:0]c_tag,
 input wire s_valid,output wire s_ready,input wire[2*DATA_W-1:0]s_iq,input wire s_last,
 output wire m_valid,input wire m_ready,output reg[2:0]m_status,
 output reg[31:0]m_end,m_start,m_event_start,output reg m_qual,m_event,m_last,
 output wire[TAG_W-1:0]m_tag,output reg[CROSS_W-1:0]m_energy,
 output reg signed[CROSS_W-1:0]m_cross_re,m_cross_im
);
 localparam integer TERM_W=2*DATA_W+1,POWER_W=2*DATA_W;
 localparam integer LPW=(L>1)?$clog2(L):1,EPW=$clog2(2*L);
 localparam integer IW=$clog2(MAX_SAMPLES),NW=$clog2(MAX_SAMPLES+1);
 localparam integer SQ_W=2*CROSS_W,NUM_W=SQ_W+1;
 localparam integer MUL_A_W=SQ_W+2,MUL_W=MUL_A_W+CROSS_W;
 localparam[4:0]IDLE=0,LOAD=1,READ=2,ISSUE_POWER=3,ISSUE_CROSS=4,
   WAIT_PRODUCTS=5,UPDATE=6,WRITE=7,MUL_ISSUE=8,MUL_WAIT=9,
   DECIDE=10,OUTPUT=11,FAULT_RESET=12,FAULT_RECOVER=13;
 reg[4:0]state;
 reg[2*DATA_W-1:0]delay_ram[0:L-1];
 reg[POWER_W-1:0]power_ram[0:2*L-1];
 reg[2*TERM_W-1:0]product_ram[0:L-1];
 reg[LPW-1:0]lag_pointer;
 reg[EPW-1:0]energy_pointer;
 reg[IW-1:0]sample_index;
 reg[NW-1:0]length;
 reg[2*DATA_W-1:0]sample_word,delayed_word;
 reg[POWER_W-1:0]old_power,new_power;
 reg[2*TERM_W-1:0]old_product;
 reg signed[TERM_W-1:0]new_re,new_im;
 reg[CROSS_W-1:0]energy,min_energy;
 reg signed[CROSS_W-1:0]cross_re,cross_im;
 reg[16:0]threshold;
 reg[6:0]hold_windows,run_count;
 reg[31:0]run_start;
 reg[TAG_W-1:0]tag;
 reg received;
 reg[1:0]multiply_phase;
 reg[NUM_W-1:0]numerator;
 reg[SQ_W-1:0]energy_squared;
 reg[MUL_W-1:0]threshold_product;
 reg helper_flush,helper_rst_n;
 // Edge-only changes bridge the serial multiplier's async-low reset. All
 // synchronous helpers see a complete low-reset edge before new readiness.
 always @(posedge clk)begin
   if(rst ||helper_flush)helper_rst_n<=0;
   else helper_rst_n<=1;
 end
 assign c_ready=!rst &&helper_rst_n &&state==IDLE;
 assign s_ready=!rst &&helper_rst_n &&state==LOAD;
 assign m_valid=!rst &&state==OUTPUT;
 assign m_tag=tag;
 wire signed[DATA_W:0]xr={sample_word[DATA_W-1],sample_word[DATA_W-1:0]};
 wire signed[DATA_W:0]xi={sample_word[2*DATA_W-1],sample_word[2*DATA_W-1:DATA_W]};
 wire signed[DATA_W:0]dr={delayed_word[DATA_W-1],delayed_word[DATA_W-1:0]};
 wire signed[DATA_W:0]di={delayed_word[2*DATA_W-1],delayed_word[2*DATA_W-1:DATA_W]};
 wire signed[DATA_W:0]negative_xi=-xi,negative_di=-di;
 // Actual helper packing is {b_im,b_re,a_im,a_re}. Conj(delay)*current
 // therefore has positive phase for a positive-frequency repeated waveform.
 wire[4*(DATA_W+1)-1:0]mac_input=(state==ISSUE_POWER)?
   {xi,xr,negative_xi,xr}:{xi,xr,negative_di,dr};
 wire mac_ready,mac_valid;
 wire[2*TERM_W-1:0]mac_output;
 wire[1:0]mac_flags;
 cplx_mac #(.DATA_W(DATA_W+1),.ACC_W(2*DATA_W+3),.OUT_W(TERM_W),.SHIFT(0)) product_core(
   .clk(clk),.rst_n(helper_rst_n),.s_tdata(mac_input),.s_tlast(1'b1),
   .s_tvalid(!rst &&helper_rst_n &&(state==ISSUE_POWER ||state==ISSUE_CROSS)),
   .s_tready(mac_ready),.m_tdata(mac_output),.m_tuser(mac_flags),.m_tvalid(mac_valid),.m_tready(1'b1));
 wire signed[TERM_W-1:0]term_re=mac_output[TERM_W-1:0],term_im=mac_output[2*TERM_W-1:TERM_W];
 wire signed[TERM_W-1:0]old_re=old_product[TERM_W-1:0],old_im=old_product[2*TERM_W-1:TERM_W];
 // Widen before both additions and subtraction; even the L=1 old+new
 // intermediate is represented before the outgoing term cancels it.
 wire signed[CROSS_W+1:0]acc_re=$signed({{2{cross_re[CROSS_W-1]}},cross_re})+
   $signed({{(A+2){new_re[TERM_W-1]}},new_re})-$signed({{(A+2){old_re[TERM_W-1]}},old_re});
 wire signed[CROSS_W+1:0]acc_im=$signed({{2{cross_im[CROSS_W-1]}},cross_im})+
   $signed({{(A+2){new_im[TERM_W-1]}},new_im})-$signed({{(A+2){old_im[TERM_W-1]}},old_im});
 wire[CROSS_W+1:0]acc_energy={2'b0,energy}+{{(A+3){1'b0}},new_power}-{{(A+3){1'b0}},old_power};
 wire sum_bad=(acc_re[CROSS_W+1:CROSS_W-1]!={3{acc_re[CROSS_W-1]}}) ||
   (acc_im[CROSS_W+1:CROSS_W-1]!={3{acc_im[CROSS_W-1]}}) ||(|acc_energy[CROSS_W+1:CROSS_W]);
 wire[CROSS_W-1:0]abs_re=m_cross_re[CROSS_W-1]?(~m_cross_re+1'b1):m_cross_re;
 wire[CROSS_W-1:0]abs_im=m_cross_im[CROSS_W-1]?(~m_cross_im+1'b1):m_cross_im;
 wire[MUL_A_W-1:0]mul_a=(multiply_phase==0)?{{(CROSS_W+2){1'b0}},abs_re}:
   (multiply_phase==1)?{{(CROSS_W+2){1'b0}},abs_im}:
   (multiply_phase==2)?{{(CROSS_W+2){1'b0}},m_energy}:{2'b0,energy_squared};
 wire[CROSS_W-1:0]mul_b=(multiply_phase==0)?abs_re:(multiply_phase==1)?abs_im:
   (multiply_phase==2)?m_energy:{{(CROSS_W-17){1'b0}},threshold};
 wire mul_ready,mul_valid;
 wire[MUL_W-1:0]mul_product;
 img_hist_serial_multiply #(.A_W(MUL_A_W),.B_W(CROSS_W)) wide_product(
   .clk(clk),.rst_n(helper_rst_n),.clk_en(1'b1),
   .s_valid(!rst &&helper_rst_n &&state==MUL_ISSUE),.s_ready(mul_ready),.s_a(mul_a),.s_b(mul_b),
   .m_valid(mul_valid),.m_ready(!rst &&state==MUL_WAIT),.m_product(mul_product));
 wire[MUL_W-1:0]numerator_wide={{(MUL_W-NUM_W){1'b0}},numerator};
 wire[MUL_W-1:0]energy_square_wide={{(MUL_W-SQ_W){1'b0}},energy_squared};
 wire metric_bad=(numerator_wide<<2)>energy_square_wide;
 // M=4|P|²/E² >= T/65536  <=>  |P|²*2^18 >= T*E².
 // MUL_W >= NUM_W+18 for every supported DATA_W/L, so this shift is exact.
 wire qualifies=(numerator_wide<<18)>=threshold_product;
 task clear_statistics;
   begin m_energy<=0;m_cross_re<=0;m_cross_im<=0;m_qual<=0;m_event<=0;m_event_start<=0;end
 endtask
 task arithmetic_abort;
   begin
     m_status<=6;m_last<=1;m_end<=sample_index;
     m_start<=(sample_index>=2*L-1)?sample_index-(2*L-1):0;
     clear_statistics();helper_flush<=1;state<=FAULT_RESET;
   end
 endtask
 always @(posedge clk)begin
   if(rst)begin
     state<=IDLE;lag_pointer<=0;energy_pointer<=0;sample_index<=0;length<=0;
     sample_word<=0;delayed_word<=0;old_power<=0;new_power<=0;old_product<=0;new_re<=0;new_im<=0;
     energy<=0;min_energy<=0;cross_re<=0;cross_im<=0;threshold<=0;hold_windows<=0;run_count<=0;
     run_start<=0;tag<=0;received<=0;multiply_phase<=0;numerator<=0;energy_squared<=0;threshold_product<=0;
     helper_flush<=0;m_status<=0;m_end<=0;m_start<=0;m_event_start<=0;m_qual<=0;m_event<=0;
     m_last<=0;m_energy<=0;m_cross_re<=0;m_cross_im<=0;
   end else case(state)
     IDLE:if(c_valid &&c_ready)begin
       tag<=c_tag;length<=c_samples[NW-1:0];threshold<=c_threshold_q16[16:0];
       hold_windows<=c_hold[6:0];min_energy<=c_min_energy[CROSS_W-1:0];
       lag_pointer<=0;energy_pointer<=0;sample_index<=0;energy<=0;cross_re<=0;cross_im<=0;
       run_count<=0;run_start<=0;m_end<=0;m_start<=0;m_status<=0;m_last<=0;clear_statistics();
       if(c_samples<2*L ||c_samples>MAX_SAMPLES)begin m_status<=1;m_last<=1;state<=OUTPUT;end
       else if(c_threshold_q16==0 ||c_threshold_q16>65536)begin m_status<=2;m_last<=1;state<=OUTPUT;end
       else if(c_hold==0 ||c_hold>64)begin m_status<=3;m_last<=1;state<=OUTPUT;end
       else if((c_min_energy>>CROSS_W)!=0)begin m_status<=4;m_last<=1;state<=OUTPUT;end
       else state<=LOAD;
     end
     LOAD:if(s_valid &&s_ready)begin
       if(s_last!=(sample_index==length-1'b1))begin
         m_status<=5;m_end<=sample_index;m_start<=(sample_index>=2*L-1)?sample_index-(2*L-1):0;
         m_last<=1;clear_statistics();state<=OUTPUT;
       end else begin sample_word<=s_iq;received<=0;state<=READ;end
     end
     READ:begin
       delayed_word<=(sample_index>=L)?delay_ram[lag_pointer]:{(2*DATA_W){1'b0}};
       old_product<=(sample_index>=2*L)?product_ram[lag_pointer]:{(2*TERM_W){1'b0}};
       old_power<=(sample_index>=2*L)?power_ram[energy_pointer]:{POWER_W{1'b0}};
       state<=ISSUE_POWER;
     end
     ISSUE_POWER:if(mac_ready)state<=ISSUE_CROSS;
     ISSUE_CROSS:if(mac_ready)state<=WAIT_PRODUCTS;
     WAIT_PRODUCTS:if(mac_valid)begin
       if(mac_flags!=0 ||(!received &&(term_im!=0 ||term_re[TERM_W-1])))arithmetic_abort();
       else if(!received)begin new_power<=term_re[POWER_W-1:0];received<=1;end
       else begin new_re<=term_re;new_im<=term_im;state<=UPDATE;end
     end
     UPDATE:begin
       if(sum_bad)arithmetic_abort();
       else begin
         cross_re<=acc_re[CROSS_W-1:0];cross_im<=acc_im[CROSS_W-1:0];
         energy<=acc_energy[CROSS_W-1:0];state<=WRITE;
       end
     end
     WRITE:begin
       delay_ram[lag_pointer]<=sample_word;product_ram[lag_pointer]<={new_im,new_re};
       power_ram[energy_pointer]<=new_power;
       lag_pointer<=(lag_pointer==L-1)?{LPW{1'b0}}:lag_pointer+1'b1;
       energy_pointer<=(energy_pointer==2*L-1)?{EPW{1'b0}}:energy_pointer+1'b1;
       if(sample_index<2*L-1)begin sample_index<=sample_index+1'b1;state<=LOAD;end
       else begin
         m_end<=sample_index;m_start<=sample_index-(2*L-1);m_last<=(sample_index==length-1'b1);
         m_status<=0;m_energy<=energy;m_cross_re<=cross_re;m_cross_im<=cross_im;
         m_event_start<=0;m_qual<=0;m_event<=0;
         if(energy==0)begin m_status<=7;run_count<=0;state<=OUTPUT;end
         else if(energy<min_energy)begin run_count<=0;state<=OUTPUT;end
         else begin multiply_phase<=0;state<=MUL_ISSUE;end
       end
     end
     MUL_ISSUE:if(mul_ready)state<=MUL_WAIT;
     MUL_WAIT:if(mul_valid)begin
       if(multiply_phase<3 &&(|mul_product[MUL_W-1:SQ_W]))arithmetic_abort();
       else begin
         case(multiply_phase)
           0:numerator<={1'b0,mul_product[SQ_W-1:0]};
           1:numerator<=numerator+{1'b0,mul_product[SQ_W-1:0]};
           2:energy_squared<=mul_product[SQ_W-1:0];
           3:threshold_product<=mul_product;
         endcase
         if(multiply_phase==3)state<=DECIDE;
         else begin multiply_phase<=multiply_phase+1'b1;state<=MUL_ISSUE;end
       end
     end
     DECIDE:begin
       if(metric_bad ||energy_squared==0)arithmetic_abort();
       else begin
         m_qual<=qualifies;
         if(qualifies)begin
           if(run_count==0)run_start<=m_start;
           if(run_count<hold_windows)run_count<=run_count+1'b1;
           if(run_count==hold_windows-1'b1)begin
             m_event<=1;m_event_start<=(run_count==0)?m_start:run_start;
           end
         end else run_count<=0;
         state<=OUTPUT;
       end
     end
     OUTPUT:if(m_ready)begin
       if(m_last)state<=IDLE;
       else begin sample_index<=sample_index+1'b1;state<=LOAD;end
     end
     FAULT_RESET:begin helper_flush<=0;state<=FAULT_RECOVER;end
     FAULT_RECOVER:if(helper_rst_n)state<=OUTPUT;
     default:state<=IDLE;
   endcase
 end
 generate if(DATA_W<8 ||DATA_W>16 ||L<1 ||L>64 ||MAX_SAMPLES<2*L ||MAX_SAMPLES>4096 ||TAG_W<1 ||TAG_W>32)begin:bad_parameters
   repeated_half_sync_invalid_parameters__see_README invalid();
 end endgenerate
endmodule
