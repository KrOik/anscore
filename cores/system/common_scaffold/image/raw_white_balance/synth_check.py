import json,re,tempfile,hashlib
from pathlib import Path
from run_tests import H,ROOT,execute
rows=[];rtl=H/'raw_white_balance.sv';sha=hashlib.sha256(rtl.read_bytes()).hexdigest()
for w,h,b in [(32,24,12),(31,17,10),(8,6,8)]:
 with tempfile.TemporaryDirectory(prefix='raw_awb_synth_')as td:
  d=Path(td);(d/'run.ys').write_text(f'read_verilog -sv {rtl.as_posix()}\nchparam -set WIDTH {w} -set HEIGHT {h} -set BITS {b} raw_white_balance\nsynth_gowin -top raw_white_balance -nodsp\ncheck -assert\nstat\n')
  text=execute(['yosys','-Q','-T','-s',d/'run.ys'],d,d/'yosys.log',timeout=360)
  stat=text[text.rfind('=== raw_white_balance ==='):]
  cells={name:int(n)for n,name in re.findall(r'^\s*(\d+)\s+(\w+)\s*$',stat,re.M)}
  lut=sum(v for k,v in cells.items()if k.startswith(('LUT','ALU','MUX')))+4*sum(v for k,v in cells.items()if k.startswith('RAM16'))
  dsp=sum(v for k,v in cells.items()if k.startswith(('MULT','DSP')))
  assert lut<=15000 and dsp<=4,(lut,dsp)
  row=dict(width=w,height=h,bits=b,lut_class=lut,dsp=dsp,cells=cells,conservative_bram9_units=2*sum(v for k,v in cells.items()if k in('SP','DP','SDP','DPB','SDPB','DPX9B','SDPX9B','SPX9')),stat=stat)
  rows.append(row);print(json.dumps(row),flush=True)
assert sha==hashlib.sha256(rtl.read_bytes()).hexdigest()
(H/'synthesis_result.json').write_text(json.dumps(dict(result='PASS',rtl_sha256=sha,profiles=rows),indent=2)+'\n')
