"""Coefficient-loaded projective/CNN and paired stitch bounded board profiles."""
from pathlib import Path
import random,sys
HERE=Path(__file__).resolve().parent;COMMON=HERE.parents[2];SV=COMMON/'signal_video'
sys.path.insert(0,str(SV))
CASE_NAMES=['affine','perspective','stitch','super_resolution','canny']
IDS=[b'AFFN',b'PERS',b'STCH',b'SRES',b'CANY']
def describe(name):
 sources=[SV/'rtl'/('cip_image_'+name+'.v')];bits=8 if name in ['super_resolution','canny'] else 24;params={'MAX_WIDTH':8,'MAX_HEIGHT':6}
 if name in ['affine','perspective','stitch']:
  sources += [COMMON.parents[1]/line.strip() for line in (COMMON/'image/rtl_sources.f').read_text().splitlines() if line.strip() and not line.startswith('#')]
  if name!='stitch':sources += [SV/'rtl/cip_image_projective_frame.v']
  else:params={'WIDTH':4,'HEIGHT':3,'MAX_SHIFT':1}
 if name=='super_resolution':params['FEATURES']=1
 if name=='canny':
  params['GRAY_BITS']=8;sources += [COMMON/'image/filters/rtl/img_edge_canny.v']
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
 b=Builder();rng=random.Random(88314);coeff=[]
 def load(mode,model):
  offset=len(coeff);b.add(mode,0,0,0,0,[],[]);b.commands[-1]|=len(model)<<284|offset<<350
  order=list(range(len(model)));rng.shuffle(order);coeff.extend((i<<32)|(model[i]&0xffffffff) for i in order)
 if name in ['affine','perspective']:
  from run_projective_tests import reference
  pers=name=='perspective';identity=[65536,0,0,0,65536,0,0,0,65536]
  matrices=[identity,[65536,0,32768,0,65536,16384,0,0,65536],[-65536,0,196608,0,65536,0,0,0,65536],[0,-65536,131072,65536,0,0,0,0,65536],[32768,16384,0,-8192,65536,65536,0,0,65536]]
  if pers:matrices += [[65536,0,0,0,65536,0,8192,4096,65536],[65536,0,0,0,65536,0,65536,0,0]]
  for m in matrices:
   load(2,m)
   for w,h,dw,dh in [(1,1,2,2),(4,3,5,4),(8,6,8,6)]:
    for mode in [0,1]:
     a=[rng.randrange(1<<24) for _ in range(w*h)];out,error=reference(a,w,h,dw,dh,mode,8,3,m,pers)
     b.add(mode,w,h,0,0,a,out,dw=dw,dh=dh,error=error,encoded=True)
  b.add(3,2,2,0,0,[],[],error=1)
 elif name=='stitch':
  from run_stitch_tests import registration,reference
  w,h,s=4,3,1
  for dy in [-1,0,1]:
   for dx in [-1,0,1]:
    a=[rng.randrange(1<<24) for _ in range(w*h)];aux=[rng.randrange(1<<24) for _ in a]
    for y in range(h):
     for x in range(w):
      if 0<=x+dx<w and 0<=y+dy<h:aux[(y+dy)*w+x+dx]=a[y*w+x]
    rx,ry,confidence=registration(a,aux,w,h,s)
    for weight in [0,128,256]:
     out=reference(a,aux,w,h,s,weight,0x71395b,rx,ry) if confidence>=1 else []
     b.add(0,w,h,weight,0x71395b,a,out,aux,dw=6,dh=5,error=0 if confidence>=1 else 2,encoded=True)
    out=reference(a,aux,w,h,s,127,0,dx,dy);b.add(1,w,h,127,((dy&65535)<<16)|(dx&65535),a,out,aux,dw=6,dh=5,encoded=True)
  a=[0]*12;out=[];b.add(0,4,3,128,0,a,out,a,dw=6,dh=5,error=2)
  b.add(2,4,3,0,0,[],[],dw=6,dh=5,error=1)
 elif name=='super_resolution':
  from run_super_resolution_tests import infer,model_for
  b.add(1,2,2,0,0,[],[],dw=4,dh=4,error=2)
  for kind in range(4):
   m=model_for(1,kind,rng);load(0,m)
   for w,h in [(1,1),(1,4),(3,3),(5,4)]:
    a=[rng.randrange(256) for _ in range(w*h)];b.add(1,w,h,0,0,a,infer(a,w,h,m,1),dw=w*2,dh=h*2)
  b.add(2,0,0,0,0,[],[],error=1)
 else:
  from run_canny_tests import canny
  for w,h in [(1,1),(1,6),(3,3),(5,4),(8,6)]:
   for pat in range(4):
    a=[rng.randrange(256) for _ in range(w*h)]
    if pat==0:a=[0]*len(a)
    if pat==1:a=[255 if i%w>=w//2 else 0 for i in range(w*h)]
    if pat==2:a=[255 if (i%w+i//w)%2 else 0 for i in range(w*h)]
    for low,high in [(0,0),(85,255),(255,1020)]:b.add(0,w,h,low,high,a,canny(a,w,h,low,high,255)[0])
  b.add(1,2,2,0,255,[],[],error=1)
 result=b.done();return (*result[:4],coeff)
