import tempfile,json,re,hashlib
from pathlib import Path
from run_tests import H,RTL,execute
profiles=[]
for w,h in [(720,288),(16,12)]:
 with tempfile.TemporaryDirectory(prefix='bt656_synth_') as td:
  d=Path(td);(d/'run.ys').write_text(f'read_verilog -sv {RTL.as_posix()}\nchparam -set MAX_WIDTH {w} -set MAX_FIELD_LINES {h} bt656_rx\nsynth_gowin -top bt656_rx -nodsp\ncheck -assert\nstat\n')
  out=execute(['yosys','-Q','-T','-s',d/'run.ys'],H,H/f'synthesis_{w}x{h}.log',timeout=600)
  stats=out[out.rfind('=== bt656_rx ==='):];cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',stats,re.M)}
  lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+cells.get('RAM16SDP4',0)*4;dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k);bram=sum(v*2 for k,v in cells.items() if k in ['DPB','DPX9B','SDPB','SDPX9B','SP','SPX9'])
  row=dict(width=w,height=h,lut_class=lut,dsp=dsp,bram9=bram,cells=cells);profiles.append(row);print(json.dumps(row),flush=True);assert lut<=15000 and dsp<=4 and bram<=46
(H/'synthesis.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),profiles=profiles),indent=2)+'\n')
