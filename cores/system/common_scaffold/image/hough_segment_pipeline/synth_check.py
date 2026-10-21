import tempfile,json
from pathlib import Path
from run_tests import HERE,SOURCES,execute,hashes
frozen=hashes();profiles=[]
for w,h,step in [(7,9,5),(16,16,1),(32,32,1)]:
 with tempfile.TemporaryDirectory(prefix='hough_pipeline_synth_') as tmp:
  d=Path(tmp);(d/'run.ys').write_text('read_verilog -sv '+' '.join(p.as_posix() for p in SOURCES)+f'''
chparam -set WIDTH {w} -set HEIGHT {h} -set THETA_STEP {step} -set TRIG_FILE "{(HERE/'trig.mem').as_posix()}" hough_segment_pipeline
synth_gowin -top hough_segment_pipeline
check -assert
stat
''')
  result=execute(['yosys','-Q','-T','-s',d/'run.ys'],d,d/'yosys.log',timeout=300)
  row=dict(width=w,height=h,theta_step=step,stat=result[result.rfind('=== hough_segment_pipeline ==='):].strip());profiles.append(row);print(row,flush=True)
assert frozen==hashes()
(HERE/'synthesis_result.json').write_text(json.dumps(dict(status='PASS',profiles=profiles,sources=frozen),indent=2)+'\n')
