import tempfile,json,re
from pathlib import Path
from run_tests import HERE,RTL,execute,hashes
frozen=hashes();profiles=[]
for w,h in [(16,12),(257,173)]:
 with tempfile.TemporaryDirectory(prefix='png_encode_synth_') as tmp:
  d=Path(tmp);(d/'run.ys').write_text('read_verilog -sv '+RTL.as_posix()+f'\nchparam -set WIDTH {w} -set HEIGHT {h} png_encoder\nsynth_gowin -top png_encoder -nodsp\ncheck -assert\nstat\n')
  text=execute(['yosys','-Q','-T','-s',d/'run.ys'],HERE,d/'yosys.log',timeout=600);(HERE/f'synthesis_{w}x{h}.log').write_text(text)
  stats=text[text.rfind('=== png_encoder ==='):];cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',stats,re.M)}
  lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+sum(v*4 for k,v in cells.items() if k=='RAM16SDP4');dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k);bram=sum(v for k,v in cells.items() if k in ['DPB','DPX9B','SDPB','SDPX9B','SP','SPX9'])
  row=dict(width=w,height=h,lut_class_including_lutram=lut,dsp=dsp,bram9=bram,cells=cells);profiles.append(row);print(json.dumps(row),flush=True);assert lut<=15000 and dsp<=4 and bram<=46
assert hashes()==frozen
(HERE/'synthesis.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=profiles),indent=2)+'\n')
