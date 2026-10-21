import os,sys,json,tempfile,subprocess,hashlib,time,itertools
from pathlib import Path
import numpy as np
import cv2
sys.dont_write_bytecode=True
ROOT=Path(__file__).resolve().parent
OSS=ROOT.parents[3]/'tools/oss-cad-suite/oss-cad-suite'
os.environ['PATH']=os.pathsep.join([str(OSS/'bin'),str(OSS/'lib'),os.environ.get('PATH','')])
from oracle import oracle,mathematical
def simulate(body,w=1,h=1):
 with tempfile.TemporaryDirectory(prefix='cielab_') as temporary:
  td=Path(temporary);(td/'tb.v').write_text(TB.replace('@W@',str(w)).replace('@H@',str(h)).replace('@BODY@',body))
  p=subprocess.run(['iverilog','-g2012','-s','tb','-o',str(td/'sim'),str(ROOT/'rgb_cielab_stream.v'),str(td/'tb.v')],cwd=ROOT,capture_output=True,text=True)
  if p.returncode:raise RuntimeError(p.stderr)
  p=subprocess.run(['vvp',str(td/'sim')],cwd=ROOT,capture_output=True,text=True,timeout=180)
  if p.returncode:raise RuntimeError(p.stdout+p.stderr)
  assert 'CIELAB PASS' in p.stdout,p.stdout
 return p.stdout
def pack(v):return sum(int(x)<<s for x,s in zip(v,(16,8,0)))
def run():
 start=time.monotonic();rng=np.random.default_rng(1729)
 data=np.concatenate([rng.integers(0,256,(768,3),dtype=np.uint8),np.array([[i,i,i] for i in range(256)],dtype=np.uint8),np.array([[i,128,128] for i in range(256)],dtype=np.uint8),np.array(list(itertools.product((0,1,16,128,254,255),repeat=3)),dtype=np.uint8)])
 body=[];audit=[]
 for inverse in (False,True):
  expected=np.array([oracle(v,inverse) for v in data],dtype=np.uint8)
  independent=np.array([mathematical(v,inverse) for v in data],dtype=np.uint8)
  cv=cv2.cvtColor(data[None],cv2.COLOR_Lab2RGB if inverse else cv2.COLOR_RGB2Lab)[0]
  d=np.abs(expected.astype(int)-cv.astype(int));dm=np.abs(expected.astype(int)-independent.astype(int))
  print('audit',inverse,'opencv',d.max(axis=0),'mathematical',dm.max(axis=0),flush=True)
  assert d.max()<=2,(inverse,d.max(axis=0))
  assert dm.max()<=1,(inverse,dm.max(axis=0))
  audit.append({'inverse':inverse,'opencv_max_abs_difference':d.max(axis=0).tolist(),'independent_formula_max_abs_difference':dm.max(axis=0).tolist()})
  for v,e in zip(data,expected):body.append(f"frame(1'b{int(inverse)},24'h{pack(v):06x},24'h{pack(e):06x});")
 # Send an actual repeated-START RGB->Lab->RGB stream sequence, not only software roundtrip.
 rgb=data[:128];encoded=[oracle(v) for v in rgb];roundtrip=[oracle(v,True) for v in encoded]
 for v,l,r in zip(rgb,encoded,roundtrip):
  body.extend([f"frame(0,24'h{pack(v):06x},24'h{pack(l):06x});",f"frame(1,24'h{pack(l):06x},24'h{pack(r):06x});"])
 print(simulate('\n'.join(body)),flush=True)
 from test_protocol import run as protocol
 protocol()
 cv_roundtrip=cv2.cvtColor(cv2.cvtColor(rgb[None],cv2.COLOR_RGB2Lab),cv2.COLOR_Lab2RGB)[0]
 direct_roundtrip=np.array([mathematical(mathematical(v),True) for v in rgb],dtype=int)
 delta=np.abs(np.array(roundtrip).astype(int)-rgb.astype(int));worst=int(np.unravel_index(delta.argmax(),delta.shape)[0])
 result={'status':'PASS','pixels':len(data)*2+256,'opencv':cv2.__version__,'audit':audit,'protocol':{'frames':10,'pixels':60,'reset_phases':9,'recovery_frames':9,'invalid_geometries':4},'roundtrip_rgb_max_abs_difference':delta.max(axis=0).tolist(),'opencv_roundtrip_rgb_max_abs_difference':np.abs(cv_roundtrip.astype(int)-rgb.astype(int)).max(axis=0).tolist(),'direct_formula_roundtrip_rgb_max_abs_difference':np.abs(direct_roundtrip-rgb.astype(int)).max(axis=0).tolist(),'worst_roundtrip_example':{'rgb':rgb[worst].tolist(),'lab':list(encoded[worst]),'rtl_rgb':list(roundtrip[worst]),'opencv_rgb':cv_roundtrip[worst].tolist()},'seconds':round(time.monotonic()-start,3),'rtl_sha256':hashlib.sha256((ROOT/'rgb_cielab_stream.v').read_bytes()).hexdigest()}
 (ROOT/'test_result.json').write_text(json.dumps(result,indent=2)+'\n');print(result)
TB='''module tb;reg clk=0;always #5 clk=~clk;reg rst=1,ce=1,start_valid=0,cfg_inverse=0,s_valid=0,s_sof=1,s_eol=1,m_ready=0,done_ready=0;reg[23:0]s_data=0;wire start_ready,s_ready,m_valid,m_sof,m_eol,done_valid,done_error,busy;wire[3:0]error_code;wire[23:0]m_data;
 rgb_cielab_stream #(.WIDTH(@W@),.HEIGHT(@H@)) dut(.*);
 task startframe;input inv;begin @(negedge clk);cfg_inverse=inv;start_valid=1;@(negedge clk);start_valid=0;cfg_inverse=!inv;if(done_error||error_code)$fatal(1,"START clear");end endtask
 task pixel;input[23:0]v,e;input sf,el,os,oe;reg[23:0]held;begin
 s_data=v;s_sof=sf;s_eol=el;s_valid=1;while(!s_ready)@(negedge clk);@(negedge clk);s_valid=0;
 while(!m_valid)@(negedge clk);
 if(m_data!==e||m_sof!=os||m_eol!=oe)$fatal(1,"got %h expected %h",m_data,e);
 held=m_data;ce=0;m_ready=1;repeat(2)@(negedge clk);if(!m_valid||m_data!==held||s_ready||start_ready)$fatal(1,"CE hold");
 ce=1;m_ready=0;repeat(2)@(negedge clk);if(!m_valid||m_data!==held)$fatal(1,"backpressure");
 m_ready=1;@(negedge clk);m_ready=0;end endtask
 task ack;input[3:0]err;begin
 if(!done_valid||!busy||done_error!=(err!=0)||error_code!==err)$fatal(1,"DONE/error");
 repeat(2)@(negedge clk);if(!done_valid||start_ready)$fatal(1,"held DONE");ce=0;done_ready=1;@(negedge clk);if(!done_valid)$fatal(1,"CE DONE");
 ce=1;@(negedge clk);done_ready=0;if(done_valid||busy)$fatal(1,"DONE ack");end endtask
 task frame;input inv;input[23:0]v,e;begin startframe(inv);pixel(v,e,1,1,1,1);ack(0);end endtask
 initial begin repeat(2)@(negedge clk);rst=0;@BODY@ $display("CIELAB PASS");$finish;end
 initial begin #100000000;$fatal(1,"timeout");end endmodule'''
if __name__=='__main__':run()
