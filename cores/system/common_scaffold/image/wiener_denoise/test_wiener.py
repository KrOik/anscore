"""Independent exact rational and actual SciPy output comparisons."""
from pathlib import Path
from fractions import Fraction
import sys,json,hashlib,tempfile,warnings
import numpy as np
from scipy.signal import wiener
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
RTL=HERE/'wiener_denoise.sv'
def hashes():return {RTL.name:hashlib.sha256(RTL.read_bytes()).hexdigest()}
def oracle(a,k,noise):
 h,w=a.shape;r=k//2;out=np.empty_like(a)
 for y in range(h):
  for x in range(w):
   v=[int(a[min(h-1,max(0,yy)),min(w-1,max(0,xx))]) for yy in range(y-r,y+r+1) for xx in range(x-r,x+r+1)]
   n=len(v);mean=Fraction(sum(v),n);var=sum((Fraction(t)-mean)**2 for t in v)/n
   gain=Fraction(0) if var<=noise else (var-noise)/var
   value=mean+gain*(int(a[y,x])-mean)
   out[y,x]=(2*value.numerator+value.denominator)//(2*value.denominator)
 return out

def scipy_reference(a,k,noise):
 r=k//2;b=np.pad(a.astype(float),r,mode='edge')
 # SciPy evaluates division even where its np.where selects mean. Silence these known benign warnings.
 with warnings.catch_warnings():
  warnings.simplefilter('ignore',RuntimeWarning)
  c=wiener(b,(k,k),noise=noise)[r:-r,r:-r]
 # SciPy 0/0 at constant patches with zero noise is explicitly defined by our contract as identity.
 c=np.where(np.isfinite(c),c,a.astype(float))
 return np.floor(c+0.5).astype(np.uint8)

BASE=r'''module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,start_valid=0,cfg_window5=KK,abort=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
 reg[5:0]cfg_width=WW,cfg_height=HH;reg[15:0]cfg_noise_variance=NN;reg[7:0]s_data=0;
 wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_error,busy;wire[7:0]m_data,error_code;
 wiener_denoise dut(.*);
 localparam W=WW,H=HH,N=W*H;
 reg[7:0]pixels[0:N-1];reg[10:0]expected[0:N-1];reg[10:0]held;reg stalled=0;
 integer cyc=0,got=0,i,rep;
 wire[10:0]token={m_last,m_eol,m_sof,m_data};
 always @(negedge clk)begin cyc=cyc+1;ce=cyc%11>1;m_ready=cyc%7<4;if(cyc>3000000)$fatal(1,"timeout %d",dut.state);end
 always @(posedge clk)if(rst_n)begin
  if(stalled&&(!m_valid||held!==token))$fatal(1,"unstable output");
  stalled=m_valid&&!(ce&&m_ready);held=token;
  if(ce&&m_valid&&m_ready)begin if(got>=N||token!==expected[got])$fatal(1,"pixel %d got %h expected %h",got,token,expected[got]);got=got+1;end
 end
 task tick;begin @(negedge clk);#1;end endtask
 initial begin
 INITDATA
 repeat(3)tick;rst_n=1;
 for(rep=0;rep<RR;rep=rep+1)begin
  got=0;cfg_width=W;cfg_height=H;cfg_noise_variance=NN;cfg_window5=KK;
  while(!start_ready)tick;start_valid=1;tick;start_valid=0;
  cfg_width=0;cfg_height=0;cfg_noise_variance=65535;cfg_window5=!KK;
  for(i=0;i<N;i=i+1)begin
   if(i%5==0)repeat(2)tick;
   s_data=pixels[i];s_sof=i==0;s_eol=i%W==W-1;s_last=i==N-1;
   while(!s_ready)tick;s_valid=1;tick;s_valid=0;
  end
  while(!done_valid)tick;
  if(done_error||error_code||got!=N)$fatal(1,"bad done err=%h got=%d",error_code,got);
  abort=1;repeat(9)begin tick;if(!done_valid||done_error||error_code)$fatal(1,"held done late abort");end abort=0;
  while(!ce)tick;done_ready=1;tick;done_ready=0;tick;
 end
 $display("WIENER OK pixels=%d",got);$finish;
 end
endmodule'''

def simulate(tb,label):
 with tempfile.TemporaryDirectory(prefix='wiener_'+label+'_') as d:
  d=Path(d);(d/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',str(d/'sim.vvp'),str(RTL),str(d/'tb.sv')],d,d/'compile.log')
  out=execute(['vvp',str(d/'sim.vvp')],d,d/'run.log',timeout=180)
  assert 'WIENER OK' in out,out

def run(label,a,k,noise,replays=1):
 expected=oracle(a,k,noise);sp=scipy_reference(a,k,noise)
 # Compare actual SciPy rounded pixels exactly on the selected fixtures.
 mismatch=np.abs(expected.astype(int)-sp.astype(int))
 assert np.array_equal(expected,sp), (label, int(mismatch.max()))
 h,w=a.shape
 init='\n'.join(f'pixels[{i}]=8\'d{int(v)};expected[{i}]=11\'h{((i==w*h-1)<<10)|((i%w==w-1)<<9)|((i==0)<<8)|int(o):03x};' for i,(v,o) in enumerate(zip(a.flat,expected.flat)))
 tb=BASE
 for key,val in [('INITDATA',init),('WW',w),('HH',h),('NN',noise),('KK',int(k==5)),('RR',replays)]:tb=tb.replace(key,str(val))
 simulate(tb,label)
 result=dict(label=label,width=w,height=h,window=k,noise_variance=noise,frames=replays,status='PASS',scipy_max_rounded_difference=int(mismatch.max()),scipy_different_rounded_pixels=int(np.count_nonzero(mismatch)),changed_pixels=int(np.count_nonzero(expected!=a)),output_sha256=hashlib.sha256(expected.tobytes()).hexdigest())
 print(result,flush=True);return result

if __name__=='__main__':
 rng=np.random.default_rng(20261019)
 cases=[('random3',rng.integers(0,256,(8,9),dtype=np.uint8),3,600,2),('random5',rng.integers(0,256,(9,8),dtype=np.uint8),5,2200,1),('maximum32',rng.integers(0,256,(32,32),dtype=np.uint8),5,900,1),('nearwhite_noise1',np.array([[254,255]*4,[255,254]*4]*4,dtype=np.uint8),3,1,1),('nearwhite_zero',np.array([[254,255]*3,[255,254]*3]*3,dtype=np.uint8),5,0,1),('low_noise',rng.integers(245,256,(7,7),dtype=np.uint8),5,1,1),('constant',np.full((6,7),255,np.uint8),5,1,1),('black_zero',np.zeros((3,3),np.uint8),3,0,1),('impulse',np.pad(np.array([[255]],dtype=np.uint8),3),3,400,1),('maxnoise',rng.integers(0,256,(5,6),dtype=np.uint8),5,65535,1),('singleton',np.array([[254]],dtype=np.uint8),5,1,1),('row',np.array([[0,254,255,1,127,128]],dtype=np.uint8),5,1,1),('column',np.array([[1],[255],[254],[0]],dtype=np.uint8),3,100,1)]
 cases.append(('half_up_tie',np.array([[4,6,1],[6,3,4],[7,7,7]],dtype=np.uint8),3,1,1))
 results=[run(*c) for c in cases]
 (HERE/'evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes(),cases=results,scipy='actual scipy.signal.wiener replicate-padded then cropped; exact-half floating ties may differ by one',board=False),indent=2)+'\n')
