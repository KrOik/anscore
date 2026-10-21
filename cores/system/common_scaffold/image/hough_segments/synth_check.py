import tempfile,json,hashlib
from pathlib import Path
from run_tests import HERE,execute
results=[]
for w,h in [(7,9),(16,16),(32,32)]:
 with tempfile.TemporaryDirectory(prefix='hough_segments_synth_') as tmp:
  d=Path(tmp);(d/'run.ys').write_text(f'''read_verilog -sv {(HERE/'hough_segments.sv').as_posix()}
chparam -set WIDTH {w} -set HEIGHT {h} -set TRIG_FILE "{(HERE/'trig.mem').as_posix()}" hough_segments
synth_gowin -top hough_segments
check -assert
stat
''')
  result=execute(['yosys','-Q','-T','-s',d/'run.ys'],d,d/'yosys.log',timeout=300)
  row=dict(width=w,height=h,stat=result[result.rfind('=== hough_segments ==='):].strip());results.append(row);print(row,flush=True)
(HERE/'synthesis_result.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256((HERE/'hough_segments.sv').read_bytes()).hexdigest(),profiles=results),indent=2)+'\n')
