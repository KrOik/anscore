// SPDX-License-Identifier: Apache-2.0
// Finite aligned burst: qualify the repeated prefix, then correct/replay all IQ.
module burst_cfo_correct #(
 parameter integer MAX_SAMPLES=256,TAG_W=8
)(
 input wire clk,rst,c_valid,output wire c_ready,
 input wire[31:0]c_samples,c_threshold_q16,input wire[63:0]c_min_energy,
 input wire[TAG_W-1:0]c_tag,
 input wire s_valid,output wire s_ready,input wire[23:0]s_iq,input wire s_last,
 output wire m_valid,input wire m_ready,output reg[3:0]m_status,
 output reg[23:0]m_iq,output reg[31:0]m_index,output reg m_last,
 output wire[TAG_W-1:0]m_tag,output reg[1:0]m_clip,
 output wire[23:0]m_phase,output wire[31:0]m_correction
);
 localparam integer AW=$clog2(MAX_SAMPLES),NW=$clog2(MAX_SAMPLES+1);
 localparam[3:0]IDLE=0,ARM=1,CAPTURE=2,WAIT_ESTIMATE=3,READ=4,
   COEFF_SEND=5,COEFF_WAIT=6,MUL_SEND=7,MUL_WAIT=8,SUM=9,
   QUANTIZE=10,OUTPUT=11,FLUSH=12,RECOVER=13;
 reg[3:0]state;
 reg[23:0]burst_ram[0:MAX_SAMPLES-1];
 reg[AW-1:0]capture_index,replay_index;
 reg[NW-1:0]length;
 reg[31:0]threshold;
 reg[63:0]min_energy;
 reg[TAG_W-1:0]tag;
 reg[23:0]sample_word,estimated_phase;
 reg[31:0]correction,rotation_phase;
 reg estimate_done;
 reg[3:0]estimate_status;
 wire helper_reset=rst ||state==FLUSH;
 reg multiply_rst_n;
 // Async-low helper reset changes only as a consequence of a rising edge.
 always @(posedge clk)begin
   if(helper_reset)multiply_rst_n<=0;else multiply_rst_n<=1;
 end
 assign c_ready=!rst &&multiply_rst_n &&state==IDLE;
 assign m_valid=!rst &&state==OUTPUT;
 assign m_tag=tag;assign m_phase=estimated_phase;assign m_correction=correction;
 wire prefix_c_ready,prefix_ready,prefix_valid,prefix_qual,prefix_zero;
 wire[2:0]prefix_status;
 wire[23:0]prefix_phase;
 wire[31:0]unused_end,unused_start,unused_event_start;
 wire unused_event,unused_last;
 wire[7:0]unused_tag;
 wire expected_last=capture_index==length-1'b1;
 wire last_bad=s_last!=expected_last;
 assign s_ready=!rst &&state==CAPTURE &&((capture_index<32)?prefix_ready:1'b1);
 sync12_phase prefix(
   .clk(clk),.rst(helper_reset),.c_valid(!rst &&state==ARM),.c_ready(prefix_c_ready),
   .c_samples(32'd32),.c_threshold_q16(threshold),.c_hold(32'd1),
   .c_min_energy(min_energy),.c_tag(8'd0),
   .s_valid(!rst &&state==CAPTURE &&capture_index<32 &&s_valid &&!last_bad),
   .s_ready(prefix_ready),.s_iq(s_iq),.s_last(capture_index==31),
   .m_valid(prefix_valid),.m_ready(!rst &&!estimate_done &&(state==CAPTURE ||state==WAIT_ESTIMATE)),
   .m_status(prefix_status),.m_end(unused_end),.m_start(unused_start),
   .m_event_start(unused_event_start),.m_qual(prefix_qual),.m_event(unused_event),
   .m_last(unused_last),.m_tag(unused_tag),.m_phase(prefix_phase),.m_zero(prefix_zero));
 wire signed[23:0]signed_prefix_phase=prefix_phase;
 wire branch_boundary=signed_prefix_phase>=24'sd8388604 ||signed_prefix_phase<=-24'sd8388604;
 wire[31:0]wide_phase={{8{prefix_phase[23]}},prefix_phase};
 wire coeff_ready,coeff_valid;
 wire signed[17:0]coeff_cos_out,coeff_sin_out;
 wire unused_coeff_tag;
 reg signed[17:0]cos_coeff,sin_coeff;
 stream_sincos #(.PHASE_W(32),.OUT_W(18),.ITER(24),.TAG_W(1)) coefficients(
   .clk(clk),.rst(helper_reset),.s_valid(!rst &&state==COEFF_SEND),.s_ready(coeff_ready),
   .s_phase(rotation_phase),.s_tag(1'b0),.m_valid(coeff_valid),
   .m_ready(!rst &&state==COEFF_WAIT),.m_cos(coeff_cos_out),.m_sin(coeff_sin_out),.m_tag(unused_coeff_tag));
 reg[1:0]multiply_phase;
 wire signed[11:0]rx_re=sample_word[11:0],rx_im=sample_word[23:12];
 wire signed[11:0]selected_sample=(multiply_phase==0 ||multiply_phase==2)?rx_re:rx_im;
 wire signed[17:0]selected_coeff=(multiply_phase==0 ||multiply_phase==3)?cos_coeff:sin_coeff;
 wire[11:0]sample_magnitude=selected_sample[11]?(~selected_sample+12'd1):selected_sample;
 wire[17:0]coeff_magnitude=selected_coeff[17]?(~selected_coeff+18'd1):selected_coeff;
 reg product_negative;
 wire multiply_ready,multiply_valid;
 wire[29:0]multiply_product;
 img_hist_serial_multiply #(.A_W(18),.B_W(12)) rotation_product(
   .clk(clk),.rst_n(multiply_rst_n),.clk_en(1'b1),
   .s_valid(!rst &&state==MUL_SEND),.s_ready(multiply_ready),
   .s_a(coeff_magnitude),.s_b(sample_magnitude),.m_valid(multiply_valid),
   .m_ready(!rst &&state==MUL_WAIT),.m_product(multiply_product));
 wire signed[30:0]positive_product=$signed({1'b0,multiply_product});
 wire signed[30:0]signed_product=product_negative?-positive_product:positive_product;
 reg signed[30:0]rr,ii,ri,ir;
 reg signed[31:0]sum_re,sum_im;
 function signed[31:0]rne16;
   input signed[31:0]value;reg signed[31:0]floor_value;
   begin
     floor_value=value>>>16;
     if(value[15] &&((|value[14:0]) ||value[16]))floor_value=floor_value+1'b1;
     rne16=floor_value;
   end
 endfunction
 wire signed[31:0]rounded_re=rne16(sum_re),rounded_im=rne16(sum_im);
 wire clip_re=rounded_re>32'sd2047 ||rounded_re< -32'sd2048;
 wire clip_im=rounded_im>32'sd2047 ||rounded_im< -32'sd2048;
 wire[11:0]quant_re=(rounded_re>2047)?12'h7ff:(rounded_re< -2048)?12'h800:rounded_re[11:0];
 wire[11:0]quant_im=(rounded_im>2047)?12'h7ff:(rounded_im< -2048)?12'h800:rounded_im[11:0];
 task error_marker;
   input[3:0]status;input[31:0]index;
   begin
     m_status<=status;m_index<=index;m_iq<=0;m_last<=1;m_clip<=0;
     estimated_phase<=0;correction<=0;
   end
 endtask
 always @(posedge clk)begin
   if(rst)begin
     state<=IDLE;capture_index<=0;replay_index<=0;length<=0;threshold<=0;min_energy<=0;tag<=0;
     sample_word<=0;estimated_phase<=0;correction<=0;rotation_phase<=0;
     estimate_done<=0;estimate_status<=0;cos_coeff<=0;sin_coeff<=0;
     multiply_phase<=0;product_negative<=0;rr<=0;ii<=0;ri<=0;ir<=0;sum_re<=0;sum_im<=0;
     m_status<=0;m_index<=0;m_iq<=0;m_last<=0;m_clip<=0;
   end else begin
     if(prefix_valid &&!estimate_done &&(state==CAPTURE ||state==WAIT_ESTIMATE))begin
       estimate_done<=1;estimated_phase<=prefix_phase;correction<=-(wide_phase<<4);
       if(prefix_status!=0 &&prefix_status!=7)estimate_status<=8;
       else if(prefix_status==7 ||prefix_zero)estimate_status<=5;
       else if(!prefix_qual)estimate_status<=6;
       else if(branch_boundary)estimate_status<=7;
       else estimate_status<=0;
     end
     case(state)
       IDLE:if(c_valid &&c_ready)begin
         tag<=c_tag;length<=c_samples[NW-1:0];threshold<=c_threshold_q16;min_energy<=c_min_energy;
         capture_index<=0;replay_index<=0;estimate_done<=0;estimate_status<=0;rotation_phase<=0;
         error_marker(0,0);
         if(c_samples<32 ||c_samples>MAX_SAMPLES)begin error_marker(1,0);state<=OUTPUT;end
         else if(c_threshold_q16==0 ||c_threshold_q16>65536)begin error_marker(2,0);state<=OUTPUT;end
         else if((c_min_energy>>29)!=0)begin error_marker(3,0);state<=OUTPUT;end
         else state<=ARM;
       end
       ARM:if(prefix_c_ready)state<=CAPTURE;
       CAPTURE:if(s_valid &&s_ready)begin
         if(last_bad)begin error_marker(4,32'(capture_index));state<=FLUSH;end
         else begin
           burst_ram[capture_index]<=s_iq;
           if(expected_last)state<=WAIT_ESTIMATE;
           else capture_index<=capture_index+1'b1;
         end
       end
       WAIT_ESTIMATE:if(estimate_done)begin
         if(estimate_status!=0)begin error_marker(estimate_status,0);state<=OUTPUT;end
         else begin replay_index<=0;rotation_phase<=0;state<=READ;end
       end
       READ:begin sample_word<=burst_ram[replay_index];state<=COEFF_SEND;end
       COEFF_SEND:if(coeff_ready)state<=COEFF_WAIT;
       COEFF_WAIT:if(coeff_valid)begin
         cos_coeff<=coeff_cos_out;sin_coeff<=coeff_sin_out;multiply_phase<=0;state<=MUL_SEND;
       end
       MUL_SEND:if(multiply_ready)begin
         product_negative<=selected_sample[11]^selected_coeff[17];state<=MUL_WAIT;
       end
       MUL_WAIT:if(multiply_valid)begin
         case(multiply_phase)
           0:rr<=signed_product;1:ii<=signed_product;2:ri<=signed_product;3:ir<=signed_product;
         endcase
         if(multiply_phase==3)state<=SUM;
         else begin multiply_phase<=multiply_phase+1'b1;state<=MUL_SEND;end
       end
       SUM:begin
         sum_re<=$signed({rr[30],rr})-$signed({ii[30],ii});
         sum_im<=$signed({ri[30],ri})+$signed({ir[30],ir});state<=QUANTIZE;
       end
       QUANTIZE:begin
         m_iq<={quant_im,quant_re};m_clip<={clip_im,clip_re};m_status<=0;
         m_index<=32'(replay_index);m_last<=replay_index==length-1'b1;state<=OUTPUT;
       end
       OUTPUT:if(m_ready)begin
         if(m_last)state<=IDLE;
         else begin replay_index<=replay_index+1'b1;rotation_phase<=rotation_phase+correction;state<=READ;end
       end
       FLUSH:state<=RECOVER;
       RECOVER:if(multiply_rst_n)state<=OUTPUT;
       default:state<=IDLE;
     endcase
   end
 end
 generate if(MAX_SAMPLES<32 ||MAX_SAMPLES>4096 ||TAG_W<1 ||TAG_W>32)begin:bad_parameters
   burst_cfo_correct_invalid_parameters__see_README invalid();
 end endgenerate
endmodule
