// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb;
 parameter integer F=4,W=16,D=32,T=8,Q=16,CYCLES=1;
 localparam IW=(F>1)?$clog2(F):1,QW=(Q>1)?$clog2(Q):1;
 localparam INW=36+3*W+T+F*(1+W+D+T),PREW=70+F+W+D+2*T;
 localparam EW=4*W+D+T+3,STATEW=QW+IW+F*EW,CINW=33+3*W+T,MOUTW=33+W+D+T,ROUTW=34+T;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,cv=0,ce=0,rrdy=0,mrdy=0;reg [31:0] cf=0;
 reg [W-1:0] cc=0,cr=0,ci=0;reg [T-1:0] ct=0;
 reg [F-1:0] sv=0;reg [F*W-1:0] costs=0;reg [F*D-1:0] data=0;reg [F*T-1:0] tags=0;
 wire cready,rv,mv,ms;wire [1:0] rs;wire [31:0] rf,mf;wire [T-1:0] rt,mt;
 wire [F-1:0] sr;wire [W-1:0] mc;wire [D-1:0] md;
 multiflow_token_shaper #(.FLOWS(F),.TOKEN_W(W),.DATA_W(D),.TAG_W(T),.QUANTUM(Q)) dut(
  .clk(clk),.rst(rst),.c_valid(cv),.c_ready(cready),.c_flow(cf),.c_enable(ce),
  .c_capacity(cc),.c_rate(cr),.c_initial(ci),.c_tag(ct),.r_valid(rv),.r_ready(rrdy),
  .r_status(rs),.r_flow(rf),.r_tag(rt),.s_valid(sv),.s_ready(sr),.s_cost(costs),
  .s_data(data),.s_tag(tags),.m_valid(mv),.m_ready(mrdy),.m_flow(mf),.m_status(ms),
  .m_cost(mc),.m_data(md),.m_tag(mt));
 wire [CINW-1:0] csource={cf,ce,cc,cr,ci,ct};
 wire [MOUTW-1:0] mout={mf,ms,mc,md,mt};wire [ROUTW-1:0] rout={rs,rf,rt};
 wire [PREW-1:0] observed={cready,rv,(rv?rout:{ROUTW{1'b0}}),sr,mv,(mv?mout:{MOUTW{1'b0}})};
 reg [INW-1:0] stimuli[0:CYCLES-1];reg [PREW-1:0] expected_pre[0:CYCLES-1];
 reg [STATEW-1:0] expected_post[0:CYCLES-1];
 integer accepted=0,delivered=0,configs=0,source_stalls=0,config_stalls=0,held=0,rheld=0;
 integer phase_resets=0,recoveries=0,ledger_checks=0,queue_checks=0;
 reg [F-1:0] source_held=0;reg config_held=0,out_held=0,response_held=0;
 reg [F*W-1:0] old_cost;reg [F*D-1:0] old_data;reg [F*T-1:0] old_tags;
 reg [CINW-1:0] old_config;reg [MOUTW-1:0] old_out;reg [ROUTW-1:0] old_response;

 function automatic [STATEW-1:0] state_word;
  begin
   state_word={dut.phase,dut.rr};
   for(integer x=0;x<F;x=x+1)state_word=(state_word<<EW)|
    {dut.enabled[x],dut.capacity[x],dut.rate[x],dut.tokens[x],dut.pending[x],
     (dut.pending[x]?dut.queued_cost[x]:{W{1'b0}}),(dut.pending[x]?dut.queued_data[x]:{D{1'b0}}),
     (dut.pending[x]?dut.queued_tag[x]:{T{1'b0}}),(dut.pending[x]?dut.queued_bad[x]:1'b0)};
  end
 endfunction
 task reset_now;
  begin
   rst=1;cv=0;sv=0;mrdy=0;rrdy=0;
   #1;if(cready || rv || mv || sr!=0)$fatal(1,"reset transfer gating");
   @(posedge clk);#1;
   if(dut.enabled!==0 || dut.pending!==0 || dut.phase!==0 || dut.rr!==0 || rv || mv)$fatal(1,"reset ownership");
   for(integer x=0;x<F;x=x+1)if(dut.capacity[x]!==0 || dut.rate[x]!==0 || dut.tokens[x]!==0)$fatal(1,"reset ledger");
   @(negedge clk);rst=0;
  end
 endtask
 task offer_config(input integer index,input integer enable,input reg [W-1:0] cap,rate,initial_value);
  begin
   @(negedge clk);cv=1;cf=index;ce=enable;cc=cap;cr=rate;ci=initial_value;ct={T{1'b1}};
   #1;if(!cready)$fatal(1,"probe config not ready");
   @(posedge clk);#1;cv=0;
   if(!rv || rf!==index || rt!=={T{1'b1}})$fatal(1,"probe config response");
  end
 endtask
 task accept_config;
  begin @(negedge clk);rrdy=1;@(posedge clk);#1;if(rv)$fatal(1,"probe config retirement");@(negedge clk);rrdy=0;end
 endtask
 task configure(input integer index,input reg [W-1:0] rate,initial_value);
  begin offer_config(index,1,{W{1'b1}},rate,initial_value);if(rs!==0)$fatal(1,"probe valid config");accept_config();end
 endtask
 task offer_item(input reg [W-1:0] cost);
  begin
   @(negedge clk);sv=1;costs=cost;data={D{1'b1}};tags={T{1'b1}};
   #1;if(!sr[0])$fatal(1,"probe input not ready");
   @(posedge clk);#1;sv=0;
  end
 endtask
 task wait_output;
  integer count;
  begin
   count=0;while(!mv)begin @(posedge clk);#1;count=count+1;if(count>Q+2*F+8)$fatal(1,"probe output timeout");end
  end
 endtask
 task retire_output;
  begin @(negedge clk);mrdy=1;@(posedge clk);#1;if(mv)$fatal(1,"probe output retirement");@(negedge clk);mrdy=0;end
 endtask
 task fresh;
  begin
   configure(0,0,{W{1'b1}});offer_item(1);wait_output();
   if(mf!==0 || ms || mc!==1 || md!=={D{1'b1}} || mt!=={T{1'b1}})$fatal(1,"fresh descriptor");
   repeat(3)begin @(posedge clk);#1;if(!mv || !dut.pending[0] || dut.tokens[0]!=={W{1'b1}})$fatal(1,"fresh held reservation");end
   retire_output();
   if(dut.tokens[0]!==({W{1'b1}}-1'b1) || dut.pending!==0 || dut.rr!==((F>1)?1:0))$fatal(1,"fresh debit");
   repeat(3)begin @(posedge clk);#1;if(mv || rv || dut.pending!==0)$fatal(1,"fresh stale result");end
   recoveries=recoveries+1;
  end
 endtask
 task finish_reset;
  begin reset_now();phase_resets=phase_resets+1;fresh();end
 endtask
 task probe(input integer phase);
  begin
   reset_now();
   case(phase)
    0:begin end
    1:offer_config(0,1,{W{1'b1}},1,0);
    2:begin
     offer_config(0,1,{W{1'b1}},1,0);
     while(dut.phase!=Q-1)@(negedge clk);
     rrdy=1;@(posedge clk);#1;rrdy=0;
     if(dut.tokens[0]!==0)$fatal(1,"config ACK priority at tick");
    end
    3,7:begin
     configure(0,0,0);offer_item(1);
     if(phase==7)begin cv=1;cf=0;ce=1;cc={W{1'b1}};cr=1;ci=0;ct=0;end
     repeat(4)begin @(posedge clk);#1;if(mv || !dut.pending[0] || dut.tokens[0]!==0 || (phase==7 && cready))$fatal(1,"zero-rate pending boundary");end
    end
    4:begin configure(0,0,{W{1'b1}});offer_item(1);if(mv || !dut.pending[0])$fatal(1,"pending preselect boundary");end
    5,6:begin configure(0,1,{W{1'b1}});offer_item((phase==6)?0:1);wait_output();if(ms!==(phase==6))$fatal(1,"held output status");end
    8:begin
     offer_config(0,1,0,0,0);if(rs!==2)$fatal(1,"bad config status");sv=1;costs=1;
     repeat(4)begin @(posedge clk);#1;if(!rv || sr[0])$fatal(1,"held invalid config/source");end
    end
    9:begin offer_config(F,0,0,0,0);if(rs!==1)$fatal(1,"bad flow status");end
    10:begin
     configure(0,1,{W{1'b1}});offer_config(0,0,0,0,0);sv=1;costs=1;
     repeat(4)begin @(posedge clk);#1;if(!rv || sr[0] || !dut.enabled[0] || dut.capacity[0]!=={W{1'b1}})$fatal(1,"uncommitted config/blocked ingress");end
    end
    11,12,13:begin
     configure(0,1,{W{1'b1}});offer_item((phase==11)?0:1);wait_output();
     if(phase==12)begin while(dut.phase!=0)begin @(posedge clk);#1;end end
     else begin while(dut.phase!=Q-1)@(negedge clk);end
     if(phase==13)begin mrdy=1;@(posedge clk);#1;mrdy=0;
      if(dut.tokens[0]!==({W{1'b1}}-1'b1) || dut.pending[0] || mv)$fatal(1,"tick refill then debit");end
    end
    14:begin
     for(integer x=0;x<F;x=x+1)configure(x,1,{W{1'b1}});
     @(negedge clk);sv={F{1'b1}};
     for(integer x=0;x<F;x=x+1)begin costs[x*W+:W]=1;data[x*D+:D]=x;tags[x*T+:T]=x;end
     #1;if(sr!=={F{1'b1}})$fatal(1,"parallel ingress ready");
     @(posedge clk);#1;sv=0;if(dut.pending!=={F{1'b1}} || mv)$fatal(1,"parallel pending owner");
    end
   endcase
   // This observed target asserts reset now, without another active edge.
   finish_reset();
  end
 endtask
 initial begin
  $readmemh("input.hex",stimuli);$readmemh("pre.hex",expected_pre);$readmemh("post.hex",expected_post);
  for(integer x=0;x<15;x=x+1)probe(x);
  reset_now();
  for(integer cycle=0;cycle<CYCLES;cycle=cycle+1)begin
   if(cycle>0)@(negedge clk);
   {cv,cf,ce,cc,cr,ci,ct,rrdy,sv,costs,data,tags,mrdy}=stimuli[cycle];
   #1;
   if(observed!==expected_pre[cycle])$fatal(1,"cycle %0d interface got=%h expected=%h",cycle,observed,expected_pre[cycle]);
   if(config_held && (!cv || csource!==old_config))$fatal(1,"blocked config changed");
   if(out_held && (!mv || mout!==old_out))$fatal(1,"held egress changed");
   if(response_held && (!rv || rout!==old_response))$fatal(1,"held config response changed");
   for(integer x=0;x<F;x=x+1)begin
    if(source_held[x] && (!sv[x] || costs[x*W+:W]!==old_cost[x*W+:W] || data[x*D+:D]!==old_data[x*D+:D] || tags[x*T+:T]!==old_tags[x*T+:T]))$fatal(1,"blocked flow source changed");
    if(sv[x] && sr[x])accepted=accepted+1;
    if(sv[x] && !sr[x])source_stalls=source_stalls+1;
   end
   if(cv && cready)configs=configs+1;
   if(cv && !cready)config_stalls=config_stalls+1;
   if(mv && mrdy)delivered=delivered+1;
   if(mv && !mrdy)held=held+1;
   if(rv && !rrdy)rheld=rheld+1;
   source_held=sv&~sr;old_cost=costs;old_data=data;old_tags=tags;
   config_held=cv&&!cready;old_config=csource;out_held=mv&&!mrdy;old_out=mout;response_held=rv&&!rrdy;old_response=rout;
   @(posedge clk);#1;
   if(state_word()!==expected_post[cycle])$fatal(1,"cycle %0d full ledger/queue state got=%h expected=%h",cycle,state_word(),expected_post[cycle]);
   ledger_checks=ledger_checks+F;queue_checks=queue_checks+F;
  end
  @(negedge clk);cv=0;sv=0;rrdy=0;mrdy=0;
  #1;if(mv || rv || dut.pending!==0 || accepted!=delivered || phase_resets!=recoveries || source_stalls==0 || config_stalls==0 || held==0 || rheld==0)$fatal(1,"incomplete conservation/stalls");
  $display("PASS shaper F=%0d W=%0d D=%0d T=%0d Q=%0d cycles=%0d accepted=%0d delivered=%0d configs=%0d phase_resets=%0d recoveries=%0d source_stalls=%0d config_stalls=%0d held=%0d rheld=%0d ledgers=%0d queues=%0d",F,W,D,T,Q,CYCLES,accepted,delivered,configs,phase_resets,recoveries,source_stalls,config_stalls,held,rheld,ledger_checks,queue_checks);
  $finish;
 end
 initial begin #100000000;$fatal(1,"watchdog");end
endmodule
