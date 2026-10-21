from pathlib import Path
import hashlib,json,tempfile
from run_tests import H,ROOT,execute
tb=r'''module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=0,start_valid=0,cfg_auto=1;reg[1:0]cfg_pattern=0;
 reg[15:0]cfg_roi_x0=0,cfg_roi_y0=0,cfg_roi_x1=7,cfg_roi_y1=5,cfg_gain_min=0,cfg_gain_max=65535;
 reg[11:0]cfg_low=0,cfg_high=4095,s_data=500;reg[63:0]cfg_manual_gains=64'h1000100010001000;
 reg s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
 wire start_ready,s_ready,m_valid,m_saturated,m_sof,m_eol,m_last,done_valid,done_error;
 wire[11:0]m_data;wire[3:0]error_code;wire[127:0]stats_sums,stats_counts;wire[63:0]applied_gains,green_sum;wire[31:0]green_count;
 raw_white_balance #(.WIDTH(8),.HEIGHT(6),.BITS(12))dut(.*);
 integer seen=0,k,j,cycles=0,delay_cycles;reg armed=0,blocked=0,got_start,got_input,got_done;
 reg[31:0]rng=32'h6413882;integer targets[0:7];
 always @(posedge clk)if(rst_n)begin
  cycles=cycles+1;if(cycles>300000)$fatal(1,"timeout state %d",dut.state);
  if(armed&&ce&&m_valid&&m_ready)begin
   if(m_data!==12'd500||m_saturated||m_sof!==(seen==0)||m_eol!==(seen%8==7)||m_last!==(seen==47))$fatal(1,"recovery pixel");
   seen=seen+1;
  end
 end
 task tick;begin
  @(negedge clk);rng=(rng>>1)^((rng[0])?32'hd0000001:0);ce=rng[1:0]!=0;m_ready=!blocked&&(rng[3:2]!=0);
  @(posedge clk);got_start=ce&&start_valid&&start_ready;got_input=ce&&s_valid&&s_ready;got_done=ce&&done_valid&&done_ready;#1;
 end endtask
 task begin_frame;input a;begin
  cfg_auto=a;start_valid=1;do tick();while(!got_start);start_valid=0;
 end endtask
 task send;input integer n;begin
  for(k=0;k<n;k=k+1)begin
   s_valid=1;s_data=500;s_sof=k==0;s_eol=k%8==7;s_last=k==47;
   do tick();while(!got_input);s_valid=0;
  end
 end endtask
 task reset_ce_off;begin
  armed=0;s_valid=0;start_valid=0;done_ready=0;
  @(negedge clk);ce=0;rst_n=0;@(posedge clk);#1;
  if(m_valid||done_valid||done_error||error_code||stats_sums||stats_counts||applied_gains)$fatal(1,"reset with CE off");
  @(negedge clk);rst_n=1;blocked=0;
  repeat(4)tick();if(m_valid||done_valid)$fatal(1,"stale post-reset token");
 end endtask
 task healthy;begin
  seen=0;armed=1;begin_frame(0);send(48);
  while(!done_valid)tick();
  if(done_error||error_code||seen!=48||stats_sums!==128'h00001770000017700000177000001770||stats_counts!==128'h0000000c0000000c0000000c0000000c||green_sum!=12000||green_count!=24||applied_gains!==64'h1000100010001000)$fatal(1,"recovery frame");
  done_ready=1;do tick();while(!got_done);done_ready=0;armed=0;
 end endtask
 initial begin
  targets[0]=1;targets[1]=3;targets[2]=6;targets[3]=8;targets[4]=9;targets[5]=10;targets[6]=11;targets[7]=12;
  reset_ce_off();healthy();
  for(j=0;j<8;j=j+1)begin
   cfg_pattern=j%4;
   begin_frame(1);
   if(targets[j]==1)send(7);else send(48);
   if(targets[j]==11)blocked=1;
   while(dut.state!=targets[j])tick();
   // Reset must clear capture, both arithmetic engines, RAM read/output, stalled output and DONE.
   reset_ce_off();healthy();
  end
  // Marker fault after partial capture (not only at pixel zero), then a clean frame.
  begin_frame(1);send(7);s_valid=1;s_data=600;s_sof=0;s_eol=0;s_last=0;
  do tick();while(!got_input);s_valid=0;while(!done_valid)tick();
  if(!done_error||error_code!=2||m_valid)$fatal(1,"late marker error");
  done_ready=1;do tick();while(!got_done);done_ready=0;healthy();
  $display("PASS protocol 9 CE-off resets, 10 healthy recovery frames, late marker fault");$finish;
 end
endmodule'''
with tempfile.TemporaryDirectory(prefix='raw_awb_protocol_')as td:
 d=Path(td);(d/'tb.sv').write_text(tb)
 execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',H/'raw_white_balance.sv',d/'tb.sv'],ROOT,d/'compile.log')
 text=execute(['vvp',d/'a.vvp'],ROOT,d/'run.log');print(text.strip())
e=dict(result='PASS',rtl_sha256=hashlib.sha256((H/'raw_white_balance.sv').read_bytes()).hexdigest(),ce_disabled_resets=9,reset_states=['initial','capture','multiply','divide','ram_read','ram_wait','output_prepare','stalled_output','done'],healthy_recovery_frames=10,healthy_pixels=480,late_marker_faults=1)
(H/'protocol_result.json').write_text(json.dumps(e,indent=2)+'\n')
