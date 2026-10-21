import os,sys,json,tempfile,subprocess,time,hashlib
from pathlib import Path
import numpy as np
import cv2
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parent;OSS=ROOT.parents[3]/'tools/oss-cad-suite/oss-cad-suite'
os.environ['PATH']=os.pathsep.join([str(OSS/'bin'),str(OSS/'lib'),os.environ.get('PATH','')])
from oracle import oracle,numpy_oracle
def simulate(body,n=8):
 with tempfile.TemporaryDirectory(prefix='phase_corr_') as temporary:
  td=Path(temporary);(td/'tb.v').write_text(TB.replace('@SIDE@',str(n)).replace('@BODY@',body))
  p=subprocess.run(['iverilog','-g2012','-s','tb','-o',str(td/'sim'),str(ROOT/'phase_correlation_frame.v'),str(td/'tb.v')],cwd=ROOT,capture_output=True,text=True)
  if p.returncode:raise RuntimeError(p.stderr)
  p=subprocess.run(['vvp',str(td/'sim')],cwd=ROOT,capture_output=True,text=True,timeout=240)
  if p.returncode:raise RuntimeError(p.stdout+p.stderr)
  assert 'PHASE PASS' in p.stdout,p.stdout
 return p.stdout
def frame_body(a,b,dc=True,bad=0):
 n=len(a);e=oracle(a,b,dc)
 code=bad|(16 if e['invalid'] else 0)
 body=[f'beginframe({int(dc)});']
 for y in range(n):
  for x in range(n):
   sf=int(x==0 and y==0);el=int(x==n-1)
   if bad==1 and x==y==0:sf=0
   if bad==2 and x==1 and y==0:sf=1
   if bad==4 and x==n-1 and y==0:el=0
   if bad==8 and x==1 and y==0:el=1
   body.append(f'send({int(a[y,x])},{int(b[y,x])},{sf},{el});')
 body.append(f"check({e['dx']},{e['dy']},{e['peak']},{e['valid_bins']},{int(bool(code))},{code});")
 return '\n'.join(body),e
