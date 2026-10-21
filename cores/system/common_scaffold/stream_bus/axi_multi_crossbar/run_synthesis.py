from pathlib import Path
import sys,tempfile,re,json,hashlib
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import execute
rtl=H/'axi_multi_crossbar.sv'
results=[]
for name,m,t,w,i in [('default',2,2,32,4),('maximum',4,4,64,8)]:
 with tempfile.TemporaryDirectory(prefix='axi_xbar_synth_') as td:
  p=Path(td); script=p/'s.ys'
  script.write_text(f'read_verilog -sv {rtl.as_posix()}\nchparam -set MASTERS {m} -set TARGETS {t} -set DATA_WIDTH {w} -set ID_WIDTH {i} axi_multi_crossbar\nsynth_gowin -top axi_multi_crossbar -nodsp\ncheck -assert\nstat\n',encoding='utf-8')
  out=execute(['yosys','-s',script],H,p/'s.log',timeout=600)
  tail=out[out.rfind('=== axi_multi_crossbar ==='):]
  cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',tail,re.M)}
  lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+4*cells.get('RAM16SDP4',0)
  dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k)
  results.append(dict(profile=name,masters=m,targets=t,data_width=w,id_width=i,cells=cells,lut_class=lut,dsp=dsp,status='PASS' if lut<=15000 and dsp<=4 else 'FAIL'))
  (H/f'synthesis_{name}.log').write_text(tail,encoding='utf-8')
  print(name,lut,dsp,flush=True)
(H/'synthesis_evidence.json').write_text(json.dumps(dict(rtl_sha256=hashlib.sha256(rtl.read_bytes()).hexdigest(),results=results),indent=2)+'\n',encoding='utf-8')
