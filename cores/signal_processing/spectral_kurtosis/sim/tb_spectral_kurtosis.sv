// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_spectral_kurtosis;
 parameter integer BINS=7,FRAMES=3,POWER_W=12,FRAC_W=1,TAG_W=8,EXAMPLE=0;
 localparam BW=(BINS<2)?1:$clog2(BINS),G=$clog2(FRAMES),CW=$clog2(FRAMES+2);
 localparam SW=POWER_W+G,S2W=2*POWER_W+G,NW=2*SW+CW,QW=FRAC_W+CW;
 localparam ROW_W=6+BW+SW+S2W+2*NW+QW+TAG_W;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,c_valid=0,s_valid=0,s_last=0;
 reg [QW-1:0] c_lower=0,c_upper=0;
 reg [TAG_W-1:0] c_tag=0;
 reg [31:0] s_word=0;
 wire c_ready,s_ready,m_valid,busy;
 reg m_ready=0,force_hold=1;
 wire [2:0] m_status;
 wire [BW-1:0] m_bin;
 wire [SW-1:0] m_sum;
 wire [S2W-1:0] m_sum2;
 wire [NW-1:0] m_num,m_den;
 wire [QW-1:0] m_q;
 wire m_inexact,m_outside,m_last;
 wire [TAG_W-1:0] m_tag;
 wire [3:0] core_state;
 generate if(EXAMPLE!=0)begin:example_path
  iq_spectral_kurtosis64 #(.BINS(BINS),.FRAMES(FRAMES),.FRAC_W(FRAC_W),.TAG_W(TAG_W)) dut(
   .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_lower(c_lower),.c_upper(c_upper),.c_tag(c_tag),
   .s_valid(s_valid),.s_ready(s_ready),.s_complex(s_word),.s_last(s_last),
   .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_bin(m_bin),.m_sum(m_sum),.m_sum2(m_sum2),
   .m_numerator(m_num),.m_denominator(m_den),.m_sk_q(m_q),.m_inexact(m_inexact),.m_outside(m_outside),
   .m_last(m_last),.m_tag(m_tag),.busy(busy));
  assign core_state=dut.measure.state;
 end else begin:core_path
  spectral_kurtosis #(.BINS(BINS),.FRAMES(FRAMES),.POWER_W(POWER_W),.FRAC_W(FRAC_W),.TAG_W(TAG_W)) dut(
   .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_lower(c_lower),.c_upper(c_upper),.c_tag(c_tag),
   .s_valid(s_valid),.s_ready(s_ready),.s_power(s_word[POWER_W-1:0]),.s_last(s_last),
   .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_bin(m_bin),.m_sum(m_sum),.m_sum2(m_sum2),
   .m_numerator(m_num),.m_denominator(m_den),.m_sk_q(m_q),.m_inexact(m_inexact),.m_outside(m_outside),
   .m_last(m_last),.m_tag(m_tag),.busy(busy));
  assign core_state=dut.state;
 end endgenerate
 reg [31:0] sample_word[0:16383];
 integer sample_last[0:16383];
 integer e_status[0:255],e_bin[0:255];
 reg [SW-1:0] e_sum[0:255];
 reg [S2W-1:0] e_sum2[0:255];
 reg [NW-1:0] e_num[0:255],e_den[0:255];
 reg [QW-1:0] e_q[0:255];
 reg e_inexact[0:255],e_outside[0:255],e_last[0:255];
 integer cycles=0,commands=0,future_commands=0,future_results=0,resets=0,cancelled=0;
 integer cases=0,case_results=0,samples=0,status0=0,status1=0,status2=0,status3=0,inexact=0,outside=0;
 integer holds=0,blocked=0,input_holds=0,row_index=0,expected_rows=0,current_case=-1;
 reg active_case=0,future_active=0,future_offer=0,future_may_handshake=0;
 reg original_retired=0,future_retired=0;
 reg [TAG_W-1:0] expected_tag,expected_future_tag;
 reg prev_cv=0,prev_cr=0,prev_sv=0,prev_sr=0,prev_mv=0,prev_mr=0;
 reg [2*QW+TAG_W-1:0] held_command;
 reg [32:0] held_sample;
 reg [ROW_W-1:0] held_row;
 wire [ROW_W-1:0] row_payload={m_status,m_bin,m_sum,m_sum2,m_num,m_den,m_q,m_inexact,m_outside,m_last,m_tag};
 always @(negedge clk)m_ready=!rst && !force_hold && cycles%13>=5;
 always @(posedge clk)begin
  cycles=cycles+1;
  if(cycles>4000000)$fatal(1,"watchdog");
  if(rst)begin prev_cv=0;prev_sv=0;prev_mv=0;end
  else begin
   if(prev_cv && !prev_cr && (!c_valid || {c_lower,c_upper,c_tag}!==held_command))$fatal(1,"command changed while stalled");
   if(prev_sv && !prev_sr && (!s_valid || {s_word,s_last}!==held_sample))$fatal(1,"sample changed while stalled");
   if(prev_mv && !prev_mr && (!m_valid || row_payload!==held_row))$fatal(1,"result changed while stalled");
   prev_cv=c_valid;prev_cr=c_ready;held_command={c_lower,c_upper,c_tag};
   prev_sv=s_valid;prev_sr=s_ready;held_sample={s_word,s_last};
   prev_mv=m_valid;prev_mr=m_ready;held_row=row_payload;
   if(c_valid && c_ready)begin
    commands=commands+1;
    if(future_offer)begin
     if(!future_may_handshake)$fatal(1,"future command crossed current ownership");
     future_commands=future_commands+1;
    end
   end
   if(c_valid && !c_ready)blocked=blocked+1;
   if(s_valid && !s_ready)input_holds=input_holds+1;
   if(m_valid && !m_ready)holds=holds+1;
   if(s_valid && s_ready && active_case)samples=samples+1;
   if(m_valid && m_ready)begin
    if(future_active)begin
     if(m_status!==3'd1 || m_bin!=0 || m_sum!=0 || m_sum2!=0 || m_num!=0 || m_den!=0 ||
      m_q!=0 || m_inexact || m_outside || !m_last || m_tag!==expected_future_tag)$fatal(1,"future marker mismatch");
     future_results=future_results+1;future_retired=1;
    end else begin
     if(!active_case || row_index>=expected_rows)$fatal(1,"unexpected result");
     if(m_status!==e_status[row_index] || m_bin!==e_bin[row_index] || m_sum!==e_sum[row_index] ||
      m_sum2!==e_sum2[row_index] || m_num!==e_num[row_index] || m_den!==e_den[row_index] ||
      m_q!==e_q[row_index] || m_inexact!==e_inexact[row_index] || m_outside!==e_outside[row_index] ||
      m_last!==e_last[row_index] || m_tag!==expected_tag)
      $fatal(1,"row mismatch case%0d row%0d status%0d bin%0d sum%h sum2%h num%h den%h q%h",current_case,row_index,
       m_status,m_bin,m_sum,m_sum2,m_num,m_den,m_q);
     case_results=case_results+1;inexact=inexact+m_inexact;outside=outside+m_outside;
     case(m_status)0:status0=status0+1;1:status1=status1+1;2:status2=status2+1;3:status3=status3+1;
      default:$fatal(1,"unexpected arithmetic fault");endcase
     row_index=row_index+1;
     if(m_last)begin
      if(row_index!=expected_rows)$fatal(1,"early terminal result");
      original_retired=1;
     end
    end
   end
  end
 end
 task automatic reset_now;
  begin
   @(negedge clk);rst=1;c_valid=0;s_valid=0;active_case=0;future_active=0;
   future_offer=0;future_may_handshake=0;force_hold=1;
   repeat(3)@(negedge clk);
   rst=0;resets=resets+1;
   repeat(3)@(negedge clk);
   if(!c_ready || m_valid || busy)$fatal(1,"reset ghost/busy");
  end
 endtask
 task automatic issue(input [QW-1:0] lo,hi,input [TAG_W-1:0] tag);
  begin
   @(negedge clk);c_lower=lo;c_upper=hi;c_tag=tag;c_valid=1;future_offer=0;future_may_handshake=0;
   do @(posedge clk);while(!c_ready);
   @(negedge clk);c_lower={QW{1'b1}};c_upper=0;c_tag=~tag;future_offer=1;
   if(c_ready)$fatal(1,"future accepted before output retirement");
  end
 endtask
 task automatic feed(input integer count,use_vectors);
  integer k;
  begin
   @(negedge clk);
   for(k=0;k<count;k=k+1)begin
    if((k+current_case+29)%11==0)begin s_valid=0;@(negedge clk);end
    s_valid=1;s_word=use_vectors?sample_word[k]:32'd1;
    s_last=use_vectors?sample_last[k]:(k%BINS==BINS-1);
    do @(posedge clk);while(!s_ready);
    @(negedge clk);
   end
   s_valid=0;
  end
 endtask
 task automatic abort_at(input integer mode);
  integer target;
  begin
   current_case=-100-mode;force_hold=1;
   issue(mode==7?{QW{1'b1}}:0,mode==7?0:{QW{1'b1}},mode+11);
   if(mode==0)repeat(3)@(negedge clk);
   else if(mode==1)begin feed(1,0);while(core_state!=3)@(negedge clk);end
   else if(mode==6)begin
    feed(1,0);
    if(EXAMPLE!=0)repeat(2)@(negedge clk);
    else while(core_state!=4)@(negedge clk);
   end else if(mode==7)begin while(!m_valid)@(negedge clk);repeat(5)@(negedge clk);end
   else begin
    feed(BINS*FRAMES,0);
    case(mode)2:target=5;3:target=8;4:target=11;default:target=12;endcase
    while(core_state!=target)@(negedge clk);
    if(mode==5)repeat(5)@(negedge clk);
   end
   cancelled=cancelled+1;reset_now();
  end
 endtask
 integer fd,ncases,ci,id,ns,nr,j,sc;
 reg [QW-1:0] lo,hi;
 reg [4095:0] vector_path;
 initial begin
  if(EXAMPLE!=0 && POWER_W!=32)$fatal(1,"example power width");
  reset_now();
  if(BINS!=256)for(j=0;j<8;j=j+1)abort_at(j);
  if(!$value$plusargs("vectors=%s",vector_path))$fatal(1,"missing vector path");
  fd=$fopen(vector_path,"r");if(!fd)$fatal(1,"vector open");
  sc=$fscanf(fd,"%d",ncases);if(sc!=1)$fatal(1,"case header");
  for(ci=0;ci<ncases;ci=ci+1)begin
   sc=$fscanf(fd,"%d %h %h %d %d",id,lo,hi,ns,nr);
   if(sc!=5 || id!=ci || ns<0 || ns>BINS*FRAMES || nr<1 || nr>BINS)$fatal(1,"case dimensions");
   for(j=0;j<ns;j=j+1)begin sc=$fscanf(fd,"%h %d",sample_word[j],sample_last[j]);if(sc!=2)$fatal(1,"sample vector");end
   for(j=0;j<nr;j=j+1)begin
    sc=$fscanf(fd,"%d %d %h %h %h %h %h %h %h %h",e_status[j],e_bin[j],e_sum[j],e_sum2[j],e_num[j],e_den[j],e_q[j],
     e_inexact[j],e_outside[j],e_last[j]);if(sc!=10)$fatal(1,"row vector");
   end
   current_case=id;expected_rows=nr;row_index=0;expected_tag=id*37+9;expected_future_tag=~expected_tag;
   active_case=1;original_retired=0;future_retired=0;force_hold=0;
   issue(lo,hi,id*37+9);
   if(ns!=0)feed(ns,1);
   while(!original_retired)@(negedge clk);
   active_case=0;future_active=1;future_may_handshake=1;force_hold=1;
   do @(posedge clk);while(!c_ready);
   @(negedge clk);c_valid=0;future_offer=0;future_may_handshake=0;
   while(!m_valid)@(negedge clk);
   repeat(5)begin @(negedge clk);if(c_ready)$fatal(1,"held future completion lost ownership");end
   force_hold=0;
   while(!future_retired)@(negedge clk);
   future_active=0;cases=cases+1;
   @(negedge clk);if(!c_ready || m_valid || busy)$fatal(1,"terminal fence");
  end
  $fclose(fd);
  if(holds==0 || blocked==0 || input_holds==0)$fatal(1,"flow-control coverage");
  $display("PASS spectral_kurtosis B=%0d M=%0d P=%0d F=%0d T=%0d EX=%0d cases=%0d case_results=%0d samples=%0d status0=%0d status1=%0d status2=%0d status3=%0d inexact=%0d outside=%0d commands=%0d future_commands=%0d future_results=%0d resets=%0d cancelled=%0d holds=%0d blocked=%0d input_holds=%0d cycles=%0d",
   BINS,FRAMES,POWER_W,FRAC_W,TAG_W,EXAMPLE,cases,case_results,samples,status0,status1,status2,status3,inexact,outside,
   commands,future_commands,future_results,resets,cancelled,holds,blocked,input_holds,cycles);
  $finish;
 end
endmodule
