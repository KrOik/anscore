import sys,random,json,math
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'models'))
from reference import *
rng=random.Random(0x504)
vectors=[[0]*200,[32767]*200,[-32768]*200,[-32768,32767]*100,
         [20000]+[0]*199,[int(21000*math.sin(i*.21)) for i in range(200)],
         [rng.randrange(-32768,32768) for _ in range(200)]]
cases=0; errors={'meanabs_lsb':0.,'rms_lsb':0.,'power_lsb':0.}
for block in [False,True]:
 for lg in range(7):
  for scale in [-8,-1,0,1,8,15]:
   cfg=Config(block,lg,scale,1234567)
   for xs in vectors:
    m=IntegerModel(cfg); got=[r for x in xs if (r:=m.step(x)) is not None]
    fp=floating_reference(xs,cfg)
    assert len(got)==len(fp)
    for a,b in zip(got,fp):
     ae=abs(a['meanabs']-b['meanabs']*32768)
     re=abs(a['rms']-b['rms']*32768)
     pe=abs(a['power']-b['power']*2**30)
     assert ae<=1.001 and re<=1.6 and pe<=32768.5,(cfg,ae,re,pe)
     errors['meanabs_lsb']=max(errors['meanabs_lsb'],ae)
     errors['rms_lsb']=max(errors['rms_lsb'],re)
     errors['power_lsb']=max(errors['power_lsb'],pe)
    m.configure(cfg)
    assert [r for x in xs if (r:=m.step(x)) is not None]==got
    cases+=1
assert rne(-3,2)==-2 and rne(-1,2)==0 and rne(3,2)==2
assert IntegerModel(Config(log2=0)).step(-32768)['rms']==32768
m=IntegerModel(Config(log2=2)); rs=[m.step(x) for x in [7,-7,7,-7,7]]
assert [r['position'] for r in rs]==[0,0,0,0,1]
for cfg in [dict(log2=7),dict(scale=-9),dict(threshold=-1)]:
 try:Config(**cfg)
 except ValueError:pass
 else:raise AssertionError('illegal config accepted')
print(json.dumps({'status':'PASS','cases':cases,'errors':errors,'scope':'algorithm models only'},indent=2))
