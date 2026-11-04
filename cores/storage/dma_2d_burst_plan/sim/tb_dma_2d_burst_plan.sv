// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb;
parameter integer A=32,B=4,M=16,T=8,INPUTS=1,OUTPUTS=1;
localparam INW=2*A+49+T,OUTW=127+A+T+2*B;
reg clk=0;always #5 clk=~clk;
reg rst=1,sv=0,mr=0;
reg [A-1:0] sb=0;reg [31:0] sn=0;reg [15:0] srw=0;
reg signed [A:0] ss=0;reg [T-1:0] st=0;
wire ready,valid,keep,rf,rl,first,last;
wire [1:0] status;wire [T-1:0] tag;wire [A-1:0] addr;
wire [8:0] beats;wire [14:0] bytes;
wire [B-1:0] fm,lm;wire [15:0] row;wire [31:0] roff;wire [47:0] off;
dma_2d_burst_plan #(.ADDR_W(A),.DATA_BYTES(B),.MAX_BURST_BEATS(M),.TAG_W(T)) dut(
 .clk(clk),.rst(rst),.s_valid(sv),.s_ready(ready),.s_base(sb),.s_row_bytes(sn),
 .s_rows(srw),.s_stride(ss),.s_tag(st),.m_valid(valid),.m_ready(mr),.m_status(status),
 .m_tag(tag),.m_keep(keep),.m_addr(addr),.m_beats(beats),.m_bytes(bytes),
 .m_first_mask(fm),.m_last_mask(lm),.m_row(row),.m_row_offset(roff),.m_offset(off),
 .m_row_first(rf),.m_row_last(rl),.m_first(first),.m_last(last));
wire [INW-1:0] source={sb,sn,srw,ss,st};
wire [OUTW-1:0] result={status,tag,keep,addr,beats,bytes,fm,lm,row,roff,off,rf,rl,first,last};
reg [INW-1:0] stimuli[0:INPUTS-1];reg [OUTW-1:0] golden[0:OUTPUTS-1];
reg [31:0] latencies[0:INPUTS-1];
reg checking=0,held_s=0,held_o=0,await_first=0,await_next=0;
reg [INW-1:0] old_s;reg [OUTW-1:0] old_o;
integer cycles=0,sent=0,received=0,completed=0,started=0,next_cycle=0,latency=0;
integer source_stalls=0,held_cycles=0,phase_resets=0,recoveries=0;
integer mask_checks=0,source_idle=0;

always @(posedge clk)begin
 cycles=cycles+1;
 if(checking && !rst)begin
  if(held_s && (!sv || source!==old_s))$fatal(1,"held source changed");
  if(held_o && (!valid || result!==old_o))$fatal(1,"held output changed");
  held_s=sv&&!ready;old_s=source;held_o=valid&&!mr;old_o=result;
  if(sv&&!ready)source_stalls=source_stalls+1;
  if(!sv)source_idle=source_idle+1;
  if(valid&&!mr)held_cycles=held_cycles+1;
  if(sv&&ready)begin
   if(sent>=INPUTS)$fatal(1,"extra input");
   started=cycles;latency=latencies[sent];sent=sent+1;await_first=1;
  end
  if(valid&&mr)begin
   if(received>=OUTPUTS || result!==golden[received])
    $fatal(1,"output %0d got=%h expected=%h",received,result,golden[received]);
   received=received+1;
   if(keep)begin
    if(status!=0 || beats<1 || beats>M || addr%B!=0 ||
       (addr%4096)+beats*B>4096 || bytes==0 || fm==0 || lm==0)
     $fatal(1,"burst geometry");
    if(beats==1 && fm!==lm)$fatal(1,"single beat masks");
    mask_checks=mask_checks+1;
   end
   if(last)completed=completed+1;
   else begin await_next=1;next_cycle=cycles;end
  end
 end
 #1;
 if(checking && !rst && await_first)begin
  if(valid)begin
   if(cycles-started!=latency)$fatal(1,"first valid latency %0d expected %0d",cycles-started,latency);
   await_first=0;
  end else if(cycles-started>=latency)$fatal(1,"missing first valid");
 end
 if(checking && !rst && await_next && valid)begin
  if(cycles-next_cycle!=1)$fatal(1,"next plan latency");await_next=0;
 end
end

task reset_now;
 begin
  // Called immediately at the observed target, with no intervening clock wait.
  rst=1;sv=0;mr=0;
  #1;if(ready || valid)$fatal(1,"reset interface gating");
  @(posedge clk);#1;
  if(dut.state!==dut.IDLE)$fatal(1,"reset ownership");
  @(negedge clk);rst=0;
  #1;if(!ready || valid)$fatal(1,"reset recovery ready");
 end
endtask

