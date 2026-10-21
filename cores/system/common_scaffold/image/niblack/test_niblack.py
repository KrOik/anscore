"""Independent integer/rational oracle and actual skimage Niblack reference."""
from pathlib import Path
from fractions import Fraction
from math import isqrt,sqrt
import sys,json,hashlib,tempfile
import numpy as np
from skimage.filters import threshold_niblack
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]/'integration'))
from tooling import execute
RTL=HERE/'niblack.sv'
def hashes():return {RTL.name:hashlib.sha256(RTL.read_bytes()).hexdigest()}
def oracle(a,window,k,bias,root_values=None):
 h,w=a.shape;r=window//2;out=np.empty_like(a);threshold=np.empty((h,w),float)
 for y in range(h):
  for x in range(w):
   v=[int(a[min(h-1,max(0,yy)),min(w-1,max(0,xx))]) for yy in range(y-r,y+r+1) for xx in range(x-r,x+r+1)]
   n=len(v);mean=Fraction(sum(v),n)
   exactvar=sum((Fraction(t)-mean)**2 for t in v)/n
   # Independent mean/central-variance calculation, then exact fixed-point square root.
   rad=exactvar*n*n*65536;assert rad.denominator==1
   root=isqrt(rad.numerator)
   if root_values is not None:root_values.append(root)
   std=Fraction(root,256*n)
   t=mean-Fraction(k,256)*std+Fraction(bias,256)
   out[y,x]=255 if Fraction(int(a[y,x]))>t else 0;threshold[y,x]=float(t)
 return out,threshold

def skimage_reference(a,window,k,bias):
 r=window//2;b=np.pad(a,r,mode='edge')
 t=threshold_niblack(b,window_size=window,k=k/256)[r:-r,r:-r]+bias/256
 return np.where(a>t,255,0).astype(np.uint8),t

BASE=r'''module tb;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,ce=1,start_valid=0,cfg_window5=KK,abort=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;
 reg[5:0]cfg_width=WW,cfg_height=HH;reg signed[11:0]cfg_k_q8=KVAL;reg signed[15:0]cfg_bias_q8=BVAL;reg[7:0]s_data=0;
 wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_error,busy;wire[7:0]m_data,error_code;
 niblack dut(.*);
 localparam W=WW,H=HH,N=W*H;
 reg[7:0]pixels[0:N-1];reg[23:0]roots[0:N-1];reg[10:0]expected[0:N-1];reg[10:0]held;reg stalled=0;
 integer cyc=0,got=0,i,rep;
 wire[10:0]token={m_last,m_eol,m_sof,m_data};
 always @(negedge clk)begin cyc=cyc+1;ce=cyc%11>1;m_ready=cyc%7<4;if(cyc>3000000)$fatal(1,"timeout %d",dut.state);end
 always @(posedge clk)if(rst_n)begin
  if(ce&&dut.state==10&&dut.sqrt_root!==roots[dut.oy*W+dut.ox])$fatal(1,"sqrt mismatch at x=%d y=%d",dut.ox,dut.oy);
  if(stalled&&(!m_valid||held!==token))$fatal(1,"unstable output");
  stalled=m_valid&&!(ce&&m_ready);held=token;
  if(ce&&m_valid&&m_ready)begin if(got>=N||token!==expected[got])$fatal(1,"pixel %d got %h expected %h",got,token,expected[got]);got=got+1;end
 end
 task tick;begin @(negedge clk);#1;end endtask
 initial begin
 INITDATA
 repeat(3)tick;rst_n=1;
 for(rep=0;rep<RR;rep=rep+1)begin
  got=0;cfg_width=W;cfg_height=H;cfg_k_q8=KVAL;cfg_bias_q8=BVAL;cfg_window5=KK;
  while(!start_ready)tick;start_valid=1;tick;start_valid=0;
  cfg_width=0;cfg_height=0;cfg_k_q8=0;cfg_bias_q8=32767;cfg_window5=!KK;
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
 $display("NIBLACK OK pixels=%d",got);$finish;
 end
endmodule'''

