"""Advanced denoise and DCP bounded numerical board profiles."""
from pathlib import Path
import random,sys
HERE=Path(__file__).resolve().parent;COMMON=HERE.parents[2];SV=COMMON/'signal_video'
sys.path.insert(0,str(SV))
CASE_NAMES=['guided_filter','nlm_denoise','dark_channel','transmission','recover','dehaze']
IDS=[b'GUID',b'NLMD',b'DARK',b'TRAN',b'RECV',b'DHAZ']
def describe(name):
 sources=[SV/'rtl'/('cip_image_'+name+'.v')];bits=16 if name=='transmission' else 8 if name in CASE_NAMES[:2] else 24
 params={'MAX_WIDTH':3 if name=='dehaze' else 8,'MAX_HEIGHT':3 if name=='dehaze' else 6}
 if name in CASE_NAMES[:2]:
  params['GRAY_BITS']=8;sources += [COMMON/'image/filters/rtl'/('img_filter_'+('guided' if name=='guided_filter' else 'nlm')+'.v')]
  if name=='guided_filter':sources += [COMMON/'image/dehaze'/n for n in ['img_dh_guided_frame.v','img_dh_guided_refine.v']]
  else:sources += [COMMON/'image/filters/rtl'/n for n in ['img_filter_frame_engine.v','img_filter_exp_weight.v']]
 else:sources += [SV/'rtl/cip_image_dehaze_scalar_frame.v',*sorted((COMMON/'image/dehaze').glob('*.v'))]
 return {'module':'cip_image_'+name,'data_w':bits,'parameters':params,'sources':sources,'case_id':int.from_bytes(IDS[CASE_NAMES.index(name)],'big'),'simulation_timeout_cycles':2000000}
class Builder:
 def __init__(self):self.commands=[];self.inputs=[];self.outputs=[];self.aux=[]
 def add(self,mode,w,h,p0,p1,image,out,aux=None,dw=None,dh=None,error=0,encoded=False):
  dw=w if dw is None else dw;dh=h if dh is None else dh;aux=[] if aux is None else aux
  fields=[(mode,0),((0x30+len(self.commands))&255,4),(w,12),(h,28),(dw,44),(dh,60),(p0,76),(p1,108),(len(image),236),(len(out),252),(len(aux),268),(error,300),(len(self.inputs),302),(len(self.outputs),318),(len(self.aux),334)]
  self.commands.append(sum(v<<s for v,s in fields))
  def marked(data,width):return [v|(int(i==0)<<33)|(int(i%width==width-1)<<32) for i,v in enumerate(data)]
  self.inputs.extend(marked(image,w));self.aux.extend(marked(aux,w));self.outputs.extend(out if encoded else marked(out,dw))
 def done(self):return self.commands,self.inputs,self.outputs,self.aux,[]

def make_vectors(name):
 b=Builder();rng=random.Random(661734)
 if name in CASE_NAMES[:2]:
  from run_guided_nlm_tests import reference
  guided=name=='guided_filter'
  for w,h in [(1,1),(1,4),(3,3),(5,4)]:
   for pattern in range(3):
    a=[rng.randrange(256) for _ in range(w*h)];g=[rng.randrange(256) for _ in a]
    if pattern==0:a=[255]*len(a);g=[0]*len(g)
    if pattern==1:a=[255 if i%2 else 0 for i in range(w*h)]
    for p0,p1 in ([(0,1),(1,256),(2,6400),(3,16776960)] if guided else [(0,256),(256,7680),(257,10240),(769,65535)]):
     out=reference(a,g,w,h,p0,p1,guided);b.add(0,w,h,p0,p1,a,out,g if guided else [])
  b.add(1,2,2,0,256,[],[],error=1);b.add(0,2,2,0,0,[],[],error=2)
 else:
  from run_dehaze_adapters_tests import oracle
  kind=CASE_NAMES.index(name)-2
  for w,h in ([(1,1),(3,2),(3,3)] if kind==3 else [(1,1),(1,4),(3,3),(5,4)]):
   for pattern in range(4):
    a=[rng.randrange(256 if kind==1 else 1<<24) for _ in range(w*h)]
    if pattern==0:a=[0]*len(a)
    if pattern==1:a=[255 if kind==1 else 0xffffff]*len(a)
    aux=[rng.choice([0,1,32768,8192]) for _ in a]
    configs=([(r,0,0) for r in [0,1,3]] if kind==0 else [(8192<<16|om,A,0) for om,A in [(0,1),(32768,255),(30000,97)]] if kind==1 else [(t<<16,A,0) for t,A in [(1,0),(8192,0x5070a0),(32768,0xffffff)]] if kind==2 else [(8192<<16|30000,0xc0d0e0|(int(pattern!=0)<<24)|(int(pattern==3)<<27),pattern)])
    for p0,p1,mode in configs:
     out=oracle(kind,a,aux,w,h,p0,p1,mode);b.add(mode,w,h,p0,p1,a,out,aux if kind==2 else [])
  b.add(15,2,2,0,0,[],[],error=1)
 return b.done()