def run():
 start=time.monotonic();rng=np.random.default_rng(20481);results=[]
 for n in (8,16,32):
  a=rng.integers(0,256,(n,n),dtype=np.uint8);body=[];audit=[]
  shifts=[(0,0),(1,-2),(-n//2,n//2-1),(-3,2)] if n==8 else [(3,-2),(-n//2,n//2-1)]
  for dx,dy in shifts:
   b=np.roll(a,(dy,dx),(0,1));text,e=frame_body(a,b);body.append(text)
   nf=numpy_oracle(a,b);cv,response=cv2.phaseCorrelate(a.astype(np.float64),b.astype(np.float64))
   assert (e['dx'],e['dy'])==(nf['dx'],nf['dy'])==(-dx if dx!=-n//2 else -n//2,-dy if dy!=-n//2 else -n//2),(n,dx,dy,e,nf)
   assert not e['invalid']
   assert all(abs((-cv[k]-e[key]+n/2)%n-n/2)<1e-5 for k,key in enumerate(('dx','dy'))),(n,cv,e)
   assert abs(e['peak']/1048576-nf['peak'])<.01
   audit.append({'input_B_roll':[dx,dy],'integer':e,'numpy':nf,'opencv_B_shift':list(cv),'opencv_response':response})
  if n==8:
   a_gain=rng.integers(0,96,(n,n),dtype=np.uint8);b_gain=(np.roll(a_gain,(2,-3),(0,1)).astype(np.uint16)*2+40).astype(np.uint8)
   text,e=frame_body(a_gain,b_gain);nf=numpy_oracle(a_gain,b_gain);cv,response=cv2.phaseCorrelate(a_gain.astype(np.float64),b_gain.astype(np.float64))
   assert (e['dx'],e['dy'])==(nf['dx'],nf['dy'])==(3,-2) and not e['invalid']
   assert abs(cv[0]+3)<1e-5 and abs(cv[1]-2)<1e-5
   body.append(text);audit.append({'gain_offset':True,'integer':e,'numpy':nf,'opencv_B_shift':list(cv),'opencv_response':response})
   for dc in (False,True):
    for a0,b0 in [(np.full((n,n),80,np.uint8),np.full((n,n),190,np.uint8)),(np.zeros((n,n),np.uint8),np.zeros((n,n),np.uint8)),((np.indices((n,n)).sum(axis=0)%2*255).astype(np.uint8),(np.indices((n,n)).sum(axis=0)%2*255).astype(np.uint8))]:
     text,e=frame_body(a0,b0,dc);assert e['invalid'];body.append(text);audit.append({'degenerate':True,'dc':dc,'integer':e})
   # Marker errors in all four categories, then successful repeated frame.
   for bad in (1,2,4,8,0):
    text,e=frame_body(a,np.roll(a,(1,2),(0,1)),True,bad);body.append(text)
  print('running',n,len(body),'frames',flush=True);print(simulate('\n'.join(body),n),flush=True)
  results.append({'side':n,'frames':len(body),'audit':audit,'status':'PASS'})
 from test_protocol import run as protocol
 protocol()
 result={'status':'PASS','profiles':results,'main_frames':sum(p['frames'] for p in results),'main_paired_pixels':sum(p['frames']*p['side']**2 for p in results),'protocol':{'reset_phases':10,'healthy_recovery_frames':10,'invalid_parameters':6},'opencv':cv2.__version__,'seconds':round(time.monotonic()-start,3),'rtl_sha256':hashlib.sha256((ROOT/'phase_correlation_frame.v').read_bytes()).hexdigest()}
 (ROOT/'test_result.json').write_text(json.dumps(result,indent=2)+'\n');print(result)
TB='''module tb;reg clk=0;always #5 clk=~clk;reg rst=1,ce=1,start_valid=0,cfg_remove_dc=1,s_valid=0,s_sof=0,s_eol=0,m_ready=0,done_ready=0;reg[7:0]s_a=0,s_b=0;wire start_ready,s_ready,m_valid,m_invalid,done_valid,done_error,busy;wire signed[6:0]m_dx,m_dy;wire signed[31:0]m_peak;wire[15:0]m_valid_bins;wire[7:0]error_code;
 phase_correlation_frame #(.SIDE(@SIDE@)) dut(.*);
 task beginframe;input dc;begin @(negedge clk);cfg_remove_dc=dc;start_valid=1;@(negedge clk);start_valid=0;cfg_remove_dc=!dc;if(done_error||error_code)$fatal(1,"start clear");end endtask
 task send;input[7:0]a,b;input sf,el;begin
 while(!s_ready)@(negedge clk);s_a=a;s_b=b;s_sof=sf;s_eol=el;s_valid=1;@(negedge clk);s_valid=0;
 ce=0;repeat(2)@(negedge clk);ce=1;end endtask
 task check;input signed[6:0]dx,dy;input signed[31:0]peak;input[15:0]expbins;input invalid;input[7:0]err;reg[63:0]held;integer pauses;begin
 pauses=0;while(!m_valid)begin @(negedge clk);pauses=pauses+1;ce=pauses%11!=0;end ce=1;
 if(m_dx!==dx||m_dy!==dy||m_peak!==peak||m_valid_bins!==expbins||m_invalid!==invalid||error_code!==err)$fatal(1,"got dx=%d dy=%d peak=%d bins=%d invalid=%d err=%h expected dx=%d dy=%d peak=%d bins=%d err=%h",m_dx,m_dy,m_peak,m_valid_bins,m_invalid,error_code,dx,dy,peak,expbins,err);
 held={m_dx,m_dy,m_peak,m_valid_bins,m_invalid};repeat(3)@(negedge clk);if(!m_valid||held!=={m_dx,m_dy,m_peak,m_valid_bins,m_invalid})$fatal(1,"backpressure");
 ce=0;m_ready=1;repeat(2)@(negedge clk);if(!m_valid||s_ready||start_ready)$fatal(1,"CE hold");ce=1;@(negedge clk);m_ready=0;
 if(!done_valid||done_error!==invalid)$fatal(1,"terminal");repeat(3)@(negedge clk);if(!done_valid||start_ready)$fatal(1,"DONE hold");
 ce=0;done_ready=1;@(negedge clk);if(!done_valid)$fatal(1,"DONE CE");ce=1;@(negedge clk);done_ready=0;if(busy||done_valid)$fatal(1,"DONE ack");
 end endtask
 initial begin repeat(2)@(negedge clk);rst=0;@BODY@ $display("PHASE PASS");$finish;end
 initial begin #1000000000;$fatal(1,"timeout");end endmodule'''
if __name__=='__main__':run()

