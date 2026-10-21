"""True FFT translation and actual aligned-frame pixel verification."""
from pathlib import Path
import hashlib,importlib.util,json,shutil,sys,tempfile
import numpy as np
HERE=Path(__file__).resolve().parent;PACKAGE=HERE.parents[1];PHASE=PACKAGE/'image/phase_correlation'
sys.path.insert(0,str(PACKAGE/'integration'))
from tooling import execute
spec=importlib.util.spec_from_file_location('phase_fft_reference',PHASE/'oracle.py');reference=importlib.util.module_from_spec(spec);spec.loader.exec_module(reference)
SOURCES=[PHASE/'phase_correlation_frame.v',HERE/'phase_registration.sv']

def run(label,a,b,remove_dc=True,replays=1):
 n=len(a);expected=reference.oracle(a,b,remove_dc);floating=reference.numpy_oracle(a,b,remove_dc)
 assert not expected['invalid'];assert (expected['dx'],expected['dy'])==(floating['dx'],floating['dy'])
 aligned=np.roll(b,(expected['dy'],expected['dx']),(0,1))
 init='\n'.join(f"p[{i}]=16'h{x:02x}{y:02x};e[{i}]=11'h{((i==n*n-1)<<10)|((i%n==n-1)<<9)|((i==0)<<8)|int(z):03x};" for i,(x,y,z) in enumerate(zip(a.flat,b.flat,aligned.flat)))
 tb=r'''module tb;
 localparam SIDE=SS,N=SIDE*SIDE;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,start_valid=0,cfg_remove_dc=DD,abort=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
 reg[7:0]s_a=0,s_b=0;
 wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_error,busy;wire[7:0]m_data,error_code;
 wire signed[6:0]m_dx,m_dy;wire signed[31:0]m_peak;wire[15:0]m_valid_bins;
 phase_registration #(.SIDE(SIDE)) dut(.*);
 reg[15:0]p[0:N-1];reg[10:0]e[0:N-1];reg[10:0]held;reg stalled=0;integer cycles=0,i,r,got=0;
 wire[10:0]token={m_last,m_eol,m_sof,m_data};
 always @(negedge clk)begin cycles=cycles+1;ce=cycles%13!=0&&cycles%13!=1;m_ready=cycles%7<4;if(cycles>12000000)$fatal(1,"watchdog top=%d core=%d",dut.state,dut.phase.state);end
 always @(posedge clk)if(rst_n)begin
  if(stalled&&(!m_valid||token!==held))$fatal(1,"unstable output");
  stalled=m_valid&&!(ce&&m_ready);held=token;
  if(ce&&m_valid&&m_ready)begin if(got>=N||token!==e[got])$fatal(1,"pixel %d got=%h expected=%h",got,token,e[got]);got=got+1;end
 end
 task tick;begin @(negedge clk);#1;end endtask
 initial begin
 INIT
 repeat(3)tick;rst_n=1;
 for(r=0;r<RR;r=r+1)begin
  got=0;cfg_remove_dc=DD;while(!start_ready)tick;start_valid=1;tick;start_valid=0;cfg_remove_dc=!DD;
  for(i=0;i<N;i=i+1)begin
   {s_a,s_b}=p[i];s_sof=i==0;s_eol=i%SIDE==SIDE-1;s_last=i==N-1;
   while(!s_ready)tick;s_valid=1;tick;s_valid=0;
  end
  while(!done_valid)tick;
  if(done_error||error_code||got!=N||m_dx!=DX||m_dy!=DY||m_peak!=PEAK||m_valid_bins!=BINS)$fatal(1,"completion dx=%d dy=%d peak=%d bins=%d err=%h",m_dx,m_dy,m_peak,m_valid_bins,error_code);
  abort=1;repeat(7)begin tick;if(!done_valid||done_error||error_code||m_dx!=DX||m_dy!=DY||m_peak!=PEAK||m_valid_bins!=BINS)$fatal(1,"held DONE late abort");end abort=0;
  while(!ce)tick;done_ready=1;tick;done_ready=0;tick;
 end
 $display("REGISTRATION OK");$finish;end endmodule'''
 for k,v in [('SS',n),('DD',int(remove_dc)),('RR',replays),('DX',expected['dx']),('DY',expected['dy']),('PEAK',expected['peak']),('BINS',expected['valid_bins']),('INIT',init)]:tb=tb.replace(k,str(v))
 with tempfile.TemporaryDirectory(prefix='phase_registration_') as td:
  td=Path(td);shutil.copyfile(PHASE/'twiddle.mem',td/'twiddle.mem');(td/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',td/'sim',*SOURCES,td/'tb.sv'],td,td/'compile.log')
  assert 'REGISTRATION OK' in execute(['vvp',td/'sim'],td,td/'run.log',timeout=300)
 report=dict(label=label,side=n,remove_dc=remove_dc,replays=replays,phase_integer=expected,
             numpy_fft_shift=[floating['dx'],floating['dy']],pixels=n*n,status='PASS');print(report,flush=True);return report

def main():
 frozen={str(p.relative_to(PACKAGE)):hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES+[PHASE/'twiddle.mem']}
 rng=np.random.default_rng(8912);cases=[]
 for n,dy,dx,dc,r in [(8,2,-3,True,2),(8,-4,0,False,1),(8,4,4,True,1),(16,-5,7,True,1),(32,15,-16,True,1)]:
  a=rng.integers(0,256,(n,n),dtype=np.uint8);b=np.roll(a,(dy,dx),(0,1))
  cases.append(run('known_circular_shift',a,b,dc,r));assert np.array_equal(np.roll(b,(-dy,-dx),(0,1)),a)
 a=rng.integers(0,100,(8,8),dtype=np.uint8);b=np.roll(a,(1,3),(0,1))*2+3
 cases.append(run('gain_offset_actual_aligned_B',a,b));cases[-1]['pixel_policy']='aligned photometric B preserved, not replaced by A'
 assert frozen=={str(p.relative_to(PACKAGE)):hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES+[PHASE/'twiddle.mem']}
 (HERE/'evidence.json').write_text(json.dumps(dict(status='PASS',cases=cases,sources=frozen,board=False),indent=2)+'\n')

if __name__=='__main__':main()
