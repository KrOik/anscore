"""libjpeg-style narrow chroma plane fallback, all supported sampling ratios."""
import json,numpy as np
from run_tests import HERE,jpeg,run_case,hashes
def main():
 rng=np.random.default_rng(541);rows=[]
 for sampling in [0,1,2]:
  for w in [1,2,3]:
   a=rng.integers(0,256,(7,w,3));row=run_case(f'narrow_s{sampling}_w{w}',jpeg(a,85,True,sampling),w,7);rows.append(row);print(row,flush=True)
 (HERE/'narrow_evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes(),cases=rows),indent=2)+'\n')
if __name__=='__main__':main()
