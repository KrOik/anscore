import sys,json,random,math
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'models'))
from reference import *

def direct_integer(xs,sections):
 h=[[0,0,0,0] for _ in sections];out=[]
 for x in xs:
  clip=0
  for k,(b0,b1,b2,a1,a2) in enumerate(sections):
   x1,x2,y1,y2=h[k]
   wide=rne(b0*x+b1*x1+b2*x2-a1*y1-a2*y2)
   y=min(32767,max(-32768,wide));clip|=int(y!=wide)
   h[k]=[x,x1,y,y1];x=y
  out.append((x,clip))
 return out

def run():
 rng=random.Random(0x502)
 configs={'identity':(IDENTITY,), 'lowpass':(lowpass(),),
 'double_real_pole':((8192,0,0,-32768,8192),),
 'near_margin':((32,0,0,-32736,0),),
 'cascade4':(lowpass(),)*4,'saturating':((131071,0,0,-16384,0),),
 'signed_coeff_extrema':((-131072,131071,-32768,16384,8192),),
 'positive_a2_margin':((32,0,0,0,32736),)}
 xslist=[[0]*4096,[12000]*4096,[20000]+[0]*4095,
         [-32768,32767]*2048,[rng.randrange(-32768,32768) for _ in range(4096)],
         [int(12000*math.sin(i*2*math.pi*1000/48000)) for i in range(4096)]]
 reports={};cases=0
 for name,sections in configs.items():
  worst=0.;clips=0
  for xs in xslist:
   m=IntegerModel();m.configure(sections)
   result=[m.step(x) for x in xs]
   assert result==direct_integer(xs,sections),(name,'realization mismatch')
   fp=float_reference(xs,Config(sections))
   worst=max(worst,max(abs(a[0]-b*32768) for a,b in zip(result,fp)))
   clips+=sum(a[1] for a in result);cases+=1
  # Decay and quantization limit behavior measured after a long zero tail.
  m=IntegerModel();m.configure(sections)
  for _ in range(1024):m.step(10000)
  tail=[m.step(0)[0] for _ in range(16000)]
  limit=max(abs(x) for x in tail[-1024:])
  assert limit<=512,(name,limit)
  assert worst<3000,(name,worst)
  reports[name]={'max_float_error_lsb':worst,'clipped_samples':clips,'zero_tail_peak_last1024':limit}
 assert reports['identity']['max_float_error_lsb']==0
 assert reports['saturating']['clipped_samples']>4096
 # Retain changes coefficients without altering internal state at commit.
 m=IntegerModel();m.configure((lowpass(),));[m.step(10000) for _ in range(100)]
 before=[s.copy() for s in m.state];m.configure(((8192,0,0,-32768,8192),),clear=False)
 assert m.state==before
 retain=[m.step(x) for x in [32767]*128+[0]*4096]
 assert all(-32768<=x<=32767 for x,_ in retain)
 cleared=IntegerModel();cleared.configure(((8192,0,0,-32768,8192),))
 clear_trace=[cleared.step(x) for x in [32767]*128+[0]*4096]
 assert retain[:16]!=clear_trace[:16]
 retain_effect=max(abs(a[0]-b[0]) for a,b in zip(retain,clear_trace))
 m.configure((IDENTITY,),clear=True);assert m.step(7)==(7,0)
 for sections in [((0,0,0,-32768,0),),((0,0,0,0,32768),),((0,0,0,0,-32768),),()]:
  try:validate(sections)
  except ValueError:pass
  else:raise AssertionError('unstable/out-of-range accepted')
 try:m.configure((IDENTITY,IDENTITY),clear=False)
 except ValueError:pass
 else:raise AssertionError('retain count change accepted')
 return {'status':'PASS','vector_cases':cases,'samples_per_case':4096,'filters':reports,
 'retain_switch':{'clipped_samples':sum(c for _,c in retain),'tail_peak':max(abs(x) for x,_ in retain[-1024:]),
 'first16':[x for x,_ in retain[:16]],'max_difference_vs_clear_lsb':retain_effect},
 'scope':'sample-domain model validation, not II1/timing/physical qualification'}
if __name__=='__main__':print(json.dumps(run(),indent=2))
