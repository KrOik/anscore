import sys,json,random,math,cmath
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'models'))
from reference import *
rng=random.Random(0x501);reports=[];worst_error=0
for l in range(1,9):
 for m in range(1,9):
  cfg,h=design(l,m);xs=[rng.randrange(-12000,12001) for _ in range(73)]
  fixed=integer_reference(xs,cfg);fp=float_reference(xs,l,m,h)
  assert len(fixed)==((len(xs)-1)*l+len(h)-1)//m+1
  error=max(abs(y-f*32768) for (y,_),f in zip(fixed,fp));worst_error=max(worst_error,error)
  assert error<math.ceil(len(h)/l)*.5+1,(l,m,error)
  # Distinct upsample-then-convolve integer realization.
  up=[0]*((len(xs)-1)*l+1)
  for i,x in enumerate(xs):up[i*l]=x
  full=[0]*(len(up)+len(h)-1)
  for i,x in enumerate(up):
   for k,c in enumerate(cfg.coefficients):full[i+k]+=x*c
  assert fixed==[(min(32767,max(-32768,rne(v))),int(not -32768<=rne(v)<=32767)) for v in full[::m]]
  metrics=spectrum_metrics(cfg)
  assert metrics['passband_max_abs_db']<.5,(l,m,metrics)
  assert metrics['stopband_attenuation_db']>40,(l,m,metrics)
  reports.append({'l':l,'m':m,**metrics})
tones=[]
for l,m,fin,kind in [(1,4,.01,'pass'),(1,4,.3,'alias_stop'),(2,3,.01,'pass'),(2,3,.45,'alias_stop'),(4,1,.01,'pass')]:
 cfg,_=design(l,m);n=4096;xs=[round(10000*math.sin(2*math.pi*fin*i)) for i in range(n)]
 ys=integer_reference(xs,cfg,flush=False);start=128;stop=len(ys)-128
 gain=2*abs(sum(ys[i][0]*cmath.exp(-2j*math.pi*fin*m/l*i) for i in range(start,stop)))/(stop-start)/10000
 if kind=='pass':assert abs(gain-1)<.015,(l,m,gain)
 else:assert gain<.0032,(l,m,gain)
 tones.append({'l':l,'m':m,'input_frequency':fin,'kind':kind,'measured_gain':gain})
# Interpolation image at k/L+f/L: input tone image must be suppressed.
cfg,_=design(4,1);xs=[round(10000*math.sin(2*math.pi*.01*i)) for i in range(2048)];ys=integer_reference(xs,cfg,False)
image_f=(1+.01)/4;start=256;stop=len(ys)-256
image_gain=2*abs(sum(ys[i][0]*cmath.exp(-2j*math.pi*image_f*i) for i in range(start,stop)))/(stop-start)/10000
assert image_gain<.0032,image_gain
for bad in [(0,1,(1,)),(1,9,(1,)),(3,1,(1,1))]:
 try:Config(*bad)
 except ValueError:pass
 else:raise AssertionError('illegal accepted')
print(json.dumps({'status':'PASS','all_ratio_spectrum':reports,'max_float_error_lsb':worst_error,'tones':tones,'interpolation_image_gain':image_gain},indent=2))
