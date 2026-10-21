import tempfile,json,hashlib,re
from run_tests import HERE,execute
results=[]
for w,h,step in [(7,5,5),(16,16,1),(32,32,1)]:
 with tempfile.TemporaryDirectory(prefix='full_hough_synth_') as td:
  from pathlib import Path
  d=Path(td)
  script=f'''read_verilog -sv {(HERE/'hough_lines_full.sv').as_posix()};
chparam -set WIDTH {w} -set HEIGHT {h} -set THETA_STEP {step} -set TRIG_FILE "{(HERE/'trig.mem').as_posix()}" hough_lines_full;
synth_gowin -top hough_lines_full
check -assert
stat'''
  (d/'run.ys').write_text(script)
  text=execute(['yosys','-Q','-T','-s',d/'run.ys'],d,d/'yosys.log',timeout=300)
  stat=text[text.rfind('=== hough_lines_full ==='):].strip()
  results.append(dict(width=w,height=h,step=step,stat=stat));print(results[-1],flush=True)
(HERE/'synthesis_result.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256((HERE/'hough_lines_full.sv').read_bytes()).hexdigest(),profiles=results),indent=2)+'\n')
