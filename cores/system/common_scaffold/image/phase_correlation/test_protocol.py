import tempfile,subprocess
from pathlib import Path
import numpy as np
from run_tests import ROOT,simulate,frame_body
def run():
 n=8;a=np.random.default_rng(8321).integers(0,256,(n,n),dtype=np.uint8);b=np.roll(a,(2,-1),(0,1));good,_=frame_body(a,b)
 body=[]
 # Capture; synchronous FFT RAM read; butterfly multiply; crosspower multiply;
 # square-root; normalization division; inverse FFT; peak RAM read; held output/DONE.
 for phase in (1,3,40,17,29,41,35,38,39):
  body.append('beginframe(1);')
  if phase!=1:
   for y in range(n):
    for x in range(n):body.append(f'send({int(a[y,x])},{int(b[y,x])},{int(x==y==0)},{int(x==n-1)});')
  if phase==39:body.append('m_ready=1;')
  body.append(f'while(dut.state!={phase})@(negedge clk);ce=0;rst=1;@(negedge clk);if(busy||m_valid||done_valid||done_error||error_code||s_ready||start_ready)$fatal(1,"reset phase {phase}");rst=0;ce=1;m_ready=0;')
  body.append(good)
 # Inverse FFT specifically, not only a forward arithmetic reset.
 body.append('beginframe(1);')
 for y in range(n):
  for x in range(n):body.append(f'send({int(a[y,x])},{int(b[y,x])},{int(x==y==0)},{int(x==n-1)});')
 body.append('while(!(dut.inverse&&dut.state==40))@(negedge clk);ce=0;rst=1;@(negedge clk);if(busy||m_valid||done_valid||done_error||error_code)$fatal(1,"inverse reset");rst=0;ce=1;')
 body.append(good)
 print(simulate('\n'.join(body)))
 with tempfile.TemporaryDirectory(prefix='phase_invalid_') as td:
  td=Path(td)
  for n in (0,1,2,4,12,64):
   (td/'bad.v').write_text(f'module bad;phase_correlation_frame #(.SIDE({n})) dut();endmodule')
   p=subprocess.run(['iverilog','-g2012','-s','bad','-o',str(td/'sim'),str(ROOT/'phase_correlation_frame.v'),str(td/'bad.v')],cwd=ROOT,capture_output=True,text=True)
   if p.returncode:raise RuntimeError(p.stderr)
   p=subprocess.run(['vvp',str(td/'sim')],cwd=ROOT,capture_output=True,text=True)
   assert p.returncode!=0 and 'SIDE must be 8/16/32' in p.stdout
 print('PROTOCOL PASS reset_phases=10 healthy_recovery=10 invalid_parameters=6')
if __name__=='__main__':run()
