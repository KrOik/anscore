from pathlib import Path
from fractions import Fraction
import hashlib,json,subprocess,tempfile
from run_tests import H,oracle,nearest,run_profile
url='https://cdn.jsdelivr.net/gh/10x-Engineers/Infinite-ISP@master/modules/auto_white_balance/gray_world.py'
with tempfile.TemporaryDirectory(prefix='raw_awb_upstream_')as td:
 p=Path(td)/'gray_world.py'
 subprocess.run(['curl.exe','-fsL','--ssl-revoke-best-effort','--max-time','30','-o',str(p),url],check=True,capture_output=True)
 data=p.read_bytes();ns={'__name__':'reference_gray_world'};exec(compile(data,str(p),'exec'),ns)
 import numpy as np
 r=np.random.default_rng(20261019);rows=[];cases=[]
 for pattern in range(4):
  # Equal green values per CFA cell: actual upstream RGB gray-world equals
  # our pooled-green target; Gr/Gb gains are consequently exactly unity.
  vals=r.integers(1,4096,size=(12,3));raw=[]
  for y in range(6):
   for x in range(8):
    pidx=((y&1)*2+(x&1))^pattern;i=(y//2)*4+x//2
    raw.append(int(vals[i,[0,1,1,2][pidx]]))
  c=dict(pattern=pattern,auto=True,roi=[0,0,7,5],gate=[0,4095],bounds=[0,65535],manual=[4096]*4,data=raw,kind='actual_upstream_gray_world')
  _,_,g,_,_,err=oracle(8,6,12,c);assert not err
  gr,gb=ns['GrayWorld'](vals.astype(np.float64)).calculate_gains()
  assert g==[nearest(Fraction(int(vals[:,1].sum()),int(vals[:,0].sum()))*4096),4096,4096,nearest(Fraction(int(vals[:,1].sum()),int(vals[:,2].sum()))*4096)]
  assert abs(g[0]/4096-gr)<=1/8192+1e-12 and abs(g[3]/4096-gb)<=1/8192+1e-12
  rows.append(dict(pattern=pattern,actual_upstream_r_gain=float(gr),actual_upstream_b_gain=float(gb),expected_fixed_gains=g))
  cases.append(c)
 upstream_sha=hashlib.sha256(data).hexdigest()
 profile=run_profile(8,6,12,cases)
e=dict(result='PASS',rtl_sha256=hashlib.sha256((H/'raw_white_balance.sv').read_bytes()).hexdigest(),url=url,upstream_sha256=upstream_sha,actual_unmodified_source_executed=True,scope='Equal population complete CFA cells with Gr=Gb; comparison of G/R and G/B, Q12 error <=0.5 LSB. Different ROI/gating populations and four independent gains use the explicit local contract, not claimed upstream-equivalent.',rows=rows,rtl_profile=profile)
(H/'reference_result.json').write_text(json.dumps(e,indent=2)+'\n');print('PASS actual Infinite-ISP GrayWorld source, 4 patterns, 192 RTL outputs')
