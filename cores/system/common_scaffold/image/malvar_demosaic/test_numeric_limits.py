"""Kernel sign-extreme patterns force negative sums and positive saturation at every bit depth."""
import json,numpy as np
from run_tests import HERE,run_case,oracle,hashes,G,H,C

def main():
 rows=[]
 for bits in [8,10,12]:
  peak=(1<<bits)-1
  for name,kernel,cy,cx,channel in [('green',G,2,2,1),('horizontal',H,2,3,0),('cross',C,2,2,2)]:
   for positive in [False,True]:
    cfa=np.zeros((7,7),dtype=int);cfa[cy-2:cy+3,cx-2:cx+3]=np.where(kernel>0 if positive else kernel<0,peak,0)
    result=oracle(cfa,0,bits);assert result[cy,cx,channel]==(peak if positive else 0)
    row=run_case(f'{name}_sign{int(positive)}_b{bits}',cfa,0,bits);rows.append(row);print(row,flush=True)
 (HERE/'numeric_evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes(),cases=rows,saturation_and_negative_clamp=True),indent=2)+'\n')
if __name__=='__main__':main()
