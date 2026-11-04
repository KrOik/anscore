// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb;
parameter integer Q=4,C=64,D=32,T=8,INPUTS=1,OUTPUTS=1,COMMANDS=1;
localparam IW=(C>1)?$clog2(C):1,CW=$clog2(C+1),QW=(Q>1)?$clog2(Q):1;
localparam INW=12+T+D,OUTW=4+8+2*T+3+IW+D+3*CW;
reg clk=0;always #5 clk=~clk;
reg rst=1,sv=0,mr=0,sk=0,sl=0;
reg [1:0] sop=0;reg [7:0] sq=0;reg [D-1:0] sd=0;reg [T-1:0] st=0;
wire sr,mv,mk,mfirst,mlast;wire [1:0] mop,ms;
wire [7:0] mq;wire [T-1:0] mt,pt;wire [D-1:0] md;
wire [IW-1:0] mi;wire [CW-1:0] fc,qc,qp;
shared_packet_queues #(.QUEUES(Q),.CELLS(C),.DATA_W(D),.TAG_W(T)) dut(
 .clk(clk),.rst(rst),.s_valid(sv),.s_ready(sr),.s_op(sop),.s_queue(sq),.s_data(sd),
 .s_keep(sk),.s_last(sl),.s_tag(st),.m_valid(mv),.m_ready(mr),.m_op(mop),.m_status(ms),
 .m_queue(mq),.m_tag(mt),.m_keep(mk),.m_first(mfirst),.m_last(mlast),.m_index(mi),
 .m_data(md),.m_packet_tag(pt),.m_free_cells(fc),.m_queue_cells(qc),.m_queue_packets(qp));
reg [INW-1:0] stimuli[0:INPUTS-1];reg [OUTW-1:0] golden[0:OUTPUTS-1];
reg [31:0] latencies[0:COMMANDS-1];
wire [INW-1:0] source={sop,sq,st,sl,sk,sd};
wire [OUTW-1:0] result={mop,ms,mq,mt,mk,mfirst,mlast,mi,md,pt,fc,qc,qp};
reg checking=0,held_o=0,held_s=0,frame_open=0,await_first=0,await_next=0;
reg [OUTW-1:0] old_o;reg [INW-1:0] old_s;
integer cycles=0,sent=0,received=0,tails=0,completed=0,tail_cycle=0,next_cycle=0,expected_latency=0;
integer source_stalls=0,held_cycles=0,phase_resets=0,partitions=0,cell_checks=0,pending_partitions=0,pop_partitions=0;
integer exp_free=C,exp_cells[0:Q-1],exp_packets[0:Q-1];
reg [D+T-1:0] exp_payload[0:Q-1][0:C-1];reg exp_last[0:Q-1][0:C-1];
reg [D+T-1:0] pending_payload[0:C-1];
integer pending_expected=0,initial_free=0,ingress_queue=0;
reg ingress_bad=0;reg [T-1:0] ingress_tag;
reg completion_pending=0;
integer snapshots,rc,q,k,n,tmp_free,tmp_cells,tmp_packets,tmp_last;
reg [D-1:0] tmp_data;reg [T-1:0] tmp_tag;

