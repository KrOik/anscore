import tempfile,json,re
from pathlib import Path
from run_tests import HERE,SOURCES,execute,hashes
frozen=hashes();profiles=[]
for w,h,d,b in [(8,6,4,24),(16,8,8,24),(32,16,8,24)]:
 with tempfile.TemporaryDirectory(prefix='sgm_synth_') as tmp:
  p=Path(tmp);(p/'run.ys').write_text('read_verilog -sv '+SOURCES[0].as_posix()+f'\nchparam -set WIDTH {w} -set HEIGHT {h} -set DISPARITIES {d} -set DESC_BITS {b} stereo_sgm\nsynth_gowin -top stereo_sgm -nodsp\ncheck -assert\nstat\n')
  text=execute(['yosys','-Q','-T','-s',p/'run.ys'],p,p/'yosys.log',timeout=360)
  stat=text[text.rfind('=== stereo_sgm ==='):];cells={name:int(n) for n,name in re.findall(r'^\s*(\d+)\s+(\w+)\s*$',stat,re.M)}
  count=sum(v for k,v in cells.items()if k.startswith(('LUT','ALU','MUX')))+4*sum(v for k,v in cells.items()if k.startswith('RAM16'));dsp=sum(v for k,v in cells.items()if k.startswith(('MULT','DSP')))
  assert count<=15000 and dsp<=4,(count,dsp)
  row=dict(width=w,height=h,disparities=d,descriptor_bits=b,lut_class=count,dsp=dsp,cells=cells,stat=stat.strip());profiles.append(row);print(row,flush=True)
assert frozen==hashes()
(HERE/'synthesis_result.json').write_text(json.dumps(dict(status='PASS',profiles=profiles,sources=frozen),indent=2)+'\n')
