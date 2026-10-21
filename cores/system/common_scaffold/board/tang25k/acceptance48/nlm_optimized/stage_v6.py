from pathlib import Path
import sys
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent))
import make_case
original=make_case.dependencies
def dependencies(name):
 if name!='nlm_denoise':raise ValueError(name)
 result=[]
 for p in original(name):
  if p.name=='img_filter_frame_engine.v':p=HERE/'candidate_v6/img_filter_nlm_serial_engine.v'
  elif p.name=='img_filter_nlm.v':p=HERE/'candidate_v6/img_filter_nlm.v'
  result.append(p)
 return result
make_case.dependencies=dependencies
sys.argv[1:1]=['--case','nlm_denoise']
make_case.main()
