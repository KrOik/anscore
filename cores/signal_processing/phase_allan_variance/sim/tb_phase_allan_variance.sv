// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_phase_allan_variance;
 parameter integer D=16,M=256,MM=64,T=8,EX=0;
 localparam SW=2*D+2+$clog2(M),VW=2*D+18,RN=EX?256:(M<17?M:17);
 reg clk=0,rst=1,c_valid=0,s_valid=0,s_marker=0,s_invalid=0,m_ready=0;
 always #5 clk=~clk;
 reg [31:0]c_samples=0,c_m=0;
 reg [T-1:0]c_tag=0;
 reg signed[D-1:0]s_phase=0;
 wire c_ready,s_ready,m_valid;
 wire [2:0]m_status;
 wire [T-1:0]m_tag;
 wire [31:0]m_samples,m_m;
 wire [12:0]m_received,m_terms;
 wire [SW-1:0]m_sum;
 wire [24:0]m_den;
 wire [VW-1:0]m_variance_q16;
 wire [3:0]state_view;
 wire divide_valid,multiply_reset_view;
 generate if(EX)begin:g_dut
  trigger_phase_allan256 dut(.clk(clk),.rst(rst),.a_valid(c_valid),.a_ready(c_ready),.a_m(c_m),.a_tag(c_tag),
   .s_valid(s_valid),.s_ready(s_ready),.s_phase(s_phase),.s_trigger(s_marker),.s_invalid(s_invalid),
   .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_tag(m_tag),.m_samples(m_samples),.m_m(m_m),
   .m_received(m_received),.m_terms(m_terms),.m_sum(m_sum),.m_den(m_den),.m_variance_q16(m_variance_q16));
  assign state_view=dut.measure.state;assign divide_valid=dut.measure.divide_valid;
  assign multiply_reset_view=dut.measure.multiply_rst_n;
  task inject;begin force dut.measure.divide_flags=2'b01;@(posedge clk);@(negedge clk);release dut.measure.divide_flags;end endtask
 end else begin:g_dut
  phase_allan_variance #(.DATA_W(D),.MAX_SAMPLES(M),.MAX_M(MM),.TAG_W(T)) dut(
   .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_samples(c_samples),.c_m(c_m),.c_tag(c_tag),
   .s_valid(s_valid),.s_ready(s_ready),.s_phase(s_phase),.s_last(s_marker),.s_invalid(s_invalid),
   .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_tag(m_tag),.m_samples(m_samples),.m_m(m_m),
   .m_received(m_received),.m_terms(m_terms),.m_sum(m_sum),.m_den(m_den),.m_variance_q16(m_variance_q16));
  assign state_view=dut.state;assign divide_valid=dut.divide_valid;
  assign multiply_reset_view=dut.multiply_rst_n;
  task inject;begin force dut.divide_flags=2'b01;@(posedge clk);@(negedge clk);release dut.divide_flags;end endtask
 end endgenerate
 localparam B=3+T+64+26+SW+25+VW;
 wire [B-1:0]bundle={m_status,m_tag,m_samples,m_m,m_received,m_terms,m_sum,m_den,m_variance_q16};
 reg [B-1:0]saved;
 reg held=0;
 integer commands=0,samples=0,records=0,resets=0,faults=0,held_cycles=0,ii_checks=0,max_wait=0;
 time previous_sample;
 always @(posedge clk)begin
  if(rst)held=0;
  else begin
   if(held&&(!m_valid||bundle!==saved))$fatal(1,"held result changed");
   held=m_valid&&!m_ready;saved=bundle;if(held)held_cycles=held_cycles+1;
  end
 end
 always @(multiply_reset_view)if($time>0&&multiply_reset_view===0&&clk!==1)$fatal(1,"asynchronous reset origin");
 task reset_now;
  integer k;
  begin
   rst=1;c_valid=0;s_valid=0;m_ready=0;
   repeat(2)begin @(posedge clk);#1;if(c_ready||s_ready||m_valid)$fatal(1,"reset gating");end
   @(negedge clk);rst=0;resets=resets+1;k=0;
   while(!c_ready)begin @(negedge clk);k=k+1;if(k>8)$fatal(1,"reset recovery");end
   if(m_valid)$fatal(1,"reset leaked result");
  end
 endtask
 task command(input[31:0]n,m,input[T-1:0]tag);
  integer k;
  begin
   @(negedge clk);c_valid=1;c_samples=n;c_m=m;c_tag=tag;k=0;
   @(posedge clk);while(!c_ready)begin @(negedge clk);k=k+1;if(k>8)$fatal(1,"command deadline");@(posedge clk);end
   commands=commands+1;previous_sample=0;
   @(negedge clk);c_valid=0;c_samples=32'hffffffff;c_m=32'hffffffff;c_tag=~tag;
  end
 endtask
 task sample(input signed[D-1:0]x,input marker,invalid,input integer gap);
  integer k;
  begin
   repeat(gap)@(negedge clk);
   s_valid=1;s_phase=x;s_marker=marker;s_invalid=invalid;k=0;
   @(posedge clk);while(!s_ready)begin @(negedge clk);k=k+1;if(k>12)$fatal(1,"sample deadline");@(posedge clk);end
   if(previous_sample!=0&&gap==0)begin if($time-previous_sample!=10)$fatal(1,"input II1");ii_checks=ii_checks+1;end
   previous_sample=$time;samples=samples+1;
   @(negedge clk);s_valid=0;s_phase=~x;s_marker=~marker;s_invalid=~invalid;
  end
 endtask
 task expect_result(input[2:0]status,input[31:0]n,m,input[12:0]received,terms,
  input[63:0]total,den,result,input[T-1:0]tag,input integer hold_count,budget);
  integer k;
  begin
   k=0;m_ready=0;c_valid=1;s_valid=1;
   while(!m_valid)begin
    if(c_ready||s_ready)$fatal(1,"owned transaction readiness");
    @(negedge clk);k=k+1;if(k>budget)$fatal(1,"result deadline state%0d",state_view);
   end
   if(k>max_wait)max_wait=k;
   if(m_status!==status||m_samples!==n||m_m!==m||m_received!==received||m_terms!==terms||
      m_sum!==total[SW-1:0]||m_den!==den[24:0]||m_variance_q16!==result[VW-1:0]||m_tag!==tag||c_ready||s_ready)
    $fatal(1,"result got st%0d n%0d m%0d recv%0d K%0d sum%0d den%0d q%0d tag%h expected st%0d n%0d m%0d recv%0d K%0d sum%0d den%0d q%0d tag%h",
     m_status,m_samples,m_m,m_received,m_terms,m_sum,m_den,m_variance_q16,m_tag,status,n,m,received,terms,total,den,result,tag);
   repeat(hold_count)begin @(negedge clk);if(!m_valid||c_ready||s_ready)$fatal(1,"held ownership");end
   m_ready=1;@(posedge clk);if(c_ready)$fatal(1,"retirement fallthrough");
   @(negedge clk);m_ready=0;c_valid=0;s_valid=0;records=records+1;
   if(m_valid)$fatal(1,"duplicate result");
   k=0;while(!c_ready)begin @(negedge clk);k=k+1;if(k>8)$fatal(1,"rearm deadline");end
  end
 endtask
 task fill_zero;
  integer j;
  begin
   command(RN,1,1);
   for(j=0;j<RN;j=j+1)sample(0,EX?(j==0):(j==RN-1),0,0);
  end
 endtask
 task recovery;
  begin fill_zero;expect_result(0,RN,1,RN,RN-2,0,2*(RN-2),0,1,3,40*RN+512);end
 endtask
 integer fd,rc,op,iv,marker,invalid,gap,hold_count,budget,st,j,k;
 reg [1023:0]vector_path;
 reg [31:0]vn,vm;
 reg [T-1:0]vtag;
 reg [2:0]vstatus;
 reg [12:0]vreceived,vterms;
 reg [63:0]vsum,vden,vresult;
 initial begin
  if(!$value$plusargs("vectors=%s",vector_path))$fatal(1,"missing vectors");
  fd=$fopen(vector_path,"r");if(!fd)$fatal(1,"vector open");
  reset_now;
  begin: vector_loop
   forever begin
    rc=$fscanf(fd,"%d",op);if(rc!=1)$fatal(1,"bad vector opcode");
    case(op)
     0:disable vector_loop;
     1:begin rc=$fscanf(fd,"%d %d %d",vn,vm,vtag);if(rc!=3)$fatal(1,"command row");command(vn,vm,vtag);end
     2:begin rc=$fscanf(fd,"%d %d %d %d",iv,marker,invalid,gap);if(rc!=4)$fatal(1,"sample row");sample(D'(iv),marker!=0,invalid!=0,gap);end
     3:begin
      rc=$fscanf(fd,"%d %d %d %d %d %d %d %d %d %d %d",vstatus,vn,vm,vreceived,vterms,vsum,vden,vresult,vtag,hold_count,budget);
      if(rc!=11)$fatal(1,"result row");expect_result(vstatus,vn,vm,vreceived,vterms,vsum,vden,vresult,vtag,hold_count,budget);
     end
     default:$fatal(1,"unknown opcode");
    endcase
   end
  end
  $fclose(fd);
  // Cancel every active state, including multiplier CSA/fold ownership,
  // both denominator operations, division, and a held output. Recover each.
  for(st=1;st<=15;st=st+1)begin
   if(st==1)command(RN,1,1);else fill_zero;
   k=0;while(state_view!=st)begin @(negedge clk);k=k+1;if(k>40*RN+512)$fatal(1,"reset phase unreachable %0d",st);end
   reset_now;recovery;
  end
  command(RN,1,1);
  for(j=0;j<(RN-1<7?RN-1:7);j=j+1)sample(0,EX?(j==0):0,0,0);
  reset_now;recovery;
  fill_zero;k=0;
  while(!(state_view==14&&divide_valid))begin @(negedge clk);k=k+1;if(k>40*RN+512)$fatal(1,"fault phase deadline");end
  g_dut.inject;faults=faults+1;
  expect_result(5,RN,1,RN,0,0,0,0,1,4,8);recovery;
  if(held_cycles<20||ii_checks<10)$fatal(1,"insufficient flow-control coverage");
  $display("PASS phase_allan_variance D=%0d M=%0d MM=%0d T=%0d EX=%0d commands=%0d samples=%0d records=%0d resets=%0d faults=%0d held_cycles=%0d ii_checks=%0d max_wait=%0d",
   D,M,MM,T,EX,commands,samples,records,resets,faults,held_cycles,ii_checks,max_wait);
  $finish;
 end
 initial begin #400000000;$fatal(1,"global watchdog");end
endmodule
