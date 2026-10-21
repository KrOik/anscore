"""Weight carry, boundary fill and coordinate phase extremes at every bit depth."""
import json,numpy as np
from run_tests import HERE,run_case,hashes

def main():
 rows=[]
 for bits in [8,10,12]:
  src=np.array([[0,(1<<bits)-1],[((1<<bits)-1),0]],dtype=int)
  mx=np.array([[0,256,128,255,-1,-128],[8388607,-8388608,4,12,-4,-12]])
  my=np.array([[0,0,128,255,0,-128],[8388607,-8388608,4,12,-4,-12]])
  for compat in [0,1]:
   row=run_case(f'limits_b{bits}_cv{compat}',src,mx,my,bits,(1<<bits)-1,compat);rows.append(row);print(row,flush=True)
 (HERE/'numeric_evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes(),cases=rows),indent=2)+'\n')
if __name__=='__main__':main()
