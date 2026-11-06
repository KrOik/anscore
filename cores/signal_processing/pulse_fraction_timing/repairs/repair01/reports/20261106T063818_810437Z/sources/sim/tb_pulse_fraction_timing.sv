// SPDX-License-Identifier: Apache-2.0
`timescale 1ns/1ps
module tb_pulse_fraction_timing;
 parameter integer D=12,M=256,T=8,EX=0;
 localparam I=$clog2(M),TW=I+16;
 reg clk=0,rst=1,c_valid=0,s_valid=0,s_marker=0,m_ready=0;
 always #5 clk=~clk;
 reg[31:0]c_samples=0,c_fraction=0;
 reg signed[D-1:0]c_baseline=0,s_sample=0;
 reg c_negative=0;
 reg[D-1:0]c_min_peak=0;
 reg[T-1:0]c_tag=0;
 wire c_ready,s_ready,m_valid;
 wire[3:0]m_status,state_view;
 wire[T-1:0]m_tag;
 wire[D-1:0]m_peak;
 wire[I-1:0]m_peak_index;
 wire[1:0]m_sides;
 wire[TW-1:0]m_left_q16,m_right_q16,m_width_q16;
 wire divider_valid,multiply_reset_view;
 generate if(EX)begin:g_dut
  trigger_pulse256 dut(.clk(clk),.rst(rst),.a_valid(c_valid),.a_ready(c_ready),
   .a_baseline(c_baseline),.a_negative(c_negative),.a_fraction(c_fraction),.a_min_peak(c_min_peak),.a_tag(c_tag),
   .s_valid(s_valid),.s_ready(s_ready),.s_sample(s_sample),.s_trigger(s_marker),
   .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_tag(m_tag),.m_peak(m_peak),.m_peak_index(m_peak_index),
   .m_sides(m_sides),.m_left_q16(m_left_q16),.m_right_q16(m_right_q16),.m_width_q16(m_width_q16));
  assign state_view=dut.measure.state;assign divider_valid=dut.measure.divide_valid;
  assign multiply_reset_view=dut.measure.multiply_rst_n;
  task inject;begin force dut.measure.divide_flags=2'b01;@(posedge clk);@(negedge clk);release dut.measure.divide_flags;end endtask
 end else begin:g_dut
  pulse_fraction_timing #(.DATA_W(D),.MAX_SAMPLES(M),.TAG_W(T)) dut(
   .clk(clk),.rst(rst),.c_valid(c_valid),.c_ready(c_ready),.c_samples(c_samples),.c_fraction(c_fraction),
   .c_baseline(c_baseline),.c_negative(c_negative),.c_min_peak(c_min_peak),.c_tag(c_tag),
   .s_valid(s_valid),.s_ready(s_ready),.s_sample(s_sample),.s_last(s_marker),
   .m_valid(m_valid),.m_ready(m_ready),.m_status(m_status),.m_tag(m_tag),.m_peak(m_peak),.m_peak_index(m_peak_index),
   .m_sides(m_sides),.m_left_q16(m_left_q16),.m_right_q16(m_right_q16),.m_width_q16(m_width_q16));
  assign state_view=dut.state;assign divider_valid=dut.divide_valid;
  assign multiply_reset_view=dut.multiply_rst_n;
  task inject;begin force dut.divide_flags=2'b01;@(posedge clk);@(negedge clk);release dut.divide_flags;end endtask
 end endgenerate
 localparam B=4+T+D+I+2+3*TW;
 wire[B-1:0]bundle={m_status,m_tag,m_peak,m_peak_index,m_sides,m_left_q16,m_right_q16,m_width_q16};
 reg[B-1:0]saved;
 reg held=0;
 integer commands=0,samples=0,records=0,resets=0,faults=0,held_cycles=0,ii_checks=0,max_wait=0;
 time previous_sample;
 always @(posedge clk)begin
  if(rst)held=0;
  else begin
   if(held&&(!m_valid||bundle!==saved))$fatal(1,"held record changed");
   held=m_valid&&!m_ready;saved=bundle;if(held)held_cycles=held_cycles+1;
  end
 end
 always @(multiply_reset_view)if($time>0&&multiply_reset_view===0&&clk!==1)$fatal(1,"async reset origin");
 task reset_now;
  integer n;
  begin
   rst=1;c_valid=0;s_valid=0;m_ready=0;
   repeat(2)begin @(posedge clk);#1;if(c_ready||s_ready||m_valid)$fatal(1,"reset gate");end
   @(negedge clk);rst=0;resets=resets+1;n=0;
   while(!c_ready)begin @(negedge clk);n=n+1;if(n>8)$fatal(1,"reset recovery");end
   if(m_valid)$fatal(1,"reset leaked output");
  end
 endtask
 task command(input[31:0]n,f,input signed[D-1:0]b,input neg,input[D-1:0]floor,input[T-1:0]tag);
  integer wait_count;
  begin
   @(negedge clk);c_valid=1;c_samples=n;c_fraction=f;c_baseline=b;c_negative=neg;c_min_peak=floor;c_tag=tag;
   wait_count=0;@(posedge clk);
   while(!c_ready)begin @(negedge clk);wait_count=wait_count+1;if(wait_count>8)$fatal(1,"command deadline");@(posedge clk);end
   commands=commands+1;previous_sample=0;
   @(negedge clk);c_valid=0;c_samples=32'hffffffff;c_fraction=0;c_baseline=~b;c_negative=~neg;c_min_peak=0;c_tag=~tag;
  end
 endtask
 task sample(input signed[D-1:0]x,input marker,input integer ii);
  integer n;
  begin
   s_sample=x;s_marker=marker;s_valid=1;n=0;@(posedge clk);
   while(!s_ready)begin @(negedge clk);n=n+1;if(n>10)$fatal(1,"sample deadline");@(posedge clk);end
   if(ii)begin if(($time-previous_sample)/10!=ii)$fatal(1,"II mismatch");ii_checks=ii_checks+1;end
   previous_sample=$time;samples=samples+1;
   @(negedge clk);s_valid=0;s_sample=~x;s_marker=~marker;
  end
 endtask
 task expect_result(input[3:0]status,input[D-1:0]peak,input[I-1:0]position,input[1:0]sides,
  input[TW-1:0]left_time,right_time,width_time,input[T-1:0]tag,input integer hold_count);
  integer n;
  begin
   n=0;m_ready=0;c_valid=1;
   while(!m_valid)begin
    if(c_ready)$fatal(1,"owned command readiness");
    @(negedge clk);n=n+1;if(n>4*M+256)$fatal(1,"result deadline state%0d",state_view);
   end
   if(n>max_wait)max_wait=n;
   if(m_status!==status||m_peak!==peak||m_peak_index!==position||m_sides!==sides||m_left_q16!==left_time||
    m_right_q16!==right_time||m_width_q16!==width_time||m_tag!==tag||c_ready||s_ready)
    $fatal(1,"result got st%0d p%0d i%0d sides%0d l%0d r%0d w%0d tag%h expected st%0d p%0d i%0d sides%0d l%0d r%0d w%0d tag%h",
     m_status,m_peak,m_peak_index,m_sides,m_left_q16,m_right_q16,m_width_q16,m_tag,status,peak,position,sides,left_time,right_time,width_time,tag);
   repeat(hold_count)begin @(negedge clk);if(!m_valid||c_ready||s_ready)$fatal(1,"held ownership");end
   m_ready=1;@(posedge clk);if(c_ready)$fatal(1,"retirement fallthrough");
   @(negedge clk);m_ready=0;c_valid=0;records=records+1;
   if(m_valid)$fatal(1,"duplicate response");
   n=0;while(!c_ready)begin @(negedge clk);n=n+1;if(n>5)$fatal(1,"rearm deadline");end
  end
 endtask
 task fill_recovery;
  integer j,n,center,x;
  begin
   n=EX?256:(M<9?M:9);center=n/2;command(n,128,0,0,1,1);
   for(j=0;j<n;j=j+1)begin
    x=j==center?40:((j==center-1||j==center+1)?20:0);
    sample(D'(x),EX?(j==64):(j==n-1),j?1:0);
   end
  end
 endtask
 task recovery_result;
  integer center;
  begin center=EX?128:(M<9?M:9)/2;expect_result(0,40,I'(center),3,TW'((center-1)*65536),TW'((center+1)*65536),131072,1,2);end
 endtask
 task wait_state(input[3:0]target);
  integer n;
  begin n=0;while(state_view!=target)begin @(negedge clk);n=n+1;if(n>4*M+256)$fatal(1,"state deadline%0d",target);end end
 endtask
 integer fd,rc,j,target,n;
 reg[63:0]row[0:15];
 reg[2047:0]path;
 initial begin
  if(EX&&(D!=12||M!=256||T!=8))$fatal(1,"example profile");
  if(!$value$plusargs("vectors=%s",path))$fatal(1,"vectors missing");
  fd=$fopen(path,"r");if(!fd)$fatal(1,"vectors open");reset_now();
  while(!$feof(fd))begin
   rc=$fscanf(fd,"%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h\n",
    row[0],row[1],row[2],row[3],row[4],row[5],row[6],row[7],row[8],row[9],row[10],row[11],row[12],row[13],row[14],row[15]);
   if(rc!=16)$fatal(1,"vector parse");
   case(row[0])
    1:command(32'(row[1]),32'(row[2]),D'(row[3]),1'(row[4]),D'(row[5]),T'(row[6]));
    2:sample(D'(row[1]),1'(row[2]),32'(row[3]));
    3:expect_result(4'(row[1]),D'(row[2]),I'(row[3]),2'(row[4]),TW'(row[5]),TW'(row[6]),TW'(row[7]),T'(row[8]),32'(row[9]));
    4:repeat(row[1])@(negedge clk);
    default:$fatal(1,"vector opcode");
   endcase
  end
  $fclose(fd);
  for(target=1;target<=11;target=target+1)begin
   if(target==1&&!EX)begin command(M<9?M:9,128,0,0,1,1);sample(0,0,0);end
   else fill_recovery();
   wait_state(4'(target));reset_now();fill_recovery();recovery_result();
  end
  fill_recovery();wait_state(9);n=0;
  while(!divider_valid)begin @(negedge clk);n=n+1;if(n>80)$fatal(1,"fault wait");end
  g_dut.inject();faults=faults+1;expect_result(7,0,0,0,0,0,0,1,2);
  fill_recovery();recovery_result();
  $display("PASS pulse_fraction_timing D=%0d M=%0d T=%0d EX=%0d records=%0d commands=%0d samples=%0d resets=%0d faults=%0d held_cycles=%0d ii_checks=%0d max_wait=%0d",
   D,M,T,EX,records,commands,samples,resets,faults,held_cycles,ii_checks,max_wait);
  $finish;
 end
 initial begin #20000000;$fatal(1,"global cycle watchdog");end
endmodule
