import tempfile,json,re
from pathlib import Path
from run_tests import HERE,SOURCES,execute,hashes
frozen=hashes();profiles=[]
for w,h,db,df,qb,qf,ob,of in [(16,8,24,4,32,16,32,12),(32,16,24,12,32,28,32,16)]:
 with tempfile.TemporaryDirectory(prefix='reproject_synth_')as tmp:
  p=Path(tmp);params=dict(WIDTH=w,HEIGHT=h,DISP_BITS=db,DISP_FRAC=df,Q_BITS=qb,Q_FRAC=qf,OUT_BITS=ob,OUT_FRAC=of)
  (p/'run.ys').write_text('read_verilog -sv '+SOURCES[0].as_posix()+'\nchparam '+' '.join(f'-set {k} {v}'for k,v in params.items())+' disparity_reproject\nsynth_gowin -top disparity_reproject -nodsp\ncheck -assert\nstat\n')
  text=execute(['yosys','-Q','-T','-s',p/'run.ys'],p,p/'yosys.log',timeout=360);stat=text[text.rfind('=== disparity_reproject ==='):]
  cells={name:int(n)for n,name in re.findall(r'^\s*(\d+)\s+(\w+)\s*$',stat,re.M)}
  count=sum(v for k,v in cells.items()if k.startswith(('LUT','ALU','MUX')))+4*sum(v for k,v in cells.items()if k.startswith('RAM16'))
  dsp=sum(v for k,v in cells.items()if k.startswith(('MULT','DSP')));assert count<=15000 and dsp<=4
  profiles.append(dict(parameters=params,lut_class=count,dsp=dsp,cells=cells,stat=stat));print(profiles[-1],flush=True)
assert frozen==hashes()
(HERE/'synthesis_result.json').write_text(json.dumps(dict(status='PASS',profiles=profiles,sources=frozen),indent=2)+'\n')
