import tempfile,json,re
from pathlib import Path
from run_tests import HERE,RTL,execute,hashes
frozen=hashes();profiles=[]
for bits,compat in [(8,0),(10,1),(12,0)]:
 with tempfile.TemporaryDirectory(prefix='stereo_rectify_synth_') as tmp:
  d=Path(tmp);(d/'run.ys').write_text('read_verilog -sv '+RTL.as_posix()+f'\nchparam -set BITS {bits} -set CV_COMPAT {compat} stereo_rectify\nsynth_gowin -top stereo_rectify -nodsp\ncheck -assert\nstat\n')
  text=execute(['yosys','-Q','-T','-s',d/'run.ys'],HERE.parents[3],d/'yosys.log',timeout=600)
  (HERE/f'synthesis_b{bits}_cv{compat}.log').write_text(text)
  stats=text[text.rfind('=== stereo_rectify ==='):];cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',stats,re.M)}
  lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+sum(v*4 for k,v in cells.items() if k=='RAM16SDP4');dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k)
  row=dict(bits=bits,cv_compat=compat,lut_class_including_lutram=lut,dsp=dsp,cells=cells,stats=stats);profiles.append(row);print(json.dumps(row),flush=True);assert lut<=15000 and dsp<=4,(lut,dsp)
assert hashes()==frozen
(HERE/'synthesis.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=profiles),indent=2)+'\n')
