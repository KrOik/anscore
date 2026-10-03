module goertzel_mul48(input wire clk,rst_n,start,input wire signed[47:0] a,b,
 output reg done,output reg signed[95:0] result);
 reg busy,negative;reg[5:0] count;reg[95:0] multiplicand,acc;reg[47:0] multiplier;
 wire[95:0] next_acc=acc+(multiplier[0] ? multiplicand:96'd0);
 always @(posedge clk)begin
  if(!rst_n)begin busy<=0;done<=0;result<=0;negative<=0;count<=0;multiplicand<=0;multiplier<=0;acc<=0;end
  else begin done<=0;
   if(start && !busy)begin busy<=1;negative<=a[47]^b[47];count<=0;acc<=0;
    multiplicand<={48'd0,(a[47] ? -a:a)};multiplier<=b[47] ? -b:b;
   end else if(busy)begin
    acc<=next_acc;multiplicand<=multiplicand<<1;multiplier<=multiplier>>1;count<=count+1'b1;
    if(count==47)begin result<=negative ? -next_acc:next_acc;done<=1;busy<=0;end
   end
  end
 end
endmodule

module goertzel_bank(
 input wire clk,rst_n,input wire signed[15:0] s_tdata,input wire s_tvalid,output wire s_tready,
 output reg[79:0] m_power,output reg[1:0] m_bin,output reg m_last,m_detect,m_error,m_valid,input wire m_ready,
 input wire cfg_valid,output wire cfg_ready,input wire[8:0] cfg_n,input wire[2:0] cfg_bins,
 input wire[75:0] cfg_coeffs,input wire[4095:0] cfg_window,input wire[319:0] cfg_thresholds,
 output reg cfg_done,cfg_error
);
 localparam WAIT=0,WS=1,WW=2,RS=3,RW=4,AS=5,AW=6,BS=7,BW=8,CS=9,CW=10,DS=11,DW=12,OUT=13;
 reg[3:0] state;reg[8:0] n,index;reg[2:0] nbins;reg[1:0] bin_i;
 reg signed[18:0] coeff[0:3];reg[15:0] window[0:255];reg[79:0] threshold[0:3];
 reg signed[39:0] s1[0:3],s2[0:3];reg signed[15:0] sample;reg signed[39:0] wx;
 reg signed[47:0] terminal_c;reg signed[95:0] power_sum;reg block_error;
 assign cfg_ready=rst_n && state==WAIT && index==0 && !m_valid;
 assign s_tready=rst_n && state==WAIT && !(cfg_valid && index==0);
 wire start=state==WS || state==RS || state==AS || state==BS || state==CS || state==DS;
 reg signed[47:0] ma,mb;
 always @* begin
  ma=0;mb=0;
  case(state)
   WS:begin ma=sample;mb=$signed({1'b0,window[index]});end
   RS,CS:begin ma=coeff[bin_i];mb=s1[bin_i];end
   AS:begin ma=s1[bin_i];mb=s1[bin_i];end
   BS:begin ma=s2[bin_i];mb=s2[bin_i];end
   DS:begin ma=terminal_c;mb=s2[bin_i];end
  endcase
 end
 wire mdone;wire signed[95:0] product;
 goertzel_mul48 multiplier(clk,rst_n,start,ma,mb,mdone,product);
 function signed[95:0] round16;input signed[95:0] x;reg signed[95:0] q;
 begin q=x>>>16;if(x[15:0]>32768 || (x[15:0]==32768 && q[0]))q=q+1;round16=q;end endfunction
 function signed[95:0] round15;input signed[95:0] x;reg signed[95:0] q;
 begin q=x>>>15;if(x[14:0]>16384 || (x[14:0]==16384 && q[0]))q=q+1;round15=q;end endfunction
 wire signed[95:0] recur=round16(product)+wx-s2[bin_i];
 wire signed[95:0] terminal=power_sum-product;
 wire[79:0] clipped_power=terminal<0 ? 80'd0 : (|terminal[95:80]) ? {80{1'b1}} : terminal[79:0];
 reg bad;integer k;
 always @*begin
  bad=cfg_n<1 || cfg_n>256 || cfg_bins<1 || cfg_bins>4;
  for(k=0;k<4;k=k+1)if(k<cfg_bins && ($signed(cfg_coeffs[k*19+:19]) < -131072 || $signed(cfg_coeffs[k*19+:19])>131072))bad=1;
  for(k=0;k<256;k=k+1)if(k<cfg_n && cfg_window[k*16+:16]>32768)bad=1;
 end
 integer i;
 always @(posedge clk)begin
  if(!rst_n)begin
   state<=WAIT;n<=1;index<=0;nbins<=1;bin_i<=0;sample<=0;wx<=0;terminal_c<=0;power_sum<=0;block_error<=0;
   m_power<=0;m_bin<=0;m_last<=0;m_detect<=0;m_error<=0;m_valid<=0;cfg_done<=0;cfg_error<=0;
   for(i=0;i<4;i=i+1)begin coeff[i]<=19'sd131072;threshold[i]<=0;s1[i]<=0;s2[i]<=0;end
   for(i=0;i<256;i=i+1)window[i]<=16'd32768;
  end else begin
   cfg_done<=0;cfg_error<=0;
   if(cfg_valid && cfg_ready)begin
    cfg_done<=1;cfg_error<=bad;
    if(!bad)begin
     n<=cfg_n;nbins<=cfg_bins;block_error<=0;
     for(i=0;i<4;i=i+1)begin coeff[i]<=cfg_coeffs[i*19+:19];threshold[i]<=cfg_thresholds[i*80+:80];s1[i]<=0;s2[i]<=0;end
     for(i=0;i<256;i=i+1)window[i]<=cfg_window[i*16+:16];
    end
   end else case(state)
    WAIT:if(s_tvalid && s_tready)begin sample<=s_tdata;bin_i<=0;state<=WS;end
    WS:state<=WW;
    WW:if(mdone)begin wx<=round15(product);state<=RS;end
    RS:state<=RW;
    RW:if(mdone)begin
     s2[bin_i]<=s1[bin_i];
     if(recur>96'sd549755813887)begin s1[bin_i]<=40'sh7fffffffff;block_error<=1;end
     else if(recur < -96'sd549755813888)begin s1[bin_i]<=40'sh8000000000;block_error<=1;end
     else s1[bin_i]<=recur[39:0];
     if(bin_i+1<nbins)begin bin_i<=bin_i+1'b1;state<=RS;end
     else if(index+1<n)begin index<=index+1'b1;state<=WAIT;end
     else begin bin_i<=0;state<=AS;end
    end
    AS:state<=AW;
    AW:if(mdone)begin power_sum<=product;state<=BS;end
    BS:state<=BW;
    BW:if(mdone)begin power_sum<=power_sum+product;state<=CS;end
    CS:state<=CW;
    CW:if(mdone)begin terminal_c<=round16(product);state<=DS;end
    DS:state<=DW;
    DW:if(mdone)begin
     m_power<=clipped_power;m_bin<=bin_i;m_last<=bin_i+1==nbins;m_detect<=clipped_power>=threshold[bin_i];
     m_error<=block_error || terminal<0 || (|terminal[95:80]);
     if(terminal<0 || (|terminal[95:80]))block_error<=1;
     m_valid<=1;state<=OUT;
    end
    OUT:if(m_ready)begin
     m_valid<=0;
     if(bin_i+1<nbins)begin bin_i<=bin_i+1'b1;state<=AS;end
     else begin state<=WAIT;index<=0;bin_i<=0;block_error<=0;for(i=0;i<4;i=i+1)begin s1[i]<=0;s2[i]<=0;end end
    end
   endcase
  end
 end
endmodule
