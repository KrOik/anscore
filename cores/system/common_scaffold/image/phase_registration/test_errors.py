import hashlib,json,shutil,tempfile
from pathlib import Path
import numpy as np
from test_registration import HERE,PACKAGE,PHASE,SOURCES,reference,execute
rng=np.random.default_rng(441);a=rng.integers(0,256,(8,8),dtype=np.uint8);b=np.roll(a,(2,-3),(0,1));expected=reference.oracle(a,b)
init='\n'.join(f"p[{i}]=16'h{x:02x}{y:02x};e[{i}]=11'h{((i==63)<<10)|((i%8==7)<<9)|((i==0)<<8)|int(z):03x};" for i,(x,y,z) in enumerate(zip(a.flat,b.flat,a.flat)))
invalid=[]
for name,v in [('zeros',np.zeros((8,8),np.uint8)),('constant',np.full((8,8),81,np.uint8)),('periodic',np.tile(np.array([0,255]*4,np.uint8),(8,1)))]:
 d=reference.oracle(v,v);assert d['invalid'];invalid.append(dict(name=name,oracle=d))
tb=r'''module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,start_valid=0,cfg_remove_dc=1,abort=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
 reg[7:0]s_a=0,s_b=0;
 wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_error,busy;wire[7:0]m_data,error_code;
 wire signed[6:0]m_dx,m_dy;wire signed[31:0]m_peak;wire[15:0]m_valid_bins;
 phase_registration #(.SIDE(8)) dut(.*);
 reg[15:0]p[0:63];reg[10:0]e[0:63];integer i,phase,cycles=0,count=0,healthy_count=0,any_output=0;reg check_pixels=0;
 wire[10:0]token={m_last,m_eol,m_sof,m_data};
 always @(posedge clk)begin
  cycles=cycles+1;if(cycles>8000000)$fatal(1,"watchdog top=%d core=%d phase=%d healthy=%d",dut.state,dut.phase.state,phase,healthy_count);
  if(rst_n&&ce&&m_valid&&m_ready)begin
   any_output=any_output+1;
   if(check_pixels)begin if(count>=64||token!==e[count])$fatal(1,"healthy pixel %d",count);count=count+1;end
  end
 end
 task tick;begin @(negedge clk);#1;end endtask
 task reset;
 begin tick;rst_n=0;ce=0;start_valid=0;abort=0;s_valid=0;m_ready=0;done_ready=0;check_pixels=0;
 tick;if(m_valid||done_valid||start_ready||s_ready||busy)$fatal(1,"CE-low reset");rst_n=1;ce=1;tick;end endtask
 task start;
 begin cfg_remove_dc=1;while(!start_ready)tick;start_valid=1;tick;start_valid=0;end endtask
 task feed;
 input integer mode;
 begin for(i=0;i<64;i=i+1)begin
  {s_a,s_b}=p[i];if(mode==1)begin s_a=0;s_b=0;end
  if(mode==2)begin s_a=81;s_b=81;end
  if(mode==3)begin s_a=i%2?255:0;s_b=s_a;end
  s_sof=i==0;s_eol=i%8==7;s_last=i==63;while(!s_ready)tick;s_valid=1;tick;s_valid=0;
 end end endtask
 task ack;
 begin done_ready=1;tick;done_ready=0;tick;end endtask
 task error_result;
 input[7:0]code;
 begin while(!done_valid)tick;if(!done_error||error_code!==code||m_valid)$fatal(1,"error result %h expected=%h",error_code,code);
 abort=1;repeat(3)begin tick;if(!done_valid||!done_error||error_code!==code||m_valid)$fatal(1,"held error");end
 ce=0;done_ready=1;repeat(3)tick;if(!done_valid||error_code!==code)$fatal(1,"CE-gated error ACK");
 abort=0;done_ready=0;ce=1;ack;end endtask
 task healthy;
 begin count=0;check_pixels=1;m_ready=1;start;feed(0);while(!done_valid)tick;
 if(done_error||error_code||count!=64||m_dx!=DX||m_dy!=DY||m_peak!=PEAK||m_valid_bins!=BINS)$fatal(1,"healthy completion");
 abort=1;repeat(3)begin tick;if(!done_valid||done_error||error_code||m_dx!=DX||m_dy!=DY||m_peak!=PEAK||m_valid_bins!=BINS)$fatal(1,"late abort");end
 ce=0;done_ready=1;repeat(3)tick;if(!done_valid)$fatal(1,"CE-gated ACK");
 done_ready=0;abort=0;ce=1;ack;check_pixels=0;m_ready=0;healthy_count=healthy_count+1;end endtask
 initial begin
 INIT
 reset;
 for(phase=0;phase<3;phase=phase+1)begin
  start;{s_a,s_b}=p[0];s_sof=phase!=0;s_eol=phase==1;s_last=phase==2;s_valid=1;tick;s_valid=0;error_result(8'h81);healthy;
 end
 for(phase=1;phase<=3;phase=phase+1)begin
  start;any_output=0;m_ready=1;feed(phase);error_result(8'h90);if(any_output)$fatal(1,"invalid spectrum emitted pixels");m_ready=0;healthy;
 end
 for(phase=0;phase<3;phase=phase+1)begin
  start;if(phase!=0)feed(0);
  case(phase)0:while(dut.state!=1)tick;1:while(dut.phase.state!=40)tick;2:while(!m_valid)tick;endcase
  if(phase==2)ce=0;
  abort=1;m_ready=1;#1;if(m_valid)$fatal(1,"abort output transfer");
  if(phase==2)begin
   repeat(3)tick;
   if(dut.state!=6||done_valid||m_valid||!dut.pending_valid)$fatal(1,"CE0 abort state changed");
   ce=1;
  end
  @(posedge clk);if(m_valid&&m_ready)$fatal(1,"abort leaked accepted pixel");
  tick;m_ready=0;error_result(8'h93);healthy;
 end
 for(phase=0;phase<8;phase=phase+1)begin
  start;if(phase!=0)feed(0);
  case(phase)
   0:while(dut.state!=1)tick;
   1:while(dut.phase.state!=40)tick;
   2:while(dut.phase.state!=29)tick;
   3:while(dut.phase.state!=41)tick;
   4:while(!dut.phase.inverse)tick;
   5:while(dut.state!=4)tick;
   6:while(!m_valid)tick;
   7:begin m_ready=1;while(!done_valid)tick;end
  endcase
  reset;healthy;
 end
 $display("ERROR OK healthy=%d",healthy_count);$finish;end endmodule'''
