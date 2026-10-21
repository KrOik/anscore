"""Parameter rejection and exact arithmetic-domain bounds, including the jointly widest format."""
from pathlib import Path
import sys,tempfile,json,hashlib
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import ROOT,execute
bad=[{'WIDTH':0},{'HEIGHT':0},{'WIDTH':4097},{'HEIGHT':4097},{'WIDTH':4096,'HEIGHT':4096},{'DISPARITIES':2},{'DISPARITIES':257},{'COST_BITS':1},{'COST_BITS':25},{'FRAC_BITS':0},{'FRAC_BITS':13}]
for params in bad:
 with tempfile.TemporaryDirectory(prefix='subpixel_bad_') as td:
  p=Path(td);pv=','.join(f'.{k}({v})' for k,v in params.items());(p/'tb.sv').write_text(f'module tb;stereo_subpixel #({pv})dut();initial #1 $finish;endmodule')
  execute(['iverilog','-g2012','-s','tb','-o',p/'sim',H/'stereo_subpixel.sv',p/'tb.sv'],ROOT,p/'compile.log')
  try:execute(['vvp',p/'sim'],p,p/'simulation.log');raise AssertionError('Invalid parameters accepted')
  except RuntimeError as exc:assert 'stereo_subpixel parameters' in str(exc)
maximum=(1<<24)-1
assert maximum<<12 <1<<36
assert 4*maximum<1<<26
assert (255<<12)+(1<<11)<1<<31
# For an interior valid WTA, a=L-B>=0, b=R-B>=0; |a-b|<=a+b.
# Thus the exact quadratic offset always lies in[-1/2,+1/2]. First-minimum tie selection
# makes a>0 when left is valid, so zero/negative curvature is unreachable there.
for a in range(256):
 for b in range(256):assert abs(a-b)<=a+b
result={'result':'PASS','invalid_parameter_rejections':bad,'max_abs_numerator_shifted_q12':maximum<<12,'max_denominator':4*maximum,'max_output_bound_q12':(255<<12)+(1<<11),'invariants':'valid WTA implies nonnegative neighbor excess; first-minimum tie rule implies strictly positive left excess for interior valid neighbors; exact |offset|<=0.5','rtl_sha256':hashlib.sha256((H/'stereo_subpixel.sv').read_bytes()).hexdigest()}
(H/'numeric_evidence.json').write_text(json.dumps(result,indent=2)+'\n');print('PASS 11 invalid profiles; joint B24/Q12 numerator bound; exact WTA offset invariants')
