"""Stage the optimized CIC candidate without changing shared generators or production RTL."""
from pathlib import Path
import sys
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parents[1]))
import make_dsp_case
original=make_dsp_case.dependencies
def dependencies(name):
 if name!='cic':raise ValueError('this isolated staging script only stages CIC')
 return [make_dsp_case.SV/'rtl/cip_cic_decimator.v',HERE/'cip_dsp_cic_decimator.v']
make_dsp_case.dependencies=dependencies
if __name__=='__main__':
 sys.argv[1:1]=['--case','cic']
 make_dsp_case.main()
