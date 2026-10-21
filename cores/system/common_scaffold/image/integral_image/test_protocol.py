from pathlib import Path
import hashlib,json,tempfile
from run_tests import H,ROOT,RTL,execute
tb=r'''module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=0,start_valid=0,abort=0,s_valid=0,s_sof=0,s_eol=0,s_last=0;
 reg[11:0]s_data=7;reg done_ready=0,query_valid=0,result_ready=0;
 reg[15:0]query_x0=0,query_y0=0,query_x1=6,query_y1=4;
 wire start_ready,s_ready,done_valid,done_error,frame_valid,query_ready,result_valid,result_error;
 wire[3:0]error_code,result_error_code;wire[31:0]accepted_pixels,result_sum,result_count;wire[39:0]result_sqsum;
 integral_image #(.WIDTH(6),.HEIGHT(4),.BITS(12))dut(.*);
 integer j,k,phase,cycles=0,healthy_count=0;integer targets[0:7];reg blocked=0;
 reg got_start,got_input,got_done,got_query,got_result;reg[31:0]rng=32'h123bca87;
 always @(posedge clk)if(rst_n)begin cycles=cycles+1;if(cycles>300000)$fatal(1,"timeout phase %d state %d",phase,dut.state);end
 task tick;begin
  @(negedge clk);rng=(rng>>1)^(rng[0]?32'hd0000001:0);ce=rng[1:0]!=0;result_ready=!blocked&&rng[3:2]!=0;
  @(posedge clk);got_start=ce&&start_valid&&start_ready;got_input=ce&&s_valid&&s_ready;
  got_done=ce&&done_valid&&done_ready;got_query=ce&&query_valid&&query_ready;got_result=ce&&result_valid&&result_ready;#1;
 end endtask
 task start;begin start_valid=1;do tick();while(!got_start);start_valid=0;end endtask
 task send;input integer n;begin
  for(k=0;k<n;k=k+1)begin s_data=7;s_valid=1;s_sof=k==0;s_eol=k%6==5;s_last=k==23;
   do tick();while(!got_input);s_valid=0;end
 end endtask
 task ack;begin done_ready=1;do tick();while(!got_done);done_ready=0;end endtask
 task query;begin
  query_x0=0;query_y0=0;query_x1=6;query_y1=4;query_valid=1;do tick();while(!got_query);query_valid=0;
 end endtask
 task good_frame;begin
  start();send(24);while(!done_valid)tick();
  if(done_error||error_code||accepted_pixels!=24||!frame_valid)$fatal(1,"healthy frame");ack();
  blocked=1;query();while(!result_valid)tick();
  if(result_error||result_sum!=168||result_sqsum!=1176||result_count!=24)$fatal(1,"healthy query");
  repeat(6)begin tick();if(!result_valid||result_sum!=168||result_sqsum!=1176||result_count!=24)$fatal(1,"query hold");end
  blocked=0;do tick();while(!got_result);healthy_count=healthy_count+1;
 end endtask
 task reset_off;begin
  s_valid=0;query_valid=0;start_valid=0;done_ready=0;abort=0;
  @(negedge clk);ce=0;rst_n=0;@(posedge clk);#1;
  if(frame_valid||done_valid||result_valid||accepted_pixels||done_error||error_code)$fatal(1,"reset CE0");
  @(negedge clk);rst_n=1;blocked=0;repeat(3)tick();if(query_ready||frame_valid||result_valid)$fatal(1,"stale reset frame");
 end endtask
 task reach;input integer target;begin
  start();
  if(target==3)send(5);
  else if(target==4)send(1);
  else if(target>=5)begin send(24);while(!done_valid)tick();if(target!=5)begin ack();if(target>=7)begin blocked=1;query();end end end
  while(dut.state!=target)tick();
 end endtask
 initial begin
  targets[0]=1;targets[1]=2;targets[2]=3;targets[3]=4;targets[4]=6;targets[5]=7;targets[6]=8;targets[7]=9;
  reset_off();good_frame();
  for(j=0;j<8;j=j+1)begin
   phase=targets[j];reach(phase);
   // Hold abort while CE is off: no terminal change until the enabled edge.
   @(negedge clk);ce=0;abort=1;@(posedge clk);#1;if(done_valid)$fatal(1,"abort ignored CE");
   do tick();while(!ce);abort=0;
   if(!done_valid||!done_error||error_code!=3||frame_valid||result_valid)$fatal(1,"abort phase %d",phase);
   ack();blocked=0;good_frame();
  end
  for(j=0;j<8;j=j+1)begin phase=targets[j];reach(phase);reset_off();good_frame();end
  // Reset terminal DONE too.
  reach(5);reset_off();good_frame();
  // SOF/EOL/LAST errors each after five accepted good inputs; faulty sixth is
  // counted as a handshake, never inserted into the table. Next frame is clean.
  for(j=0;j<3;j=j+1)begin
   start();send(5);s_valid=1;s_data=9;s_sof=j==0;s_eol=j!=1;s_last=j==2;
   do tick();while(!got_input);s_valid=0;while(!done_valid)tick();
   if(!done_error||error_code!=2||accepted_pixels!=6||frame_valid)$fatal(1,"marker error");
   ack();good_frame();
  end
  // Simultaneous START/query requests prioritize a new frame and suppress old query.
  start_valid=1;query_valid=1;do begin tick();if(got_query)$fatal(1,"query won start arbitration");end while(!got_start);
  start_valid=0;query_valid=0;if(frame_valid||accepted_pixels)$fatal(1,"stale next frame");
  send(24);while(!done_valid)tick();ack();
  $display("PASS integral protocol %d healthy frames, 8 aborts, 10 resets, 3 marker errors",healthy_count);$finish;
 end
endmodule'''
with tempfile.TemporaryDirectory(prefix='integral_protocol_')as td:
 d=Path(td);(d/'tb.sv').write_text(tb)
 execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],ROOT,d/'compile.log')
 text=execute(['vvp',d/'a.vvp'],ROOT,d/'run.log');print(text.strip())
(H/'protocol_result.json').write_text(json.dumps(dict(result='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),healthy_frames=21,full_frame_queries=21,aborts=8,ce_disabled_resets=10,marker_errors=3,start_over_query_priority=True),indent=2)+'\n')
