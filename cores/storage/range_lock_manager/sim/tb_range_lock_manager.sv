// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb;
 parameter integer A=32,S=8,G=8,O=8,T=8,COMMANDS=1;
 localparam CW=$clog2(S+1),EW=2*A+G+O+2,INW=36+2*A+O+G+T,OUTW=39+T+G+O+2*A+S+3*CW;
 reg clk=0;always #5 clk=~clk;
 reg rst=1,sv=0,mr=0;reg [1:0] op=0;reg [A-1:0] base=0;reg [A:0] length=0;
 reg exclusive=0;reg [O-1:0] owner=0;reg [31:0] slot=0;reg [G-1:0] generation=0;reg [T-1:0] tag=0;
 wire ready,valid,mode;wire [1:0] mop;wire [2:0] status;wire [T-1:0] mt;
 wire [31:0] ms;wire [G-1:0] mg;wire [O-1:0] mo;wire [A-1:0] mb;wire [A:0] ml;
 wire [S-1:0] conflicts;wire [CW-1:0] live,free_slots,retired;
 range_lock_manager #(.ADDR_W(A),.SLOTS(S),.GEN_W(G),.OWNER_W(O),.TAG_W(T)) dut(
  .clk(clk),.rst(rst),.s_valid(sv),.s_ready(ready),.s_op(op),.s_base(base),.s_length(length),
  .s_exclusive(exclusive),.s_owner(owner),.s_slot(slot),.s_generation(generation),.s_tag(tag),
  .m_valid(valid),.m_ready(mr),.m_op(mop),.m_status(status),.m_tag(mt),.m_slot(ms),
  .m_generation(mg),.m_owner(mo),.m_base(mb),.m_length(ml),.m_exclusive(mode),
  .m_conflicts(conflicts),.m_live(live),.m_free(free_slots),.m_retired(retired));
 wire [INW-1:0] source={op,base,length,exclusive,owner,slot,generation,tag};
 wire [OUTW-1:0] result={mop,status,mt,ms,mg,mo,mb,ml,mode,conflicts,live,free_slots,retired};
 reg [INW-1:0] inputs[0:COMMANDS-1];reg [OUTW-1:0] golden[0:COMMANDS-1];
 reg [31:0] latencies[0:COMMANDS-1];reg [EW-1:0] snapshots[0:COMMANDS*S-1];
 reg [EW-1:0] expected[0:S-1],frozen[0:S-1];
 reg checking=0,held_s=0,held_o=0,await_first=0;reg [INW-1:0] old_s;reg [OUTW-1:0] old_o;
 integer cycles=0,sent=0,received=0,started=0,latency=0;
 integer source_stalls=0,held_cycles=0,table_checks=0,entry_checks=0,phase_resets=0,recoveries=0;

 task check_table;
  integer l,r;
  begin
   l=0;r=0;
   for(integer x=0;x<S;x=x+1)begin
    if(dut.entries[x]!==expected[x])$fatal(1,"table ownership command=%0d slot=%0d",received,x);
    l=l+expected[x][EW-1];
    if(!expected[x][EW-1] && (&expected[x][2*A+:G]))r=r+1;
    entry_checks=entry_checks+1;
   end
   if(dut.live_count!==l || dut.free_count!==S-l-r || dut.retired_count!==r)$fatal(1,"table ledger");
   table_checks=table_checks+1;
  end
 endtask
 always @(posedge clk)begin
  cycles=cycles+1;
  if(checking && !rst)begin
   if(held_s && (!sv || source!==old_s))$fatal(1,"held source changed");
   if(held_o && (!valid || result!==old_o))$fatal(1,"held result changed");
   held_s=sv&&!ready;old_s=source;held_o=valid&&!mr;old_o=result;
   if(sv&&!ready)source_stalls=source_stalls+1;
   if(valid&&!mr)held_cycles=held_cycles+1;
   if(sv&&ready)begin started=cycles;latency=latencies[sent];sent=sent+1;await_first=1;end
   if(valid&&mr)begin
    if(received>=COMMANDS || result!==golden[received])$fatal(1,"response %0d got=%h expected=%h",received,result,golden[received]);
    for(integer x=0;x<S;x=x+1)expected[x]=snapshots[received*S+x];
    received=received+1;
   end
  end
  #1;
  if(checking && !rst)begin
   check_table();
   if(await_first)begin
    if(valid)begin
     if(cycles-started!=latency)$fatal(1,"first result latency got=%0d expected=%0d",cycles-started,latency);
     await_first=0;
    end else if(cycles-started>=latency)$fatal(1,"missing result");
   end
  end
 end

 task reset_now;
  integer count;
  begin
   rst=1;sv=0;mr=0;
   #1;if(ready || valid)$fatal(1,"reset gating");
   @(posedge clk);#1;
   if(dut.state!==dut.INIT || dut.cursor!==0)$fatal(1,"reset ownership");
   @(negedge clk);rst=0;count=0;
   while(!ready)begin @(posedge clk);#1;count=count+1;if(count>S)$fatal(1,"reset init bound");end
   for(integer x=0;x<S;x=x+1)if(dut.entries[x]!==0)$fatal(1,"reset table clear");
   if(dut.live_count!==0 || dut.free_count!==S || dut.retired_count!==0 || valid)$fatal(1,"reset ledger");
  end
 endtask
 task send(input integer operation,input reg [A-1:0] start,input reg [A:0] size,
  input integer mode_value,input reg [O-1:0] identity,input integer index,input reg [G-1:0] epoch);
  begin
   @(negedge clk);sv=1;op=operation;base=start;length=size;exclusive=mode_value;owner=identity;slot=index;generation=epoch;tag={T{1'b1}};
   if(!ready)$fatal(1,"probe command not ready");
   @(posedge clk);#1;sv=0;
  end
 endtask
 task wait_result;
  integer count;
  begin
   count=0;
   while(!valid)begin @(posedge clk);#1;count=count+1;if(count>2*S+3)$fatal(1,"probe result timeout");end
  end
 endtask
 task accept_result;
  begin @(negedge clk);mr=1;@(posedge clk);#1;if(valid || !ready)$fatal(1,"probe commit");@(negedge clk);mr=0;end
 endtask
 task acquire_one(input integer index);
  begin
   send(0,0,1,0,{O{1'b1}},0,0);wait_result();
   if(status!==0 || ms!==index || mg!==1 || ml!==1 || mb!==0)$fatal(1,"setup acquisition");
   accept_result();
  end
 endtask
 task fresh;
  begin
   acquire_one(0);
   if(!dut.entries[0][EW-1])$fatal(1,"fresh acquire not committed");
   send(1,0,0,0,{O{1'b1}},0,1);wait_result();
   if(status!==0 || ms!==0 || mg!==1 || mo!=={O{1'b1}} || mb!==0 || ml!==1 || mode ||
      live!==0 || retired!==((G==1)?1:0) || free_slots!==S-((G==1)?1:0))$fatal(1,"fresh release ledger");
   accept_result();
   send(3,{A{1'b1}},{(A+1){1'b1}},1,0,-1,0);wait_result();
   if(status!==0 || ms!==0 || mg!==0 || mo!==0 || mb!==0 || ml!==0 || mode || conflicts!==0 ||
      live!==0 || retired!==((G==1)?1:0) || free_slots!==S-((G==1)?1:0))$fatal(1,"fresh snapshot");
   accept_result();
   repeat(3)begin @(posedge clk);#1;if(valid || !ready)$fatal(1,"fresh stale response");end
   recoveries=recoveries+1;
  end
 endtask
 task finish_reset;
  begin reset_now();phase_resets=phase_resets+1;fresh();end
 endtask
 task init_probe(input integer index);
  begin
   rst=1;sv=0;mr=0;@(posedge clk);#1;@(negedge clk);rst=0;
   while(dut.cursor!=index)begin @(posedge clk);#1;end
   if(dut.state!=dut.INIT)$fatal(1,"init reset phase");
   // Target observed now; reset asserts without another active edge.
   finish_reset();
  end
 endtask
 task state_probe(input integer phase,input integer index);
  integer count;
  begin
   reset_now();
   if(phase!=dut.IDLE)begin
    if(phase==dut.TARGET_READ || phase==dut.TARGET_CHECK)begin acquire_one(0);send(2,2,1,1,{O{1'b1}},0,1);end
    else send(0,0,1,0,0,0,0);
    count=0;
    while(!(dut.state==phase && ((phase!=dut.SCAN_READ && phase!=dut.SCAN_CHECK)||dut.cursor==index)))begin
     @(posedge clk);#1;count=count+1;if(count>2*S+4)$fatal(1,"state reset phase %0d",phase);
    end
   end
   finish_reset();
  end
 endtask
 task held_probe(input integer kind);
  integer expected_status;
  begin
   reset_now();expected_status=0;
   if(kind>=1 && kind<=4)acquire_one(0);
   if(kind==5)for(integer x=0;x<S;x=x+1)acquire_one(x);
   for(integer x=0;x<S;x=x+1)frozen[x]=dut.entries[x];
   case(kind)
    0:send(0,0,1,1,0,0,0);
    1:send(2,2,1,1,{O{1'b1}},0,1);
    2:send(1,0,0,0,{O{1'b1}},0,1);
    3:begin send(2,{A{1'b1}},2,1,{O{1'b1}},0,1);expected_status=1;end
    4:begin send(0,0,1,1,0,0,0);expected_status=2;end
    5:begin send(0,10,1,1,0,0,0);expected_status=3;end
    6:send(3,0,0,0,0,0,0);
    7:begin send(1,0,0,0,0,-1,0);expected_status=4;end
   endcase
   wait_result();
   if(status!==expected_status)$fatal(1,"held reset status");
   sv=1;op=3;base=0;length=0;exclusive=0;owner=0;slot=0;generation=0;tag=0;
   // The target here is four actual held-result/blocked-source clock edges.
   repeat(4)begin
    @(posedge clk);#1;if(!valid || ready)$fatal(1,"held reset boundary");
    for(integer x=0;x<S;x=x+1)if(dut.entries[x]!==frozen[x])$fatal(1,"premature table commit");
   end
   finish_reset();
  end
 endtask
 initial begin
  $readmemh("input.hex",inputs);$readmemh("golden.hex",golden);$readmemh("latency.hex",latencies);$readmemh("table.hex",snapshots);
  init_probe(0);init_probe(S/2);init_probe(S-1);
  state_probe(dut.IDLE,0);state_probe(dut.TARGET_READ,0);state_probe(dut.TARGET_CHECK,0);
  state_probe(dut.SCAN_READ,0);state_probe(dut.SCAN_READ,S/2);state_probe(dut.SCAN_READ,S-1);
  state_probe(dut.SCAN_CHECK,0);state_probe(dut.SCAN_CHECK,S/2);state_probe(dut.SCAN_CHECK,S-1);
  state_probe(dut.DECIDE,0);state_probe(dut.HOLD,0);
  for(integer x=0;x<8;x=x+1)held_probe(x);
  reset_now();for(integer x=0;x<S;x=x+1)expected[x]=0;
  @(negedge clk);checking=1;
  fork
   begin: source_driver
    for(integer x=0;x<COMMANDS;x=x+1)begin
     if(x%7==3)repeat(2)@(negedge clk);
     sv=1;{op,base,length,exclusive,owner,slot,generation,tag}=inputs[x];
     do @(posedge clk);while(!ready);
     @(negedge clk);sv=0;
    end
   end
   begin: sink_driver
    reg [OUTW-1:0] held;
    for(integer x=0;x<COMMANDS;x=x+1)begin
     while(!valid)@(negedge clk);held=result;
     repeat(3)begin @(posedge clk);#1;if(!valid || result!==held)$fatal(1,"forced result hold");end
     @(negedge clk);mr=1;@(posedge clk);@(negedge clk);mr=0;
    end
   end
  join
  repeat(4)@(negedge clk);
  if(sent!=COMMANDS || received!=COMMANDS || valid || !ready || await_first || source_stalls==0 ||
     held_cycles<3*COMMANDS || recoveries!=phase_resets || table_checks==0)$fatal(1,"incomplete ownership checks");
  $display("PASS locks A=%0d S=%0d G=%0d O=%0d T=%0d commands=%0d phase_resets=%0d recoveries=%0d source_stalls=%0d held=%0d tables=%0d entries=%0d",A,S,G,O,T,sent,phase_resets,recoveries,source_stalls,held_cycles,table_checks,entry_checks);
  $finish;
 end
 initial begin #200000000;$fatal(1,"watchdog");end
endmodule
