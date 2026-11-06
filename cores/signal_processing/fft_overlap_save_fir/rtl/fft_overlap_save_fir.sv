// Original ANSCORE overlap-save control/datapath. Apache-2.0.
// stream_fft is a separate, unchanged original workspace support source.
module fft_overlap_save_fir #(
 parameter integer LOG_N=6, DATA_W=16, TAG_W=8
)(
 input wire clk,rst,
 input wire g_valid,output wire g_ready,
 input wire [31:0] g_taps,g_frac,input wire [TAG_W-1:0] g_tag,
 input wire k_valid,output wire k_ready,
 input wire signed [DATA_W-1:0] k_re,k_im,
 input wire k_last,k_invalid,
 output wire r_valid,input wire r_ready,
 output wire [3:0] r_status,output wire [31:0] r_taps,r_frac,r_received,
 output wire r_overflow,r_inexact,output wire [TAG_W-1:0] r_tag,
 input wire c_valid,output wire c_ready,
 input wire [31:0] c_count,input wire c_end,c_restart,
 input wire [TAG_W-1:0] c_tag,
 input wire s_valid,output wire s_ready,
 input wire signed [DATA_W-1:0] s_re,s_im,
 input wire s_last,s_invalid,
 output wire m_valid,input wire m_ready,
 output wire signed [DATA_W-1:0] m_re,m_im,
 output wire m_keep,m_last,m_error,output wire [3:0] m_status,
 output wire m_overflow,m_inexact,
 output wire [LOG_N-1:0] m_index,
 output wire [31:0] m_count,m_total,m_received,
 output wire [TAG_W-1:0] m_tag,output wire busy
);
 generate if((LOG_N<1)||(LOG_N>8)||(DATA_W<8)||(DATA_W>24)||(TAG_W<1)||(TAG_W>32))begin:invalid_parameters
  initial $fatal(1,"fft_overlap_save_fir parameter range");
 end endgenerate
 localparam integer N=1<<LOG_N, PW=2*DATA_W+1;
 localparam [LOG_N:0] SIZE=N;
 localparam [LOG_N-1:0] LAST=N-1;
 localparam [5:0] IDLE=0,CFG_LOAD=1,CFG_PAD=2,FEED_REQ=3,FEED_SEND=4,
  COEFF_DRAIN=5,CFG_REPLY=6,CLEAR_HIST=7,DATA_LOAD=8,DATA_PAD=9,
  X_DRAIN=10,MUL_REQ=11,MUL_CAP=12,MUL0=13,MUL1=14,MUL2=15,
  MUL3=16,MUL_JOIN=17,MUL_QUANT=18,I_DRAIN=19,COPY_REQ=20,
  COPY_WRITE=21,MARKER=22,FFT_FLUSH=23;
 localparam [1:0] COEFF=0,FORWARD=1,INVERSE=2;
 localparam [3:0] R_OK=0,R_BAD_TAPS=1,R_BAD_FRAC=2,R_INVALID=3,
  R_EARLY=4,R_MISSING=5,R_FFT=6;
 localparam [3:0] M_OK=0,M_EMPTY=1,M_NO_CFG=2,M_BAD_COUNT=3,
  M_INVALID=4,M_EARLY=5,M_MISSING=6,M_FFT=7;
 reg [5:0] state;
 reg [1:0] job;
 reg configured,history_valid,stream_active;
 reg [LOG_N:0] taps,hop,pending_taps;
 reg [4:0] frac,pending_frac;
 reg coeff_overflow,coeff_inexact,pending_overflow,pending_inexact;
 reg [31:0] cfg_taps_full,cfg_frac_full,cfg_received;
 reg [TAG_W-1:0] cfg_tag,cmd_tag;
 reg [3:0] reply_status,marker_status;
 reg fault_is_cfg;
 reg [31:0] cmd_count,received,total;
 reg cmd_end,cmd_overflow,cmd_inexact;
 reg [LOG_N:0] work_index,input_index,copy_index,remaining,emitted;
 reg [LOG_N-1:0] feed_index,drain_index,mul_index;
 wire [LOG_N:0] history_words=taps-1'b1;
 wire [LOG_N:0] cfg_last_index=pending_taps-1'b1;
 wire cfg_bad_last=k_last!=(input_index==cfg_last_index);
 wire data_bad_last=s_last!=(input_index==cmd_count-1'b1);
 assign g_ready=!rst&&(state==IDLE);
 assign c_ready=!rst&&(state==IDLE)&&!g_valid;
 assign k_ready=!rst&&(state==CFG_LOAD);
 assign s_ready=!rst&&(state==DATA_LOAD);
 assign r_valid=!rst&&(state==CFG_REPLY);
 assign r_status=reply_status;assign r_taps=cfg_taps_full;
 assign r_frac=cfg_frac_full;assign r_received=cfg_received;
 assign r_overflow=(reply_status==R_OK)&&pending_overflow;
 assign r_inexact=(reply_status==R_OK)&&pending_inexact;
 assign r_tag=cfg_tag;assign busy=!rst&&(state!=IDLE);

 wire f_s_ready,f_valid,f_ready,f_keep,f_last,f_error,f_overflow,f_inexact;
 wire signed [DATA_W-1:0] f_re,f_im;
 wire [LOG_N-1:0] f_index,f_scale;
 wire f_inverse;
 wire [TAG_W-1:0] f_tag;
 wire [LOG_N-1:0] wanted_scale=(job==INVERSE)?{LOG_N{1'b1}}:{LOG_N{1'b0}};
 wire [TAG_W-1:0] wanted_tag=(job==COEFF)?cfg_tag:cmd_tag;
 wire drain_bad=!f_keep||f_error||(f_index!=drain_index)||
  (f_last!=(drain_index==LAST))||(f_inverse!=(job==INVERSE))||
  (f_scale!=wanted_scale)||(f_tag!=wanted_tag);
 wire i_window=({1'b0,drain_index}>=history_words)&&(remaining!=0);
 wire emit_valid=(state==I_DRAIN)&&f_valid&&!drain_bad&&i_window;
 assign f_ready=(state==COEFF_DRAIN)||(state==X_DRAIN)||
  ((state==I_DRAIN)&&(!f_valid||drain_bad||!i_window||m_ready));
 assign m_valid=!rst&&((state==MARKER)||emit_valid);
 assign m_keep=(state==I_DRAIN);assign m_last=(state==MARKER)||(remaining==1);
 assign m_error=(state==MARKER)&&(marker_status!=M_EMPTY)&&(marker_status!=M_OK);
 assign m_status=(state==MARKER)?marker_status:M_OK;
 assign m_re=(state==MARKER)?{DATA_W{1'b0}}:f_re;
 assign m_im=(state==MARKER)?{DATA_W{1'b0}}:f_im;
 assign m_overflow=(state==I_DRAIN)&&(cmd_overflow||f_overflow);
 assign m_inexact=(state==I_DRAIN)&&(cmd_inexact||f_inexact);
 assign m_index=(state==MARKER)?{LOG_N{1'b0}}:emitted[LOG_N-1:0];
 assign m_count=cmd_count;assign m_total=(state==MARKER)?32'd0:total;
 assign m_received=received;assign m_tag=cmd_tag;

 reg [2*DATA_W-1:0] time_mem[0:N-1],h_mem[0:N-1],spectral_mem[0:N-1];
 reg [2*DATA_W-1:0] time_read,h_read,spectral_read;
 reg time_we,h_we,spectral_we,time_re,h_re,spectral_re;
 reg [LOG_N-1:0] time_wa,h_wa,spectral_wa,time_ra,h_ra,spectral_ra;
 reg [2*DATA_W-1:0] time_wd,h_wd,spectral_wd;
 wire [2*DATA_W-1:0] feed_word=(job==FORWARD)?time_read:spectral_read;
 stream_fft #(.LOG_N(LOG_N),.DATA_W(DATA_W),.TAG_W(TAG_W)) fft (
  .clk(clk),.rst(rst||(state==FFT_FLUSH)),
  .s_valid((state==FEED_SEND)&&!rst),.s_ready(f_s_ready),
  .s_re(feed_word[2*DATA_W-1:DATA_W]),.s_im(feed_word[DATA_W-1:0]),
  .s_last(feed_index==LAST),.s_inverse(job==INVERSE),
  .s_scale_mask(wanted_scale),.s_tag(wanted_tag),
  .m_valid(f_valid),.m_ready(f_ready),.m_re(f_re),.m_im(f_im),
  .m_keep(f_keep),.m_last(f_last),.m_error(f_error),
  .m_overflow(f_overflow),.m_inexact(f_inexact),
  .m_index(f_index),.m_scale_mask(f_scale),.m_inverse(f_inverse),.m_tag(f_tag));

 reg signed [DATA_W-1:0] xr,xi,hr,hi;
 wire signed [DATA_W-1:0] mul_a=((state==MUL1)||(state==MUL3))?xi:xr;
 wire signed [DATA_W-1:0] mul_b=((state==MUL1)||(state==MUL2))?hi:hr;
 wire signed [2*DATA_W-1:0] real_product=mul_a*mul_b;
 reg signed [2*DATA_W-1:0] product;
 wire signed [PW-1:0] product_ext={product[2*DATA_W-1],product};
 reg signed [PW-1:0] real_acc,imag_acc;
 function [DATA_W+1:0] quantize;
  input signed [PW-1:0] value;
  input [4:0] shift;
  reg signed [PW-1:0] floor_value;
  reg signed [PW:0] rounded,lo,hi_limit;
  reg [PW-1:0] residue,mask,half;
  reg inc,ov,ix;
  reg [DATA_W-1:0] result;
  begin
   floor_value=value>>>shift;
   mask={PW{1'b1}}>>(PW-shift);
   residue=$unsigned(value)&mask;
   half=0;inc=0;
   if(shift!=0)begin
    half={{(PW-1){1'b0}},1'b1}<<(shift-1'b1);
    inc=(residue>half)||((residue==half)&&floor_value[0]);
   end
   rounded=$signed({floor_value[PW-1],floor_value})+$signed({{PW{1'b0}},inc});
   lo=-($signed({{PW{1'b0}},1'b1})<<<(DATA_W-1));hi_limit=-lo-1'b1;
   ov=(rounded<lo)||(rounded>hi_limit);ix=(residue!=0)||ov;
   result=(rounded<lo)?lo[DATA_W-1:0]:(rounded>hi_limit)?hi_limit[DATA_W-1:0]:rounded[DATA_W-1:0];
   quantize={ix,ov,result};
  end
 endfunction
 wire [DATA_W+1:0] qr=quantize(real_acc,frac),qi=quantize(imag_acc,frac);

 always @* begin
  time_we=0;h_we=0;spectral_we=0;time_re=0;h_re=0;spectral_re=0;
  time_wa=0;h_wa=0;spectral_wa=0;time_ra=0;h_ra=0;spectral_ra=0;
  time_wd=0;h_wd=0;spectral_wd=0;
  case(state)
   CFG_LOAD:if(k_valid&&!k_invalid&&!cfg_bad_last)begin
    spectral_we=1;spectral_wa=input_index[LOG_N-1:0];spectral_wd={k_re,k_im};end
   CFG_PAD:begin spectral_we=1;spectral_wa=work_index[LOG_N-1:0];end
   FEED_REQ:if(job==FORWARD)begin time_re=1;time_ra=feed_index;end
    else begin spectral_re=1;spectral_ra=feed_index;end
   COEFF_DRAIN:if(f_valid&&f_ready&&!drain_bad)begin
    h_we=1;h_wa=drain_index;h_wd={f_re,f_im};end
   CLEAR_HIST:begin time_we=1;time_wa=work_index[LOG_N-1:0];end
   DATA_LOAD:if(s_valid&&!s_invalid&&!data_bad_last)begin
    time_we=1;time_wa=history_words+input_index;time_wd={s_re,s_im};end
   DATA_PAD:begin time_we=1;time_wa=work_index[LOG_N-1:0];end
   X_DRAIN:if(f_valid&&f_ready&&!drain_bad)begin
    spectral_we=1;spectral_wa=drain_index;spectral_wd={f_re,f_im};end
   MUL_REQ:begin spectral_re=1;spectral_ra=mul_index;h_re=1;h_ra=mul_index;end
   MUL_QUANT:begin spectral_we=1;spectral_wa=mul_index;
    spectral_wd={qr[DATA_W-1:0],qi[DATA_W-1:0]};end
   COPY_REQ:begin time_re=1;time_ra=hop+copy_index;end
   COPY_WRITE:begin time_we=1;time_wa=copy_index[LOG_N-1:0];time_wd=time_read;end
   default:begin end
  endcase
 end
 always @(posedge clk)if(!rst)begin
  if(time_we)time_mem[time_wa]<=time_wd;
  if(h_we)h_mem[h_wa]<=h_wd;
  if(spectral_we)spectral_mem[spectral_wa]<=spectral_wd;
  if(time_re)time_read<=time_mem[time_ra];
  if(h_re)h_read<=h_mem[h_ra];
  if(spectral_re)spectral_read<=spectral_mem[spectral_ra];
 end

 always @(posedge clk)begin
  if(rst)begin
   state<=IDLE;job<=COEFF;configured<=0;history_valid<=0;stream_active<=0;
   taps<=1;hop<=SIZE;frac<=0;pending_taps<=1;pending_frac<=0;
   coeff_overflow<=0;coeff_inexact<=0;pending_overflow<=0;pending_inexact<=0;
   cfg_taps_full<=0;cfg_frac_full<=0;cfg_received<=0;cfg_tag<=0;cmd_tag<=0;
   reply_status<=R_OK;marker_status<=M_OK;fault_is_cfg<=0;
   cmd_count<=0;received<=0;total<=0;cmd_end<=0;cmd_overflow<=0;cmd_inexact<=0;
   work_index<=0;input_index<=0;copy_index<=0;remaining<=0;emitted<=0;
   feed_index<=0;drain_index<=0;mul_index<=0;
  end else begin
   case(state)
    IDLE:begin
     if(g_valid)begin
      cfg_taps_full<=g_taps;cfg_frac_full<=g_frac;cfg_tag<=g_tag;cfg_received<=0;
      pending_overflow<=0;pending_inexact<=0;reply_status<=R_OK;
      if((g_taps==0)||(g_taps>N))begin reply_status<=R_BAD_TAPS;state<=CFG_REPLY;end
      else if(g_frac>=DATA_W)begin reply_status<=R_BAD_FRAC;state<=CFG_REPLY;end
      else begin pending_taps<=g_taps[LOG_N:0];pending_frac<=g_frac[4:0];
       input_index<=0;state<=CFG_LOAD;end
     end else if(c_valid)begin
      cmd_count<=c_count;cmd_tag<=c_tag;received<=0;emitted<=0;
      cmd_end<=c_end;cmd_overflow<=coeff_overflow;cmd_inexact<=coeff_inexact;
      if(!configured)begin marker_status<=M_NO_CFG;state<=MARKER;end
      else if((!c_end&&(c_count!=hop))||(c_end&&(c_count>hop)))begin
       marker_status<=M_BAD_COUNT;state<=MARKER;end
      else if(c_end&&(c_count==0)&&(c_restart||!stream_active||(taps==1)))begin
       history_valid<=0;stream_active<=0;marker_status<=M_EMPTY;state<=MARKER;end
      else begin
       total<=c_end?(c_count+taps-1'b1):c_count;
       remaining<=c_end?(c_count+taps-1'b1):c_count;input_index<=0;
       if((c_restart||!history_valid)&&(taps!=1))begin work_index<=0;state<=CLEAR_HIST;end
       else if(c_count==0)begin work_index<=history_words;state<=DATA_PAD;end
       else state<=DATA_LOAD;
      end
     end
    end
    CFG_LOAD:if(k_valid)begin
     cfg_received<=cfg_received+1'b1;
     if(k_invalid||cfg_bad_last)begin
      reply_status<=k_invalid?R_INVALID:(k_last?R_EARLY:R_MISSING);state<=CFG_REPLY;
     end else if(input_index==cfg_last_index)begin
      if(pending_taps==SIZE)begin job<=COEFF;feed_index<=0;state<=FEED_REQ;end
      else begin work_index<=pending_taps;state<=CFG_PAD;end
     end else input_index<=input_index+1'b1;
    end
    CFG_PAD:if(work_index==SIZE-1'b1)begin job<=COEFF;feed_index<=0;state<=FEED_REQ;end
     else work_index<=work_index+1'b1;
    FEED_REQ:state<=FEED_SEND;
    FEED_SEND:if(f_s_ready)begin
     if(feed_index==LAST)begin drain_index<=0;
      state<=(job==COEFF)?COEFF_DRAIN:(job==FORWARD)?X_DRAIN:I_DRAIN;end
     else begin feed_index<=feed_index+1'b1;state<=FEED_REQ;end
    end
    COEFF_DRAIN:if(f_valid&&f_ready)begin
     if(drain_bad)begin configured<=0;history_valid<=0;stream_active<=0;
      fault_is_cfg<=1;reply_status<=R_FFT;state<=FFT_FLUSH;end
     else begin
      pending_overflow<=pending_overflow||f_overflow;pending_inexact<=pending_inexact||f_inexact;
      if(drain_index==LAST)begin reply_status<=R_OK;state<=CFG_REPLY;end
      else drain_index<=drain_index+1'b1;
     end
    end
    CFG_REPLY:if(r_ready)begin
     if(reply_status==R_OK)begin
      configured<=1;taps<=pending_taps;hop<=SIZE-pending_taps+1'b1;frac<=pending_frac;
      coeff_overflow<=pending_overflow;coeff_inexact<=pending_inexact;
      history_valid<=0;stream_active<=0;
     end
     state<=IDLE;
    end
    CLEAR_HIST:if(work_index==history_words-1'b1)begin
     if(cmd_count==0)begin work_index<=history_words;state<=DATA_PAD;end
     else state<=DATA_LOAD;
    end else work_index<=work_index+1'b1;
    DATA_LOAD:if(s_valid)begin
     received<=received+1'b1;
     if(s_invalid||data_bad_last)begin
      history_valid<=0;stream_active<=0;
      marker_status<=s_invalid?M_INVALID:(s_last?M_EARLY:M_MISSING);state<=MARKER;
     end else if(input_index==cmd_count-1'b1)begin
      if(history_words+cmd_count==N)begin job<=FORWARD;feed_index<=0;state<=FEED_REQ;end
      else begin work_index<=history_words+cmd_count;state<=DATA_PAD;end
     end else input_index<=input_index+1'b1;
    end
    DATA_PAD:if(work_index==SIZE-1'b1)begin job<=FORWARD;feed_index<=0;state<=FEED_REQ;end
     else work_index<=work_index+1'b1;
    X_DRAIN:if(f_valid&&f_ready)begin
     if(drain_bad)begin history_valid<=0;stream_active<=0;
      fault_is_cfg<=0;marker_status<=M_FFT;state<=FFT_FLUSH;end
     else begin
      cmd_overflow<=cmd_overflow||f_overflow;cmd_inexact<=cmd_inexact||f_inexact;
      if(drain_index==LAST)begin mul_index<=0;state<=MUL_REQ;end
      else drain_index<=drain_index+1'b1;
     end
    end
    MUL_REQ:state<=MUL_CAP;
    MUL_CAP:begin xr<=spectral_read[2*DATA_W-1:DATA_W];xi<=spectral_read[DATA_W-1:0];
     hr<=h_read[2*DATA_W-1:DATA_W];hi<=h_read[DATA_W-1:0];state<=MUL0;end
    MUL0:begin product<=real_product;state<=MUL1;end
    MUL1:begin product<=real_product;real_acc<=product_ext;state<=MUL2;end
    MUL2:begin product<=real_product;real_acc<=real_acc-product_ext;state<=MUL3;end
    MUL3:begin product<=real_product;imag_acc<=product_ext;state<=MUL_JOIN;end
    MUL_JOIN:begin imag_acc<=imag_acc+product_ext;state<=MUL_QUANT;end
    MUL_QUANT:begin
     cmd_overflow<=cmd_overflow||qr[DATA_W]||qi[DATA_W];
     cmd_inexact<=cmd_inexact||qr[DATA_W+1]||qi[DATA_W+1];
     if(mul_index==LAST)begin job<=INVERSE;feed_index<=0;state<=FEED_REQ;end
     else begin mul_index<=mul_index+1'b1;state<=MUL_REQ;end
    end
    I_DRAIN:if(f_valid&&f_ready)begin
     if(drain_bad)begin history_valid<=0;stream_active<=0;
      fault_is_cfg<=0;marker_status<=M_FFT;state<=FFT_FLUSH;end
     else begin
      cmd_overflow<=cmd_overflow||f_overflow;cmd_inexact<=cmd_inexact||f_inexact;
      if(i_window)begin remaining<=remaining-1'b1;emitted<=emitted+1'b1;end
      if(drain_index==LAST)begin
       if(cmd_end&&((remaining==0)||(i_window&&(remaining==1))))begin
        history_valid<=0;stream_active<=0;state<=IDLE;
       end else if(taps==1)begin history_valid<=1;stream_active<=1;state<=IDLE;end
       else begin copy_index<=0;state<=COPY_REQ;end
      end else drain_index<=drain_index+1'b1;
     end
    end
    COPY_REQ:state<=COPY_WRITE;
    COPY_WRITE:if(copy_index==history_words-1'b1)begin
     history_valid<=1;stream_active<=1;
     if(cmd_end)begin work_index<=history_words;state<=DATA_PAD;end else state<=IDLE;
    end else begin copy_index<=copy_index+1'b1;state<=COPY_REQ;end
    MARKER:if(m_ready)state<=IDLE;
    FFT_FLUSH:state<=fault_is_cfg?CFG_REPLY:MARKER;
    default:begin state<=IDLE;configured<=0;history_valid<=0;stream_active<=0;end
   endcase
  end
 end
endmodule
