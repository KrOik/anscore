from pathlib import Path
import sys,json,math
import numpy as np
import cv2
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H))
from run_tests import pyramid,CIRCLE
rng=np.random.default_rng(311);rows=[]
for bits in (8,10,12):
 for h,w in ((1,3),(17,19),(65,65)):
  im=rng.integers(0,1<<bits,(h,w),dtype=np.uint16 if bits>8 else np.uint8)
  pyr=pyramid(im,3);ref=im;fast_checks=[]
  for level in range(3):
   assert np.array_equal(pyr[level],ref),(bits,h,w,level)
   if bits==8 and ref.shape[0]>=7 and ref.shape[1]>=7:
    threshold=15;actual={(round(k.pt[0]),round(k.pt[1])) for k in cv2.FastFeatureDetector_create(threshold=threshold,nonmaxSuppression=False,type=cv2.FAST_FEATURE_DETECTOR_TYPE_9_16).detect(ref)}
    hh,ww=ref.shape;mat=ref.astype(np.int64);d=np.stack([mat[3+dy:hh-3+dy,3+dx:ww-3+dx]-mat[3:hh-3,3:ww-3] for dx,dy in CIRCLE])
    strength=np.max(np.stack([np.maximum(np.min(d[[(start+k)%16 for k in range(9)]],axis=0),np.min(-d[[(start+k)%16 for k in range(9)]],axis=0)) for start in range(16)]),axis=0)
    yy,xx=np.nonzero(strength>threshold);expected=set(zip((xx+3).tolist(),(yy+3).tolist()));assert actual==expected,(bits,h,w,level,len(actual),len(expected))
    fast_checks.append({'level':level,'corners':len(actual)})
   if level<2:ref=cv2.pyrDown(ref,dstsize=((ref.shape[1]+1)//2,(ref.shape[0]+1)//2),borderType=cv2.BORDER_REFLECT_101)
  rows.append({'bits':bits,'width':w,'height':h,'pyramid_levels_exact':3,'fast9_checks':fast_checks})
result={'result':'PASS','opencv_version':cv2.__version__,'cases':rows,'pyramid_exact_checks':27,'actual_pyrdown_reductions':18,'scope':'actual cv2 pyrDown and FAST9 nonmaxSuppression=False versus independent integer component oracle; full RTL is compared with that oracle by run_tests.py'}
(H/'external_evidence.json').write_text(json.dumps(result,indent=2)+'\n');print('PASS OpenCV',cv2.__version__,27,'pyrDown exact layers, FAST9 coordinate sets')
