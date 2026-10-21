import os,json,hashlib,subprocess,tempfile
from pathlib import Path
import numpy as np
import cv2
ROOT=Path(__file__).resolve().parent
OSS=ROOT.parents[3]/'tools/oss-cad-suite/oss-cad-suite'
os.environ['PATH']=os.pathsep.join([str(OSS/'bin'),str(OSS/'lib'),os.environ.get('PATH','')])
def oracle(v,inv):
 a,b,c=map(int,v)
 if not inv:
  mx=max(v);d=mx-min(v)
  if not d:return (0,0,int(mx))
  h=(b-c)%(6*d) if a==mx else (c-a+2*d if b==mx else a-b+4*d)
  return ((256*h+3*d)//(6*d)%256,(255*d+mx//2)//mx,int(mx))
 z=6*a;s=z//255;f=z%255
 if a==255:s=0;f=0
 p=(c*(255-b)+127)//255
 q=(c*(65025-b*f)+32512)//65025
 t=(c*(65025-b*(255-f))+32512)//65025
 return [(c,t,p),(q,c,p),(p,c,t),(p,q,c),(t,p,c),(c,p,q)][s]
def run():
 rng=np.random.default_rng(41072);vectors=[]
 for inv in (0,1):
  x=np.concatenate([rng.integers(0,256,(2048,3),dtype=np.uint8),np.array([[k,k,k] for k in range(256)],dtype=np.uint8),np.array([[h,s,v] for h in (0,1,42,43,84,85,127,128,169,170,212,213,254,255) for s in (0,1,128,254,255) for v in (0,1,128,254,255)],dtype=np.uint8)])
  expected=np.array([oracle(tuple(map(int,v)),inv) for v in x],dtype=np.uint8)
  actual=cv2.cvtColor(x[None],cv2.COLOR_HSV2RGB_FULL if inv else cv2.COLOR_RGB2HSV_FULL)[0]
  diff=np.abs(expected.astype(int)-actual.astype(int))
  if not inv:diff[:,0]=np.minimum(diff[:,0],256-diff[:,0])
  assert np.max(diff)<=1,(inv,diff.max(axis=0))
  vectors.append((inv,x,expected,diff.max(axis=0).tolist()))
 with tempfile.TemporaryDirectory(prefix='hsv_full_') as td:
  td=Path(td);body=[]
  for inv,x,expected,_ in vectors:
   for v,e in zip(x,expected):
    pack=lambda q:sum(int(z)<<sh for z,sh in zip(q,(16,8,0)))
    body.append(f"send(1'b{inv},24'h{pack(v):06x},24'h{pack(e):06x});")
  tb='''module tb;reg clk=0;always #5 clk=~clk;reg rst=1,ce=1,start_valid=0,cfg_inverse=0,s_valid=0,s_sof=1,s_eol=1,m_ready=0,done_ready=0;wire done_valid;wire[3:0]error_code;reg[23:0]s_data=0;wire start_ready,s_ready,m_valid,m_sof,m_eol,done,error,busy;wire[23:0]m_data;
 rgb_hsv_full_stream #(.WIDTH(1),.HEIGHT(1)) dut(.*);
 task send;input inv;input[23:0]v,e;reg[23:0]held;begin
 @(negedge clk);cfg_inverse=inv;start_valid=1;@(negedge clk);start_valid=0;cfg_inverse=!inv;s_data=v;s_valid=1;
 while(!s_ready)@(negedge clk);@(negedge clk);s_valid=0;
 while(!m_valid)@(negedge clk);
 if(m_data!==e||!m_sof||!m_eol||error)$fatal(1,"result got=%h expected=%h",m_data,e);
 held=m_data;ce=0;m_ready=1;repeat(2)@(negedge clk);
 if(m_data!==held||!m_valid)$fatal(1,"CE hold");ce=1;m_ready=0;repeat(2)@(negedge clk);
 if(m_data!==held||!m_valid)$fatal(1,"backpressure hold");m_ready=1;@(negedge clk);m_ready=0;
 if(!done||!done_valid||!busy)$fatal(1,"terminal");repeat(2)@(negedge clk);if(!done_valid||start_ready)$fatal(1,"done not held");ce=0;done_ready=1;@(negedge clk);if(!done_valid)$fatal(1,"done CE hold");ce=1;@(negedge clk);done_ready=0;if(done_valid||busy)$fatal(1,"done ack");
 end endtask
 initial begin repeat(2)@(negedge clk);rst=0;
 '''+'\n'.join(body)+'''\n$display("HSV PASS");$finish;end
 initial begin #20000000;$fatal(1,"timeout");end endmodule'''
  (td/'tb.v').write_text(tb)
  subprocess.run(['iverilog','-g2012','-s','tb','-o',str(td/'tb'),str(ROOT/'rgb_hsv_full_stream.v'),str(td/'tb.v')],check=True,capture_output=True)
  p=subprocess.run(['vvp',str(td/'tb')],check=True,capture_output=True,text=True,timeout=90)
  print(p.stdout)
 from test_protocol import run as protocol
 protocol()
 result={'status':'PASS','opencv':cv2.__version__,'pixels':sum(len(x) for _,x,_,_ in vectors),'protocol':{'frames':11,'pixels':66,'reset_phases':6,'invalid_geometries':4},'opencv_max_abs_difference':[{'inverse':bool(i),'channels':d} for i,_,_,d in vectors],'rtl_sha256':hashlib.sha256((ROOT/'rgb_hsv_full_stream.v').read_bytes()).hexdigest()}
 (ROOT/'test_result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
if __name__=='__main__':run()