for k,v in [('DX',expected['dx']),('DY',expected['dy']),('PEAK',expected['peak']),('BINS',expected['valid_bins']),('INIT',init)]:tb=tb.replace(k,str(v))
hashes={str(p.relative_to(PACKAGE)):hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES+[PHASE/'twiddle.mem']}
with tempfile.TemporaryDirectory(prefix='phase_registration_errors_') as td:
 td=Path(td);shutil.copyfile(PHASE/'twiddle.mem',td/'twiddle.mem');(td/'tb.sv').write_text(tb)
 execute(['iverilog','-g2012','-s','tb','-o',td/'sim',*SOURCES,td/'tb.sv'],td,td/'compile.log')
 result=execute(['vvp',td/'sim'],td,td/'run.log',timeout=300);assert 'ERROR OK healthy=         17' in result,result
assert hashes=={str(p.relative_to(PACKAGE)):hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES+[PHASE/'twiddle.mem']}
report=dict(status='PASS',healthy_recovery_frames=17,marker=['missing SOF','early EOL','early LAST'],
 invalid_spectrum=invalid,invalid_pixel_output='none',abort=['capture','actual FFT serial multiply','valid and ready aligned output'],
 reset_ce0=['capture','FFT multiply','Euclidean sqrt','normalization divider','inverse FFT','aligned RAM read','held output','held DONE'],
 held=['error completion','successful DONE late abort','CE-gated ACK','CE0 abort suppresses validity and completes only on CE1'],sources=hashes,board=False)
(HERE/'error_evidence.json').write_text(json.dumps(report,indent=2)+'\n');print(report)
