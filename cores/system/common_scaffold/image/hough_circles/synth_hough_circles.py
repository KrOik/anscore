"""Complete isolated Gowin mapping, including accumulator and offset ROMs."""
import subprocess,tempfile,json,hashlib
from run_tests import ROOT
results=[]
for w,h,mr,mc in ((7,5,4,8),(16,16,8,8),(32,32,31,32)):
 with tempfile.TemporaryDirectory(prefix='circles_synth_') as td:
  s=f'''read_verilog {(ROOT/'hough_circles_frame.v').as_posix()};
chparam -set WIDTH {w} -set HEIGHT {h} -set MAX_RADIUS {mr} -set MAX_CIRCLES {mc} -set OFFSET_FILE "{(ROOT/'offsets.mem').as_posix()}" -set META_FILE "{(ROOT/'metadata.mem').as_posix()}" hough_circles_frame;
synth_gowin -top hough_circles_frame; check -assert; stat'''
  p=subprocess.run(['yosys','-Q','-T','-p',s],cwd=ROOT,capture_output=True,text=True,timeout=180)
  if p.returncode:raise RuntimeError(p.stdout[-5000:]+p.stderr)
  results.append({'width':w,'height':h,'max_radius':mr,'max_circles':mc,'stat':p.stdout[p.stdout.rfind('=== hough_circles_frame ==='):].strip()})
result={'status':'PASS','rtl_sha256':hashlib.sha256((ROOT/'hough_circles_frame.v').read_bytes()).hexdigest(),'geometries':results}
(ROOT/'synthesis_result.json').write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