task automatic check_partition(input reg with_pending,input reg exact_queue);
 integer a,i,j,ends,previous,owned,pend;
 reg [C-1:0] seen;
 begin
  seen=0;owned=0;
  for(i=0;i<Q;i=i+1)begin
   if(exact_queue && (dut.q_cells[i]!==exp_cells[i][CW-1:0] || dut.q_packets[i]!==exp_packets[i][CW-1:0]))$fatal(1,"queue counts q=%0d",i);
   a=dut.q_head[i];ends=0;previous=0;
   for(j=0;j<dut.q_cells[i];j=j+1)begin
    if(a<0 || a>=C || seen[a])$fatal(1,"live cell alias/range");
    seen[a]=1;owned=owned+1;cell_checks=cell_checks+1;
    if(exact_queue && (dut.payload[a]!==exp_payload[i][j] || dut.last_bits[a]!==exp_last[i][j]))$fatal(1,"queued payload/packet boundary q=%0d cell=%0d",i,j);
    if(dut.last_bits[a])ends=ends+1;
    previous=a;a=dut.links[a];
   end
   if(ends!==dut.q_packets[i] || (dut.q_cells[i]!=0 && (previous!==dut.q_tail[i] || !dut.last_bits[previous])))$fatal(1,"packet/tail accounting");
  end
  pend=with_pending?pending_expected:0;
  if(with_pending)begin
   pending_partitions=pending_partitions+1;
   if(dut.pending_count!==pending_expected[CW-1:0])$fatal(1,"provisional allocation count");
   a=dut.pending_head;
   for(j=0;j<pend;j=j+1)begin
    if(a<0 || a>=C || seen[a])$fatal(1,"pending cell alias/range");
    seen[a]=1;owned=owned+1;cell_checks=cell_checks+1;
    if(dut.payload[a]!==pending_payload[j] || dut.last_bits[a]!==0)$fatal(1,"pending payload/visibility");
    if(j==pend-1 && a!==dut.pending_tail)$fatal(1,"pending tail");
    a=dut.links[a];
   end
  end
  if(dut.free_count!==C-owned)$fatal(1,"credit conservation");
  a=dut.free_head;
  for(j=0;j<dut.free_count;j=j+1)begin
   if(a<0 || a>=C || seen[a])$fatal(1,"free cell alias/range");
   seen[a]=1;cell_checks=cell_checks+1;a=dut.links[a];
  end
  if(seen!=={C{1'b1}})$fatal(1,"lost pool ownership");
  if(dut.state==dut.POP_HOLD)begin
   pop_partitions=pop_partitions+1;
   if(dut.walk_node!==dut.q_head[dut.cmd_queue] || dut.payload[dut.walk_node]!=={pt,md} || dut.last_bits[dut.walk_node]!==mlast)$fatal(1,"held pop no longer owns RAM cell");
  end
  partitions=partitions+1;
 end
endtask

task load_snapshot;
 begin
  rc=$fscanf(snapshots,"%d\n",tmp_free);if(rc!=1)$fatal(1,"snapshot header");exp_free=tmp_free;
  for(q=0;q<Q;q=q+1)begin
   rc=$fscanf(snapshots,"%d %d\n",tmp_cells,tmp_packets);if(rc!=2)$fatal(1,"snapshot counts");
   exp_cells[q]=tmp_cells;exp_packets[q]=tmp_packets;
   for(k=0;k<tmp_cells;k=k+1)begin
    rc=$fscanf(snapshots,"%h %h %d\n",tmp_data,tmp_tag,tmp_last);if(rc!=3)$fatal(1,"snapshot cell");
    exp_payload[q][k]={tmp_tag,tmp_data};exp_last[q][k]=tmp_last;
   end
  end
  if(dut.free_count!==exp_free[CW-1:0])$fatal(1,"snapshot free credits");
  check_partition(0,1);
 end
endtask

always @(posedge clk)begin
 cycles=cycles+1;
 if(checking && !rst)begin
  if(held_o && (!mv || result!==old_o))$fatal(1,"held output changed");
  if(held_s && (!sv || source!==old_s))$fatal(1,"held source changed");
  held_o=mv&&!mr;old_o=result;held_s=sv&&!sr;old_s=source;
  if(sv&&!sr)source_stalls=source_stalls+1;
  if(mv&&!mr)held_cycles=held_cycles+1;
  if(sv&&sr)begin
   sent=sent+1;
   if(!frame_open)begin
    pending_expected=0;initial_free=exp_free;ingress_queue=sq;ingress_tag=st;ingress_bad=sq>=Q;
   end
   if(frame_open || sop==0)begin
    if(sk && !ingress_bad)begin
     if(pending_expected<initial_free)begin pending_payload[pending_expected]={ingress_tag,sd};pending_expected=pending_expected+1;end
     else ingress_bad=1;
    end
    frame_open=!sl;
    if(sl)begin tail_cycle=cycles;expected_latency=latencies[tails];tails=tails+1;await_first=1;end
   end else begin tail_cycle=cycles;expected_latency=latencies[tails];tails=tails+1;await_first=1;end
  end
  if(mv&&mr)begin
   if(received>=OUTPUTS || result!==golden[received])$fatal(1,"output %0d got=%h expected=%h",received,result,golden[received]);
   received=received+1;
   if(mk)begin
    for(n=0;n<exp_cells[mq]-1;n=n+1)begin exp_payload[mq][n]=exp_payload[mq][n+1];exp_last[mq][n]=exp_last[mq][n+1];end
    exp_cells[mq]=exp_cells[mq]-1;exp_free=exp_free+1;
    if(mlast)exp_packets[mq]=exp_packets[mq]-1;
   end
   if(mlast)begin completed=completed+1;completion_pending=1;end
   else begin await_next=1;next_cycle=cycles;end
  end
 end
 #1;
 if(checking && !rst && await_first && mv)begin
  if(cycles-tail_cycle!=expected_latency)$fatal(1,"first valid latency got=%0d expected=%0d",cycles-tail_cycle,expected_latency);
  await_first=0;
 end
 if(checking && !rst && await_next && mv)begin
  if(cycles-next_cycle!=1)$fatal(1,"inter-token valid latency");await_next=0;
 end
end
always @(negedge clk)if(checking && !rst)begin
 if(completion_pending)begin load_snapshot();completion_pending=0;end
 else if(dut.state==dut.COLLECT || dut.state==dut.DRAIN)check_partition(1,1);
 else if(dut.state==dut.POP_HOLD)check_partition(0,1);
 else if(dut.state==dut.ACK)check_partition(0,0);
end

task reset_now;
 begin
  rst=1;sv=0;mr=0;
  #1;if(sr || mv)$fatal(1,"reset interface gating");
  @(posedge clk);@(negedge clk);rst=0;
  while(!sr)@(negedge clk);
  if(dut.free_count!==C || mv)$fatal(1,"reset pool reinitialization");
  for(integer x=0;x<Q;x=x+1)if(dut.q_cells[x] || dut.q_packets[x])$fatal(1,"reset retained ownership");
 end
endtask

task beat(input integer op,queue_id,keep,tail,input reg [D-1:0] data);
 begin
  @(negedge clk);sv=1;sop=op;sq=queue_id;sk=keep;sl=tail;sd=data;st=3;
  while(!sr)@(negedge clk);
  @(posedge clk);@(negedge clk);sv=0;
 end
endtask

task make_packet(input integer length);
 begin
  for(integer x=0;x<length;x=x+1)beat(0,0,1,x==length-1,x+1);
  while(!mv)@(negedge clk);
  mr=1;@(posedge clk);@(negedge clk);mr=0;
 end
endtask

task abort_at(input integer target,input integer flushing);
 integer wait_count;
 begin
  reset_now();
  if(target==dut.INIT)begin
   rst=1;@(posedge clk);@(negedge clk);rst=0;
  end else if(target==dut.IDLE)begin end
  else if(target==dut.POP_READ || target==dut.POP_HOLD)begin
   make_packet(1);beat(1,0,0,0,0);
  end else if(target==dut.RECLAIM_READ || target==dut.RECLAIM_WRITE)begin
   if(flushing)begin make_packet(1);beat(2,0,0,0,0);end
   else begin
    for(integer x=0;x<C;x=x+1)beat(0,0,1,0,x);
    beat(0,0,1,1,0);
   end
  end else if(target==dut.DRAIN)beat(0,Q,1,0,0);
  else if(target==dut.ACK)beat(3,0,0,0,0);
  else beat(0,0,1,target==dut.COMMIT,1);
  wait_count=0;
  while(dut.state!=target)begin
   @(negedge clk);wait_count=wait_count+1;if(wait_count>4*C+8)$fatal(1,"reset phase missing %0d",target);
  end
  if(target==dut.POP_HOLD || target==dut.ACK)begin sv=1;sop=3;sq=0;sk=0;sl=1;end
  // Reset asserts at this observed boundary, before another active edge.
  reset_now();phase_resets=phase_resets+1;
 end
endtask

initial begin
 for(integer x=0;x<Q;x=x+1)begin exp_cells[x]=0;exp_packets[x]=0;end
 $readmemh("input.hex",stimuli);$readmemh("golden.hex",golden);$readmemh("latency.hex",latencies);
 for(integer x=0;x<13;x=x+1)abort_at(x,0);
 abort_at(dut.RECLAIM_READ,1);abort_at(dut.RECLAIM_WRITE,1);
 if(C>1)begin
  reset_now();make_packet(2);beat(1,0,0,0,0);
  while(!mv)@(negedge clk);mr=1;@(posedge clk);@(negedge clk);mr=0;
  while(!mv)@(negedge clk);
  reset_now();phase_resets=phase_resets+1;
 end
 reset_now();snapshots=$fopen("snapshots.txt","r");if(!snapshots)$fatal(1,"snapshot file");
 @(negedge clk);checking=1;
 fork
  begin: input_driver
   for(integer x=0;x<INPUTS;x=x+1)begin
    if(x%7==2)repeat(2)@(negedge clk);
    sv=1;{sop,sq,st,sl,sk,sd}=stimuli[x];
    do @(posedge clk);while(!sr);
    @(negedge clk);sv=0;
   end
  end
  begin: output_driver
   reg [OUTW-1:0] held;
   for(integer x=0;x<OUTPUTS;x=x+1)begin
    while(!mv)@(negedge clk);held=result;
    repeat(3)begin @(posedge clk);#1;if(!mv || result!==held)$fatal(1,"forced output hold");end
    @(negedge clk);mr=1;@(posedge clk);@(negedge clk);mr=0;
   end
  end
 join
 repeat(5)@(negedge clk);
 if(sent!=INPUTS || received!=OUTPUTS || completed!=COMMANDS || tails!=COMMANDS || await_first || await_next || mv || !sr)$fatal(1,"incomplete/extra commands");
 if(source_stalls==0 || held_cycles<3*OUTPUTS || pending_partitions==0 || pop_partitions==0)$fatal(1,"missing ownership/stall coverage");
 $fclose(snapshots);
 $display("PASS packets Q=%0d C=%0d D=%0d T=%0d commands=%0d inputs=%0d outputs=%0d phase_resets=%0d source_stalls=%0d held=%0d partitions=%0d pending=%0d heldpop=%0d cell_checks=%0d",Q,C,D,T,COMMANDS,sent,received,phase_resets,source_stalls,held_cycles,partitions,pending_partitions,pop_partitions,cell_checks);
 $finish;
end
initial begin #100000000;$fatal(1,"watchdog");end
endmodule
