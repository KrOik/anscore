// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_stable_preference_match;
 parameter integer N=8,T=8;
 localparam IW=(N<=1)?1:$clog2(N),CW=$clog2(N+1),PW=$clog2(N*N+1),INW=34+T;
 localparam OUTW=6+4*IW+CW+PW+T,BOUND=N*N*(N+6)+2;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,s_valid=0,s_first=0,s_last=0,m_ready=0;
 reg [31:0] s_partner=0;reg [T-1:0] s_tag=0;
 wire s_ready,m_valid,m_keep,m_first,m_last;
 wire [IW-1:0] m_proposer,m_receiver,m_proposer_rank,m_receiver_rank;
 wire [CW-1:0] m_count;wire [PW-1:0] m_proposals;
 wire [T-1:0] m_tag;wire [2:0] m_errors;
 stable_preference_match #(.N(N),.TAG_W(T)) dut(.*);
 wire [OUTW-1:0] payload={m_keep,m_first,m_last,m_proposer,m_receiver,m_proposer_rank,m_receiver_rank,m_count,m_proposals,m_tag,m_errors};
 wire [INW-1:0] request={s_partner,s_first,s_last,s_tag};
 reg [INW-1:0] inputs[0:150000];reg [OUTW-1:0] held_payload;reg [INW-1:0] held_request;
 reg held=0,source_held=0,main_run=0,started=0;
 integer cycle=0,blocked=0,holds=0,received=0,source=0,offered=0,age=0;
 integer inf,outf,events_file,input_count,output_count,currframe=-1,token=0,tailcycle=0;
 integer frame_proposals=0,frame_scans=0,max_latency=0,reset_count=0,total_proposals=0;
 string input_path,output_path,event_path;
 task tick;begin @(posedge clk);#1;end endtask
 task cancel;
  begin
   rst=1;s_valid=0;m_ready=0;#1;if(s_ready||m_valid)$fatal(1,"reset gate");
   tick;@(negedge clk);rst=0;#1;
   if(dut.state!=0 || dut.errors!=0 || dut.proposals!=0 || dut.input_address!=0)$fatal(1,"reset cancellation");
  end
 endtask
 task send(input integer partner,input integer first,input integer last,input integer tag);
  begin
   s_partner=partner;s_first=first;s_last=last;s_tag=tag;s_valid=1;
   #1;
   @(posedge clk);while(!s_ready)@(posedge clk);
   #1;@(negedge clk);s_valid=0;
  end
 endtask
 task frame(input integer bad,input integer partial);
  integer side,p,r,k;
  begin
   if(partial)send(0,1,0,1);
   else for(side=0;side<2;side=side+1)for(p=0;p<N;p=p+1)for(r=0;r<N;r=r+1)begin
    k=(side==0)?r:N-1-r;
    if(bad && side==1 && p==N-1 && r==N-1)k=-1;
    send(k,side==0&&p==0&&r==0,side==1&&p==N-1&&r==N-1,1);
   end
  end
 endtask
 task fresh;
  integer p,waited;
  begin
   frame(0,0);waited=0;
   for(p=0;p<N;p=p+1)begin
    while(!m_valid)begin tick;@(negedge clk);waited=waited+1;if(waited>BOUND+10)$fatal(1,"fresh missing");end
    if(!m_keep || m_first!=(p==0) || m_last!=(p==N-1) || m_proposer!=p || m_receiver!=N-1-p ||
      m_proposer_rank!=N-1-p || m_receiver_rank!=N-1-p || m_count!=N || m_proposals!=N*(N+1)/2 || m_tag!=1 || m_errors!=0)
      $fatal(1,"fresh all fields p%0d",p);
    repeat(2)begin tick;@(negedge clk);end
    m_ready=1;tick;@(negedge clk);m_ready=0;
   end
   #1;if(!s_ready||m_valid)$fatal(1,"fresh retirement");
  end
 endtask
 task probe(input integer id);
  reg match;integer waited;
  begin
   if(id==12)frame(0,1);
   else if(id==18)frame(1,0);
   else if(id!=0)frame(0,0);
   waited=0;match=0;
   while(!match)begin
    if(id<12)match=(dut.state==id);
    else case(id)
     12:match=(dut.state==0 && !dut.first_position);
     13:match=(dut.state==1 && dut.init_index>0);
     14:match=(dut.state==2 && dut.scan>0);
     15:match=(dut.state==8 && !dut.free_b[dut.receiver]);
     16:begin m_ready=1;match=(dut.state==11 && m_proposer>0);end
     19:match=(dut.state==8 && !dut.free_b[dut.receiver] && dut.accept);
     default:match=m_valid;
    endcase
    if(!match)begin tick;@(negedge clk);waited=waited+1;if(waited>BOUND+10)$fatal(1,"unreachable probe%0d",id);end
   end
   if(id==17 || id==18)begin
    s_partner=0;s_first=1;s_last=0;s_tag=0;s_valid=1;
    repeat(3)begin tick;@(negedge clk);if(s_ready)$fatal(1,"held overlaps capture");end
   end
   cancel;reset_count=reset_count+1;fresh;
  end
 endtask
 always @(posedge clk)begin
  cycle=cycle+1;
  if(cycle>6000000)$fatal(1,"watchdog");
  if(rst)begin held=0;source_held=0;end
  else begin
   if(held&&(!m_valid||payload!==held_payload))$fatal(1,"output hold");
   if(source_held&&(!s_valid||request!==held_request))$fatal(1,"source hold");
   held=m_valid&&!m_ready;held_payload=payload;
   source_held=s_valid&&!s_ready;held_request=request;
   if(main_run)begin
    if(s_valid&&!s_ready)blocked=blocked+1;
    if(m_valid&&!m_ready)holds=holds+1;
    if(s_valid&&s_ready)begin
     token=token+1;
     if(token==2*N*N)begin token=0;currframe=currframe+1;tailcycle=cycle;frame_proposals=0;frame_scans=0;started=0;end
    end
    if(dut.state==2)frame_scans=frame_scans+1;
    if(dut.state==8)begin
     frame_proposals=frame_proposals+1;total_proposals=total_proposals+1;
     if(dut.active_rank>=N || !dut.free_a[dut.active])$fatal(1,"proposal ownership/rank");
     $fdisplay(events_file,"%0d %0d %0d %0d %0d %0d",currframe,dut.active,dut.receiver,dut.free_b[dut.receiver],dut.accept,dut.incumbent);
    end
    if(m_valid&&m_ready)begin $fdisplay(outf,"%h",payload);received=received+1;end
   end
  end
  #1;
  if(main_run&&!rst&&m_valid&&!started)begin
   if(cycle-tailcycle!=((m_errors!=0)?0:frame_scans+6*frame_proposals+2))$fatal(1,"first-valid schedule");
   if(cycle-tailcycle>BOUND)$fatal(1,"first-valid bound");
   if(m_errors==0 && m_proposals!=frame_proposals)$fatal(1,"proposal total");
   if(cycle-tailcycle>max_latency)max_latency=cycle-tailcycle;
   started=1;
  end
 end
 integer id,guard;
 initial begin
  if(!$value$plusargs("INPUT=%s",input_path)||!$value$plusargs("OUTPUT=%s",output_path)||!$value$plusargs("EVENTS=%s",event_path)||
    !$value$plusargs("COUNT=%d",input_count)||!$value$plusargs("OUTCOUNT=%d",output_count))$fatal(1,"args");
  $readmemh(input_path,inputs,0,input_count-1);outf=$fopen(output_path,"w");events_file=$fopen(event_path,"w");
  tick;@(negedge clk);cancel;
  for(id=0;id<20;id=id+1)if(!(N==1 && (id==7 || id==13 || id==14 || id==15 || id==16 || id==19)))probe(id);
  main_run=1;guard=0;
  while(received<output_count)begin
   if(!offered&&source<input_count&&cycle%7!=0)begin {s_partner,s_first,s_last,s_tag}=inputs[source];s_valid=1;offered=1;end
   if(m_valid)begin age=age+1;m_ready=(age>=4 && cycle%5!=0);end else begin age=0;m_ready=0;end
   @(posedge clk);if(s_valid&&s_ready)begin source=source+1;offered=0;end
   #1;@(negedge clk);if(!offered)s_valid=0;
   guard=guard+1;if(guard>4000000)$fatal(1,"finite main bound");
  end
  main_run=0;if(source!=input_count||blocked==0||holds==0)$fatal(1,"coverage");
  $fclose(outf);$fclose(events_file);
  $display("PASS stable records=%0d blocked=%0d held=%0d resets=%0d max_latency=%0d proposals=%0d",received,blocked,holds,reset_count,max_latency,total_proposals);
  $finish;
 end
endmodule
