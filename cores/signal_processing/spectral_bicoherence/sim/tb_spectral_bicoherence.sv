// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_spectral_bicoherence;
 parameter integer DATA_W=12,MAX_AVERAGES=9,TAG_W=8,EXAMPLE=0,
  BINS=1,BIN1=0,BIN2=0,ABORTS=4;
 localparam integer LG=(MAX_AVERAGES<2?0:$clog2(MAX_AVERAGES));
 localparam integer BW=3*DATA_W+2+LG,UW=4*DATA_W+3+LG,VW=2*DATA_W+1+LG;
 localparam integer MA=UW,MB=BW,L=MB+(MA+MB+7)/8;
 localparam integer FULL_LATENCY=15*(L+2)+(2*BW+1+16)+3;
 localparam integer ZERO_LATENCY=12*(L+2)+1;
 reg clk=0;always #5 clk=~clk;
 reg rst=0,c_valid=0,s_valid=0,m_ready=0;
 reg [31:0] c_averages=0;
 reg [TAG_W-1:0] c_tag=0;
 reg [6*DATA_W-1:0] s_data=0;
 reg s_last=0;
 wire c_ready,s_ready,m_valid,m_last;
 wire [2:0] m_status;
 wire [16:0] m_q;
 wire signed [BW-1:0] m_br,m_bi;
 wire [UW-1:0] m_u;wire [VW-1:0] m_v;wire [TAG_W-1:0] m_tag;
 wire [3:0] core_state;
 wire core_final_accept;
 generate if(EXAMPLE)begin:frames
  spectrum_triad_bicoherence #(.DATA_W(DATA_W),.MAX_AVERAGES(MAX_AVERAGES),.TAG_W(TAG_W),
   .BINS(BINS),.BIN1(BIN1),.BIN2(BIN2)) dut(
   .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_averages(c_averages),.c_tag(c_tag),
   .s_valid(s_valid),.s_ready(s_ready),.s_data(s_data[2*DATA_W-1:0]),.s_last(s_last),
   .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_bicoherence_q16(m_q),
   .m_b_re(m_br),.m_b_im(m_bi),.m_u(m_u),.m_v(m_v),.m_tag(m_tag),.m_last(m_last));
  assign core_state=dut.measure.state;
  assign core_final_accept=dut.measure.s_valid && dut.measure.s_ready && dut.measure.s_last;
 end else begin:direct
  spectral_bicoherence #(.DATA_W(DATA_W),.MAX_AVERAGES(MAX_AVERAGES),.TAG_W(TAG_W)) dut(
   .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_averages(c_averages),.c_tag(c_tag),
   .s_valid(s_valid),.s_ready(s_ready),.s_data(s_data),.s_last(s_last),
   .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_bicoherence_q16(m_q),
   .m_b_re(m_br),.m_b_im(m_bi),.m_u(m_u),.m_v(m_v),.m_tag(m_tag),.m_last(m_last));
  assign core_state=dut.state;
  assign core_final_accept=s_valid && s_ready && s_last;
 end endgenerate
 localparam integer RECORD_W=3+17+2*BW+UW+VW+TAG_W+1;
 wire [RECORD_W-1:0] record_out={m_status,m_q,m_br,m_bi,m_u,m_v,m_tag,m_last};
 integer cycles=0,final_cycle=-1,commands=0,results=0,input_beats=0,
  holds=0,blocked=0,input_holds=0,resets=0,cancelled=0,
  future_commands=0,future_results=0,cases_done=0,timing_checks=0;
 reg prior_s_stall=0,prior_c_stall=0,prior_m_stall=0;
 reg [6*DATA_W:0] prior_s;
 reg [32+TAG_W-1:0] prior_c;
 reg [RECORD_W-1:0] prior_m;
 always @(posedge clk)begin
  cycles=cycles+1;
  if(rst)begin
   if(c_ready || s_ready || m_valid)$fatal(1,"reset interface leakage");
   prior_s_stall=0;prior_c_stall=0;prior_m_stall=0;final_cycle=-1;
  end else begin
   if(prior_s_stall && (!s_valid || {s_data,s_last}!==prior_s))$fatal(1,"input changed under hold");
   if(prior_c_stall && (!c_valid || {c_averages,c_tag}!==prior_c))$fatal(1,"command changed under hold");
   if(prior_m_stall && (!m_valid || record_out!==prior_m))$fatal(1,"result changed under hold");
   if(c_valid && c_ready)commands=commands+1;
   if(s_valid && s_ready)input_beats=input_beats+1;
   if(m_valid && m_ready)results=results+1;
   if(core_final_accept)final_cycle=cycles;
   if(c_valid && !c_ready)blocked=blocked+1;
   if(s_valid && !s_ready)input_holds=input_holds+1;
   if(m_valid && !m_ready)holds=holds+1;
   prior_s_stall=s_valid && !s_ready;prior_s={s_data,s_last};
   prior_c_stall=c_valid && !c_ready;prior_c={c_averages,c_tag};
   prior_m_stall=m_valid && !m_ready;prior_m=record_out;
  end
 end
 task reset_dut;
  begin
   @(negedge clk);rst=1;c_valid=0;s_valid=0;m_ready=0;resets=resets+1;
   repeat(3)@(negedge clk);
   rst=0;
   @(negedge clk);
   if(m_valid || !c_ready)$fatal(1,"reset recovery");
  end
 endtask
 task command;
  input [31:0] averages;input [TAG_W-1:0] tag;
  integer watchdog;
  begin
   @(negedge clk);c_valid=1;c_averages=averages;c_tag=tag;watchdog=0;
   while(!c_ready)begin @(negedge clk);watchdog=watchdog+1;if(watchdog>8)$fatal(1,"command watchdog");end
   @(posedge clk);if(!c_ready)$fatal(1,"lost command readiness");
   @(negedge clk);c_valid=0;
  end
 endtask
 task sample;
  input [6*DATA_W-1:0] word;input last;
  integer watchdog;
  begin
   @(negedge clk);s_valid=1;s_data=word;s_last=last;watchdog=0;
   while(!s_ready)begin @(negedge clk);watchdog=watchdog+1;if(watchdog>10000)$fatal(1,"input watchdog");end
   @(posedge clk);if(!s_ready)$fatal(1,"lost sample readiness");
   @(negedge clk);s_valid=0;
  end
 endtask
 task expect_result;
  input [2:0] status;input [16:0] q;
  input [BW-1:0] br,bi;input [UW-1:0] u;input [VW-1:0] v;
  input [TAG_W-1:0] tag;input check_latency;
  integer watchdog,delta;
  reg [RECORD_W-1:0] held;
  begin
   watchdog=0;
   while(!m_valid)begin @(negedge clk);watchdog=watchdog+1;if(watchdog>10000)$fatal(1,"result watchdog");end
   if({m_status,m_q,m_br,m_bi,m_u,m_v,m_tag,m_last}!=={status,q,br,bi,u,v,tag,1'b1})
    $fatal(1,"numerical/status/tag mismatch case=%0d got status=%0d q=%0d expected=%0d/%0d",cases_done,m_status,m_q,status,q);
   if(check_latency)begin
    delta=cycles-final_cycle;
    if(final_cycle<0 || delta!=(status==3?ZERO_LATENCY:FULL_LATENCY))
     $fatal(1,"final triad first-valid schedule got=%0d expected=%0d",delta,status==3?ZERO_LATENCY:FULL_LATENCY);
    timing_checks=timing_checks+1;
   end
   held=record_out;
   repeat(7)begin @(negedge clk);if(!m_valid || record_out!==held || c_ready || s_ready)$fatal(1,"held result ownership");end
   m_ready=1;
   @(posedge clk);if(c_ready || !m_valid)$fatal(1,"retirement fallthrough");
   @(negedge clk);m_ready=0;
  end
 endtask
 task reset_scene;
  input integer scene;
  integer j,watchdog;
  reg [6*DATA_W-1:0] ones;
  begin
   ones=0;for(j=0;j<6;j=j+1)ones[j*DATA_W+:DATA_W]=1;
   command(1,{TAG_W{1'b1}});
   if(scene==0)repeat(4)@(negedge clk);
   else begin
    for(j=0;j<(EXAMPLE?BINS:1);j=j+1)sample(ones,j==(EXAMPLE?BINS:1)-1);
    watchdog=0;
    if(scene==1)begin
     while(core_state!=3)begin @(negedge clk);watchdog=watchdog+1;if(watchdog>10000)$fatal(1,"multiply reset phase");end
    end else if(scene==2)begin
     while(core_state!=6)begin @(negedge clk);watchdog=watchdog+1;if(watchdog>10000)$fatal(1,"divide reset phase");end
    end else begin
     while(!m_valid)begin @(negedge clk);watchdog=watchdog+1;if(watchdog>10000)$fatal(1,"held reset phase");end
     repeat(4)@(negedge clk);
    end
   end
   cancelled=cancelled+1;reset_dut();
   command(0,0);expect_result(1,0,0,0,0,0,0,0);
  end
 endtask
 reg [6*DATA_W-1:0] words[0:MAX_AVERAGES*BINS-1];
 reg lasts[0:MAX_AVERAGES*BINS-1];
 reg [31:0] averages_in;
 reg [BW-1:0] expected_br,expected_bi;
 reg [UW-1:0] expected_u;reg [VW-1:0] expected_v;
 reg [TAG_W-1:0] tag,next_tag;
 integer fd,rc,ncases,ci,j,nsamples,status_in,q_in,last_in,watchdog;
 string vector_path,extra;
 initial begin
  if(!$value$plusargs("vectors=%s",vector_path))$fatal(1,"vectors required");
  fd=$fopen(vector_path,"r");if(fd==0)$fatal(1,"vector file");
  rc=$fscanf(fd,"%d",ncases);if(rc!=1)$fatal(1,"case count");
  reset_dut();
  for(ci=0;ci<ncases;ci=ci+1)begin
   rc=$fscanf(fd,"%d %d %d %d %h %h %h %h",averages_in,nsamples,status_in,q_in,expected_br,expected_bi,expected_u,expected_v);
   if(rc!=8 || nsamples<0 || nsamples>MAX_AVERAGES*BINS)$fatal(1,"case header");
   for(j=0;j<nsamples;j=j+1)begin
    rc=$fscanf(fd,"%h %d",words[j],last_in);if(rc!=2 || (last_in!=0 && last_in!=1))$fatal(1,"sample row");
    lasts[j]=last_in;
   end
   tag=ci;next_tag=~tag;
   command(averages_in,tag);
   for(j=0;j<nsamples;j=j+1)begin
    if(j%3==0)repeat(2)@(negedge clk);
    sample(words[j],lasts[j]);
   end
   // Distinct future command stays offered through the real original retirement.
   @(negedge clk);c_valid=1;c_averages=0;c_tag=next_tag;
   expect_result(status_in[2:0],q_in[16:0],expected_br,expected_bi,expected_u,expected_v,tag,status_in==0 || status_in==3);
   watchdog=0;
   while(!c_ready)begin @(negedge clk);watchdog=watchdog+1;if(watchdog>8)$fatal(1,"future command watchdog");end
   @(posedge clk);if(!c_ready || !c_valid)$fatal(1,"future real handshake");future_commands=future_commands+1;
   @(negedge clk);c_valid=0;
   expect_result(1,0,0,0,0,0,next_tag,0);future_results=future_results+1;
   cases_done=cases_done+1;
  end
  rc=$fscanf(fd,"%s",extra);if(rc==1)$fatal(1,"trailing vector token");$fclose(fd);
  for(j=0;j<ABORTS;j=j+1)reset_scene(j);
  @(negedge clk);
  if(commands!=2*ncases+2*ABORTS || results!=2*ncases+ABORTS || holds==0 || blocked==0 || timing_checks==0)
   $fatal(1,"protocol counters");
  $display("PASS spectral_bicoherence D=%0d A=%0d T=%0d EX=%0d cases=%0d commands=%0d results=%0d future_commands=%0d future_results=%0d resets=%0d cancelled=%0d input_beats=%0d holds=%0d blocked=%0d input_holds=%0d timing_checks=%0d",DATA_W,MAX_AVERAGES,TAG_W,EXAMPLE,cases_done,commands,results,future_commands,future_results,resets,cancelled,input_beats,holds,blocked,input_holds,timing_checks);
  $finish;
 end
endmodule