def simulate(tb,label):
 with tempfile.TemporaryDirectory(prefix='niblack_'+label+'_') as d:
  d=Path(d);(d/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',str(d/'sim.vvp'),str(RTL),str(d/'tb.sv')],d,d/'compile.log')
  text=execute(['vvp',str(d/'sim.vvp')],d,d/'run.log',timeout=180)
  assert 'NIBLACK OK' in text,text

def run(label,a,window,k,bias,replays=1,allow_boundary_difference=False):
 roots=[];expected,t=oracle(a,window,k,bias,roots);sp,st=skimage_reference(a,window,k,bias)
 bound=abs(k)/(65536*window*window)
 assert float(np.max(np.abs(t-st)))<bound+1e-8
 diff=expected!=sp
 if allow_boundary_difference:
  assert np.any(diff), "directed quantization fixture must exhibit classification boundary"
  assert np.all(np.abs(a.astype(float)-st)[diff]<=bound+1e-8)
 else:assert not np.any(diff), (label, np.argwhere(diff).tolist())
 h,w=a.shape
 init='\n'.join(f"roots[{i}]=24'd{roots[i]};pixels[{i}]=8'd{int(v)};expected[{i}]=11'h{((i==w*h-1)<<10)|((i%w==w-1)<<9)|((i==0)<<8)|int(o):03x};" for i,(v,o) in enumerate(zip(a.flat,expected.flat)))
 tb=BASE
 for key,val in [('INITDATA',init),('WW',w),('HH',h),('KVAL',k),('BVAL',bias),('KK',int(window==5)),('RR',replays)]:tb=tb.replace(key,str(val))
 simulate(tb,label)
 mean_only,_=oracle(a,window,0,bias)
 result=dict(label=label,width=w,height=h,window=window,k_q8=k,bias_q8=bias,frames=replays,status='PASS',skimage_binary_differences=int(np.count_nonzero(diff)),skimage_difference_yx=np.argwhere(diff).tolist(),quantization_boundary_allowed=allow_boundary_difference,threshold_max_difference=float(np.max(np.abs(t-st))),threshold_error_bound=bound,changed_vs_mean_only=int(np.count_nonzero(expected!=mean_only)),foreground_pixels=int(np.count_nonzero(expected)),output_sha256=hashlib.sha256(expected.tobytes()).hexdigest())
 print(result,flush=True);return result

if __name__=='__main__':
 rng=np.random.default_rng(20261020)
 white=np.array([[254,255]*4,[255,254]*4]*4,dtype=np.uint8)
 cases=[('random3',rng.integers(0,256,(8,9),dtype=np.uint8),3,128,0,2),('random5_negative',rng.integers(0,256,(9,8),dtype=np.uint8),5,-128,64,1),('maximum32',rng.integers(0,256,(32,32),dtype=np.uint8),5,51,-128,1),('nearwhite_positive',white,3,51,0,1),('nearwhite_negative',white,5,-51,0,1),('lowcontrast',rng.integers(250,256,(7,7),dtype=np.uint8),5,128,1,1),('constant_equal',np.full((6,7),255,np.uint8),5,1024,0,1),('constant_negativebias',np.full((6,7),255,np.uint8),3,-1024,-1,1),('black',np.zeros((3,3),np.uint8),3,0,0,1),('impulse',np.pad(np.array([[255]],dtype=np.uint8),3),3,256,0,1),('k_positive4',rng.integers(0,256,(5,6),dtype=np.uint8),5,1024,0,1),('k_negative4',rng.integers(0,256,(5,6),dtype=np.uint8),3,-1024,0,1),('singleton',np.array([[254]],dtype=np.uint8),5,51,0,1),('row',np.array([[0,254,255,1,127,128]],dtype=np.uint8),5,51,32767,1),('column',np.array([[1],[255],[254],[0]],dtype=np.uint8),3,-51,-32768,1),('k0_mean',rng.integers(0,256,(6,7),dtype=np.uint8),3,0,0,1)]
 cases.extend([('constant_k0_equal',np.full((4,4),254,np.uint8),3,0,0,1),('quantization_boundary',np.array([[254,250,253],[249,255,248],[250,253,248]],dtype=np.uint8),3,1024,3570,1,True)])
 results=[run(*c) for c in cases]
 assert sum(c['changed_vs_mean_only'] for c in results)>0
 (HERE/'evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes(),cases=results,reference='actual skimage.filters.threshold_niblack; edge-pad/crop; deliberate quantization-boundary classification difference recorded and mathematically bounded',checks='every emitted binary pixel and every local sqrt(V) Q8 compared with independent Fraction+isqrt oracle',board=False),indent=2)+'\n')
