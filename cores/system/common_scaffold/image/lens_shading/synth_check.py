import tempfile,json,re
from pathlib import Path
from run_tests import HERE,SOURCES,execute,hashes
frozen=hashes();profiles=[]
for w,h,b,gw,gh in [(33,25,12,3,3),(35,27,10,5,5)]:
 with tempfile.TemporaryDirectory(prefix='lens_shading_synth_')as tmp:
  p=Path(tmp);(p/'run.ys').write_text('read_verilog -sv '+SOURCES[0].as_posix()+f'\nchparam -set WIDTH {w} -set HEIGHT {h} -set BITS {b} -set GRID_WIDTH {gw} -set GRID_HEIGHT {gh} lens_shading\nsynth_gowin -top lens_shading -nodsp\ncheck -assert\nstat\n')
  text=execute(['yosys','-Q','-T','-s',p/'run.ys'],p,p/'yosys.log',timeout=360);stat=text[text.rfind('=== lens_shading ==='):];cells={name:int(n)for n,name in re.findall(r'^\s*(\d+)\s+(\w+)\s*$',stat,re.M)}
  lut=sum(v for k,v in cells.items()if k.startswith(('LUT','ALU','MUX')))+4*sum(v for k,v in cells.items()if k.startswith('RAM16'))
  dsp=sum(v for k,v in cells.items()if k.startswith(('MULT','DSP')));assert lut<=15000 and dsp<=4
  row=dict(width=w,height=h,bits=b,grid_width=gw,grid_height=gh,lut_class=lut,dsp=dsp,cells=cells,conservative_bram9_units=2*sum(v for k,v in cells.items()if k in('SP','DP','SDP','DPB','SDPB','DPX9B','SDPX9B','SPX9')),stat=stat);profiles.append(row);print(row,flush=True)
assert frozen==hashes()
(HERE/'synthesis_result.json').write_text(json.dumps(dict(status='PASS',sources=frozen,profiles=profiles),indent=2)+'\n')
