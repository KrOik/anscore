"""Isolated CLAHE candidate staging; does not modify production or generators."""
from pathlib import Path
import sys
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent))
import make_case
original=make_case.dependencies
def dependencies(name):
 if name!='clahe':raise ValueError('CLAHE only')
 return [HERE/'candidate_v3'/p.name if p.name in ['cip_image_clahe.v','cip_image_clahe_frame.v'] else p for p in original(name)]
make_case.dependencies=dependencies
if __name__=='__main__':
 sys.argv[1:1]=['--case','clahe'];make_case.main()