task launch(input reg [A-1:0] base,input reg [31:0] n,
 input reg [15:0] rows,input reg signed [A:0] stride);
 begin
  @(negedge clk);sv=1;sb=base;sn=n;srw=rows;ss=stride;st={T{1'b1}};
  if(!ready)$fatal(1,"probe launch not ready");
  @(posedge clk);#1;sv=0;
 end
endtask

task recover_one;
 integer wait_count;
 begin
  launch(0,1,1,{1'b1,{A{1'b0}}});
  wait_count=0;
  while(!valid)begin @(posedge clk);#1;wait_count=wait_count+1;
   if(wait_count>18)$fatal(1,"recovery timeout");end
  if(wait_count!=18 || status!==0 || !keep || addr!==0 || beats!==1 || bytes!==1 ||
   fm!=={{(B-1){1'b0}},1'b1} || lm!=={{(B-1){1'b0}},1'b1} ||
   row!==0 || roff!==0 || off!==0 || !rf || !rl || !first || !last || tag!=={T{1'b1}})
   $fatal(1,"fresh recovery token");
  @(negedge clk);mr=1;@(posedge clk);#1;
  if(valid || !ready)$fatal(1,"fresh recovery completion");
  @(negedge clk);mr=0;
  repeat(3)begin @(posedge clk);#1;if(valid || !ready)$fatal(1,"reset stale output");end
  recoveries=recoveries+1;
 end
endtask

task finish_reset;
 begin reset_now();phase_resets=phase_resets+1;recover_one();end
endtask

task phase_probe(input integer target,input integer mode);
 integer count;
 begin
  reset_now();
  if(target==dut.IDLE)begin end
  else begin
   if(mode==1)launch(0,0,16'hffff,{1'b1,{A{1'b0}}});
   else if(mode==2)launch(0,1,2,-1);
   else if(mode==3)launch(0,32'hffffffff,1,0);
   else launch((A==12)?4061:4093,9,3,-5);
   count=0;
   while(!(dut.state==target && (target!=dut.MUL || dut.mul_bit==mode)))begin
    @(posedge clk);#1;count=count+1;
    if(count>20)$fatal(1,"phase missing target=%0d mode=%0d",target,mode);
   end
  end
  finish_reset();
 end
endtask

task output_probe(input integer which);
 integer count;
 reg found;
 begin
  reset_now();launch(0,3*B*M+3,3,0);
  count=0;found=0;
  while(!found)begin
   if(valid)begin
    if((which==0 && first) || (which==1 && !first && !rl) ||
       (which==2 && rl && !last) || (which==3 && last))found=1;
    else begin
     @(negedge clk);mr=1;@(posedge clk);#1;mr=0;
    end
   end else begin @(posedge clk);#1;end
   count=count+1;
   if(count>1000)$fatal(1,"output reset boundary missing %0d",which);
  end
  // Both a new held command and a valid plan are present at this boundary.
  sv=1;sb=0;sn=0;srw=0;ss=0;st=0;
  if(ready)$fatal(1,"descriptor ownership leaked");
  finish_reset();
 end
endtask

task huge_row_probe;
 integer count,effective;
 begin
  reset_now();launch(0,32'hffffffff,1,0);
  count=0;
  while(!valid)begin @(posedge clk);#1;count=count+1;
   if(count>18)$fatal(1,"huge row preflight timeout");end
  if(A<32)begin
   if(count!=17 || status!==2 || keep || !first || !last || addr!==0 || bytes!==0)
    $fatal(1,"huge row canonical rejection");
  end else begin
   effective=(M<4096/B)?M:4096/B;
   if(count!=18 || status!==0 || !keep || addr!==0 || beats!==effective ||
      bytes!==effective*B || fm!=={B{1'b1}} || lm!=={B{1'b1}} ||
      !first || !rf || rl || last || roff!==0 || off!==0)
    $fatal(1,"huge unsigned row prefix");
  end
  // No extra edge is allowed between observing this prefix and asserting rst.
  finish_reset();
 end
endtask

initial begin
 $readmemh("input.hex",stimuli);$readmemh("golden.hex",golden);$readmemh("latency.hex",latencies);
 phase_probe(dut.IDLE,0);
 phase_probe(dut.MUL,0);phase_probe(dut.MUL,7);phase_probe(dut.MUL,15);
 phase_probe(dut.CHECK,0);phase_probe(dut.PLAN,0);
 phase_probe(dut.HOLD,1);phase_probe(dut.HOLD,2);
 // A huge valid row is interrupted before emission; small address profiles
 // instead probe rejection. This is a prefix/reset check, not full coverage.
 phase_probe(dut.CHECK,3);
 for(integer x=0;x<4;x=x+1)output_probe(x);
 huge_row_probe();
 reset_now();
 @(negedge clk);checking=1;
 fork
  begin: input_driver
   for(integer x=0;x<INPUTS;x=x+1)begin
    if(x%7==3)repeat(2)@(negedge clk);
    sv=1;{sb,sn,srw,ss,st}=stimuli[x];
    do @(posedge clk);while(!ready);
    @(negedge clk);sv=0;
   end
  end
  begin: output_driver
   reg [OUTW-1:0] held;
   for(integer x=0;x<OUTPUTS;x=x+1)begin
    while(!valid)@(negedge clk);held=result;
    repeat(3)begin @(posedge clk);#1;if(!valid || result!==held)$fatal(1,"forced output hold");end
    @(negedge clk);mr=1;@(posedge clk);@(negedge clk);mr=0;
   end
  end
 join
 repeat(5)@(negedge clk);
 if(sent!=INPUTS || received!=OUTPUTS || completed!=INPUTS || valid || !ready || await_first || await_next)
  $fatal(1,"incomplete/extra descriptor");
 if(source_stalls==0 || held_cycles<3*OUTPUTS || mask_checks==0 || recoveries!=phase_resets || source_idle==0)
  $fatal(1,"missing stall/reset coverage");
 $display("PASS dma2d A=%0d B=%0d M=%0d T=%0d inputs=%0d outputs=%0d phase_resets=%0d recoveries=%0d source_stalls=%0d held=%0d masks=%0d idle=%0d",A,B,M,T,sent,received,phase_resets,recoveries,source_stalls,held_cycles,mask_checks,source_idle);
 $finish;
end
initial begin #200000000;$fatal(1,"watchdog");end
endmodule
