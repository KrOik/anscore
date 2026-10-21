import tempfile,json,re
from pathlib import Path
from run_tests import HERE,SOURCES,execute,hashes
frozen=hashes();profiles=[]
for w,h,b in [(32,16,24),(64,32,24),(31,17,16)]:
 with tempfile.TemporaryDirectory(prefix='speckle_synth_')as tmp:
  p=Path(tmp);(p/'run.ys').write_text('read_verilog -sv '+SOURCES[0].as_posix()+f'\nchparam -set WIDTH {w} -set HEIGHT {h} -set DISP_BITS {b} disparity_speckle\nsynth_gowin -top disparity_speckle -nodsp\ncheck -assert\nstat\n')
  text=execute(['yosys','-Q','-T','-s',p/'run.ys'],p,p/'yosys.log',timeout=360);stat=text[text.rfind('=== disparity_speckle ==='):];cells={name:int(n)for n,name in re.findall(r'^\s*(\d+)\s+(\w+)\s*$',stat,re.M)}
  count=sum(v for k,v in cells.items()if k.startswith(('LUT','ALU','MUX')))+4*sum(v for k,v in cells.items()if k.startswith('RAM16'))
  dsp=sum(v for k,v in cells.items()if k.startswith(('MULT','DSP')));assert count<=15000 and dsp<=4
  row=dict(width=w,height=h,disp_bits=b,lut_class=count,dsp=dsp,cells=cells,conservative_bram9_units=2*sum(v for k,v in cells.items()if k in('SP','DP','SDP','DPB','SDPB','DPX9B','SDPX9B','SPX9')),stat=stat);profiles.append(row);print(row,flush=True)
assert frozen==hashes()
(HERE/'synthesis_result.json').write_text(json.dumps(dict(status='PASS',profiles=profiles,sources=frozen),indent=2)+'\n')
