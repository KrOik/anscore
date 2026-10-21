"""Isolated mapping includes the unchanged entropy bitpacker dependency."""
import tempfile,subprocess,json
from test_scan_control import ROOT,PACKER
with tempfile.TemporaryDirectory(prefix='jpeg_scan_synth_'):
 script=f'read_verilog -sv {PACKER.as_posix()} {(ROOT/"jpeg_entropy_scan_controller.v").as_posix()}; synth_gowin -top jpeg_entropy_scan_controller; stat'
 p=subprocess.run(['yosys','-Q','-T','-p',script],capture_output=True,text=True,timeout=180)
 if p.returncode:raise RuntimeError(p.stdout[-4000:]+p.stderr)
 result={'status':'PASS','includes_bitpacker':True,'stat':p.stdout[p.stdout.rfind('=== jpeg_entropy_scan_controller ==='):].strip()}
(ROOT/'synthesis_result.json').write_text(json.dumps(result,indent=2)+'\n')
print('PASS isolated flattened synthesis')

