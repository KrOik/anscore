import tempfile,json,re
from pathlib import Path
from run_tests import HERE,RTL,execute,hashes
frozen=hashes();profiles=[]
for bits in [8,10,12]:
 with tempfile.TemporaryDirectory(prefix='mhc_synth_') as tmp:
  d=Path(tmp);(d/'run.ys').write_text('read_verilog -sv '+RTL.as_posix()+f'\nchparam -set BITS {bits} malvar_demosaic\nsynth_gowin -top malvar_demosaic -nodsp\ncheck -assert\nstat\n')
  text=execute(['yosys','-Q','-T','-s',d/'run.ys'],HERE.parents[3],d/'yosys.log',timeout=600);(HERE/f'synthesis_b{bits}.log').write_text(text)
  stats=text[text.rfind('=== malvar_demosaic ==='):];cells={k:int(v) for v,k in re.findall(r'^\s*(\d+)\s+([A-Za-z0-9_]+)\s*$',stats,re.M)}
  lut=sum(v for k,v in cells.items() if k.startswith(('LUT','ALU','MUX')))+sum(v*4 for k,v in cells.items() if k=='RAM16SDP4');dsp=sum(v for k,v in cells.items() if 'MULT' in k or 'DSP' in k);bram=sum(v for k,v in cells.items() if k in ['DPB','DPX9B','SDPB','SDPX9B','SP','SPX9'])
  row=dict(bits=bits,width=32,height=24,lut_class_including_lutram=lut,dsp=dsp,bram=bram,cells=cells,stats=stats);profiles.append(row);print(json.dumps(row),flush=True);assert lut<=15000 and dsp<=4 and bram>0,(lut,dsp,bram)
assert hashes()==frozen
(HERE/'synthesis.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=profiles),indent=2)+'\n')
