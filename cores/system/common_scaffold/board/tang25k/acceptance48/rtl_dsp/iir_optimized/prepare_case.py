from pathlib import Path
import sys
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
import make_dsp_case as generate
original=generate.dependencies
def dependencies(name):
 return [HERE/'cip_dsp_iir_biquad.v' if p.name=='cip_dsp_iir_biquad.v' else p for p in original(name)]
generate.dependencies=dependencies
generate.main()
