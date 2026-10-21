// Directed DP3 stitching seam, complete traceback and raster feather mask.
module seam_find(
 input wire clk,rst_n,ce,
 input wire cfg_valid,output wire cfg_ready,input wire[5:0]cfg_width,cfg_height,
 input wire cfg_horizontal,input wire[7:0]cfg_gradient_weight,input wire[5:0]cfg_feather,
 output reg cfg_done,cfg_error,
 input wire start_valid,output wire start_ready,input wire abort,
 input wire[7:0]s_a,s_b,input wire s_valid,s_sof,s_eol,s_last,output wire s_ready,
 output reg[7:0]m_mask,output reg m_valid,m_sof,m_eol,m_last,m_is_seam,input wire m_ready,
 output wire[191:0]seam_coordinates,output wire[5:0]seam_length,
 output reg[31:0]total_cost,output reg done_valid,input wire done_ready,
 output reg[3:0]error_code,output wire busy
);
 localparam IDLE=0,CAP=1,PIXEL=2,CR=3,CV=4,LR=5,LV=6,UR=7,UV=8,
  COST=9,CMUL=10,DP=11,DR=12,DV=13,DNEXT=14,SAVE=15,ADVANCE=16,
  ENDPOINT=17,TRACE=18,TR=19,TV=20,OUTADDR=21,OUTREAD=22,MASK=23,
  DIVIDE=24,OUTVAL=25,OUTPUT=26,DONE=27;
 reg[4:0]state;
 reg configured,horizontal;
 reg[5:0]width,height,feather;
 reg[7:0]gradient_weight;
 reg[5:0]px,py,step,position,end_position,trace_step,trace_position;
 wire[5:0]long_size=horizontal?width:height,short_size=horizontal?height:width;
 wire[5:0]x=horizontal?step:position,y=horizontal?position:step;
 wire[9:0]pixel_addr=y*width+x;
 wire[9:0]input_addr=py*width+px;
 reg[15:0]frame_mem[0:1023],frame_q,center,left_pixel,up_pixel;
 reg[9:0]frame_addr;
 reg[23:0]row0[0:31],row1[0:31],r0q,r1q;
 reg[4:0]dp_addr;
 wire[23:0]previous=step[0]?r0q:r1q;
 reg[1:0]predecessor[0:1023],pred_q;
 reg[9:0]pred_addr;
 reg[5:0]seam[0:31],seam_q;
 genvar g;
 generate for(g=0;g<32;g=g+1)begin:COORDS assign seam_coordinates[g*6+:6]=seam[g];end endgenerate
 assign seam_length=long_size;
 reg[1:0]neighbor,best_predecessor;
 reg[5:0]neighbor_position;
 reg[23:0]best_previous,end_cost;
 reg[17:0]pixel_cost,mul_acc,mul_shift;
 reg[7:0]mul_factor;
 reg[3:0]bit_index;
 reg[7:0]base_cost;
 wire signed[8:0]base_difference=$signed({1'b0,center[15:8]})-$signed({1'b0,center[7:0]});
 wire[8:0]base_abs=base_difference<0?-base_difference:base_difference;
 wire signed[9:0]gx=$signed({2'b0,center[15:8]})-$signed({2'b0,left_pixel[15:8]})-
  $signed({2'b0,center[7:0]})+$signed({2'b0,left_pixel[7:0]});
 wire signed[9:0]gy=$signed({2'b0,center[15:8]})-$signed({2'b0,up_pixel[15:8]})-
  $signed({2'b0,center[7:0]})+$signed({2'b0,up_pixel[7:0]});
 wire[9:0]gx_abs=gx<0?-gx:gx,gy_abs=gy<0?-gy:gy;
 wire[10:0]gradient={1'b0,gx_abs}+{1'b0,gy_abs};
 wire[17:0]mul_next=mul_acc+(mul_factor[0]?mul_shift:18'd0);
 wire[24:0]cumulative={1'b0,best_previous}+{7'd0,pixel_cost};
 reg[15:0]quotient;
 reg[7:0]remainder;
 reg[6:0]divisor;
 wire[8:0]trial={remainder,quotient[15]};
 wire take=trial>={2'd0,divisor};
 wire[15:0]quotient_next={quotient[14:0],take};
 wire[5:0]transverse=horizontal?py:px;
 wire signed[7:0]distance=$signed({2'd0,transverse})-$signed({2'd0,seam_q});
 wire signed[8:0]mask_span=$signed({3'd0,feather})-$signed(distance);
 wire[15:0]mask_numerator=($unsigned(mask_span)<<8)-$unsigned(mask_span)+feather;
 assign cfg_ready=rst_n&&ce&&state==IDLE;
 assign start_ready=cfg_ready&&configured&&!cfg_valid&&!abort;
 assign s_ready=rst_n&&ce&&state==CAP&&!abort;
 assign busy=state!=IDLE&&state!=DONE;
 integer n;
 always @(posedge clk)if(ce)begin
  frame_q<=frame_mem[frame_addr];r0q<=row0[dp_addr];r1q<=row1[dp_addr];pred_q<=predecessor[pred_addr];
  seam_q<=seam[horizontal?px:py];
 end
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=IDLE;configured<=0;width<=1;height<=1;horizontal<=0;feather<=0;gradient_weight<=0;
   cfg_done<=0;cfg_error<=0;m_valid<=0;m_mask<=0;m_sof<=0;m_eol<=0;m_last<=0;m_is_seam<=0;
   total_cost<=0;done_valid<=0;error_code<=0;px<=0;py<=0;frame_addr<=0;dp_addr<=0;pred_addr<=0;
   for(n=0;n<32;n=n+1)seam[n]<=0;
  end else if(ce)begin
   cfg_done<=0;cfg_error<=0;
   if(abort&&state!=IDLE&&state!=DONE)begin error_code<=3;m_valid<=0;done_valid<=1;state<=DONE;end
   else case(state)
    IDLE:if(cfg_valid)begin
     if(cfg_width==0||cfg_width>32||cfg_height==0||cfg_height>32||cfg_feather>32)cfg_error<=1;
     else begin width<=cfg_width;height<=cfg_height;horizontal<=cfg_horizontal;
      gradient_weight<=cfg_gradient_weight;feather<=cfg_feather;configured<=1;cfg_done<=1;end
    end else if(start_valid&&start_ready)begin
     px<=0;py<=0;error_code<=0;total_cost<=0;state<=CAP;
     for(n=0;n<32;n=n+1)seam[n]<=0;
    end
    CAP:if(s_valid)begin
     if(s_sof!=(px==0&&py==0)||s_eol!=(px==width-1)||s_last!=(px==width-1&&py==height-1))begin
      error_code<=1;done_valid<=1;state<=DONE;
     end else begin
      frame_mem[input_addr]<={s_a,s_b};
      if(px==width-1)begin px<=0;if(py==height-1)begin py<=0;step<=0;position<=0;end_cost<=24'hffffff;end_position<=0;state<=PIXEL;end else py<=py+1'b1;end
      else px<=px+1'b1;
     end
    end
    PIXEL:begin frame_addr<=pixel_addr;state<=CR;end
    CR:state<=CV;
    CV:begin center<=frame_q;frame_addr<=x==0?pixel_addr:pixel_addr-1'b1;state<=LR;end
    LR:state<=LV;
    LV:begin left_pixel<=frame_q;frame_addr<=y==0?pixel_addr:pixel_addr-width;state<=UR;end
    UR:state<=UV;
    UV:begin up_pixel<=frame_q;state<=COST;end
    COST:begin mul_acc<=0;mul_shift<={7'd0,gradient};mul_factor<=gradient_weight;base_cost<=base_abs[7:0];bit_index<=0;state<=CMUL;end
    CMUL:begin
     mul_acc<=mul_next;mul_shift<=mul_shift<<1;mul_factor<=mul_factor>>1;
     if(bit_index==7)begin pixel_cost<=mul_next+base_cost;
      if(step==0)begin best_previous<=0;best_predecessor<=1;state<=SAVE;end
      else begin best_previous<=24'hffffff;best_predecessor<=1;neighbor<=0;state<=DP;end
     end else bit_index<=bit_index+1'b1;
    end
    DP:if((neighbor==0&&position==0)||(neighbor==2&&position==short_size-1))state<=DNEXT;
     else begin dp_addr<=neighbor==0?position-1'b1:neighbor==1?position:position+1'b1;state<=DR;end
    DR:state<=DV;
    DV:begin if(previous<best_previous)begin best_previous<=previous;best_predecessor<=neighbor;end state<=DNEXT;end
    DNEXT:if(neighbor==2)state<=SAVE;else begin neighbor<=neighbor+1'b1;state<=DP;end
    SAVE:if(cumulative[24])begin error_code<=2;done_valid<=1;state<=DONE;end
     else begin
      if(step[0])row1[position[4:0]]<=cumulative[23:0];else row0[position[4:0]]<=cumulative[23:0];
      predecessor[pixel_addr]<=best_predecessor;
      if(step==long_size-1&&cumulative[23:0]<end_cost)begin end_cost<=cumulative[23:0];end_position<=position;end
      state<=ADVANCE;
     end
    ADVANCE:if(position==short_size-1)begin position<=0;if(step==long_size-1)state<=ENDPOINT;else begin step<=step+1'b1;state<=PIXEL;end end
     else begin position<=position+1'b1;state<=PIXEL;end
    ENDPOINT:begin total_cost<={8'd0,end_cost};trace_step<=long_size-1'b1;trace_position<=end_position;state<=TRACE;end
    TRACE:begin
     seam[trace_step[4:0]]<=trace_position;
     if(trace_step==0)begin px<=0;py<=0;state<=OUTADDR;end
     else begin pred_addr<=horizontal?trace_position*width+trace_step:trace_step*width+trace_position;state<=TR;end
    end
    TR:state<=TV;
    TV:begin trace_step<=trace_step-1'b1;
     case(pred_q)0:trace_position<=trace_position-1'b1;2:trace_position<=trace_position+1'b1;default:trace_position<=trace_position;endcase
     state<=TRACE;
    end
    OUTADDR:state<=OUTREAD;
    OUTREAD:state<=MASK;
    MASK:begin
     m_sof<=px==0&&py==0;m_eol<=px==width-1;m_last<=px==width-1&&py==height-1;m_is_seam<=transverse==seam_q;
     if(feather==0)begin m_mask<=transverse<=seam_q?255:0;state<=OUTVAL;end
     else if(distance<=-$signed({2'd0,feather}))begin m_mask<=255;state<=OUTVAL;end
     else if(distance>=$signed({2'd0,feather}))begin m_mask<=0;state<=OUTVAL;end
     else begin quotient<=mask_numerator;divisor<={feather,1'b0};remainder<=0;bit_index<=0;state<=DIVIDE;end
    end
    DIVIDE:begin quotient<=quotient_next;remainder<=take?trial-{2'd0,divisor}:trial;
     if(bit_index==15)begin m_mask<=quotient_next[7:0];state<=OUTVAL;end else bit_index<=bit_index+1'b1;
    end
    OUTVAL:begin m_valid<=1;state<=OUTPUT;end
    OUTPUT:if(m_ready)begin m_valid<=0;
     if(m_last)begin done_valid<=1;state<=DONE;end
     else if(px==width-1)begin px<=0;py<=py+1'b1;state<=OUTADDR;end else begin px<=px+1'b1;state<=OUTADDR;end
    end
    DONE:if(done_ready)begin done_valid<=0;state<=IDLE;end
    default:begin error_code<=4;m_valid<=0;done_valid<=1;state<=DONE;end
   endcase
  end
 end
endmodule
