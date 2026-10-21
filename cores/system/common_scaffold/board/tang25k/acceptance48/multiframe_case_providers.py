"""Bounded public-entry board fixtures with independent integer numerical models."""
from pathlib import Path
import random,sys
from case_provider_common import fixture_vectors
HERE=Path(__file__).resolve().parent;COMMON=HERE.parents[2];SV=COMMON/'signal_video'
sys.path.insert(0,str(SV))
CASE_NAMES=['window','frame_difference','background_model','fusion','osd','temporal_denoise','bilateral_filter']
IDS=[b'WIND',b'FDIF',b'BGMX',b'FUSN',b'OSDX',b'TEMP',b'BILT']
def describe(name):
 sources=[SV/'rtl'/('cip_image_'+name+'.v')];params={'MAX_WIDTH':8,'MAX_HEIGHT':6};bits=8
 if name=='window':sources += [COMMON/'image/window/img_window3x3_valid_draft.v']
 if name=='osd':
  bits=24;sources += [COMMON/'image/multiframe/img_mf_rgb_blend_pipe.v']
 if name=='fusion':
  bits=24;sources += [COMMON/'image/multiframe/img_mf_rgb_blend_partial_pipe.v',COMMON/'image/multiframe/cip_fusion_scalar_multiply.v']
 if name=='temporal_denoise':sources += [COMMON/'image/filters/rtl/img_filter_temporal_denoise.v']
 if name=='bilateral_filter':
  params={'MAX_WIDTH':8,'GRAY_BITS':8};sources += [SV/'rtl/cip_image_bilateral_frame.v',COMMON/'image/window/img_window3x3_valid_draft.v',COMMON/'image/filters/rtl/img_filter_bilateral3x3.v',COMMON/'image/filters/rtl/img_filter_exp_weight.v']
 return {'module':'cip_image_'+name,'data_w':bits,'parameters':params,'sources':sources,'case_id':int.from_bytes(IDS[CASE_NAMES.index(name)],'big')}
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
 if name=='bilateral_filter':
  from run_bilateral_tests import fixtures
  return fixture_vectors(lambda p:fixtures(p,8,8),select=lambda i,r:i in [0,4,8,13,17,22,26,31,35,40,44] or i>=45)
 b=Builder();rng=random.Random(913734)
 if name=='window':
  for w,h in [(3,3),(3,6),(8,3),(5,4),(8,6)]:
   for pattern in range(4):
    a=[rng.randrange(256) for _ in range(w*h)] if pattern==3 else [0 if pattern==0 else 255 if pattern==1 else i%256 for i in range(w*h)]
    out=[]
    for y in range(h-2):
     for x in range(w-2):
      for dy in range(3):
       for dx in range(3):out.append(a[(y+dy)*w+x+dx]|(int(x==0 and y==0 and dx==0 and dy==0)<<33)|(int(x==w-3 and dx==2 and dy==2)<<32))
    b.add(0,w,h,0,0,a,out,dw=w-2,dh=h-2,encoded=True)
  b.add(1,3,3,0,0,[],[],dw=1,dh=1,error=1)
  b.add(0,2,3,0,0,[],[],dw=1,dh=1,error=2)
  return b.done()
 history=None;shape=None
 for w,h in [(1,1),(3,2),(8,6),(2,3)]:
  for index in range(16):
   bits=24 if name in ['fusion','osd'] else 8;maximum=(1<<bits)-1
   a=[rng.randrange(maximum+1) for _ in range(w*h)];aux=[rng.randrange(maximum+1) for _ in a];out=[]
   if index==0:a=[0]*len(a)
   if index==1:a=[maximum]*len(a)
   mode=index%4;p0=0;p1=0;paired=[];valid=history is not None and shape==(w,h)
   if name=='frame_difference':
    p0=[0,80,255,127][index%4];paired=aux if mode<2 else [];prev=aux if mode<2 else history if valid else a
    out=[abs(x-y) if mode%2==0 else (maximum if abs(x-y)>p0 else 0) for x,y in zip(a,prev)]
    if mode>=2:history=a[:];shape=(w,h)
   elif name=='background_model':
    shift=[0,1,4,8][index%4];freeze=index%2;force=int(index==9);p0=[0,64,255][index%3];p1=shift|(freeze<<8)|(force<<9)
    valid=valid and not force;old=history if valid else [x*256 for x in a];updated=[]
    for x,y in zip(a,old):
     diff=abs(x-y//256) if valid else 0;foreground=valid and diff>p0;z=y if freeze and foreground else y+(x*256-y)//(1<<shift)
     updated.append(z);out.append([z//256,diff,maximum if foreground else 0,z][mode])
    history=updated;shape=(w,h)
    if mode==3:
     out=[((v>>(8*k))&255)|(int(i==0 and k==0)<<33)|(int(i%w==w-1 and k==1)<<32) for i,v in enumerate(out) for k in range(2)]
   elif name=='temporal_denoise':
    mode=int(index in [0,9]);p0=[0,64,128,256][index%4];p1=[0,40,255][index%3]
    prev=history if valid and mode==0 else a
    out=[x if abs(x-y)>p1 else (x*p0+y*(256-p0)+128)//256 for x,y in zip(a,prev)]
    history=out[:];shape=(w,h)
   else:
    paired=aux;p0=[0,1,128,256][index%4];p1=0x345678 if name=='osd' else 0;mode=mode if name=='osd' else index%2
    if name=='osd':
     aux[0]=p1
    for x,y in zip(a,aux):
     enabled=name=='fusion' or (mode!=0 and not(mode>=2 and y==p1));weight=256 if name=='osd' and mode==3 else p0
     if not enabled:z=x
     elif name=='fusion' and mode==0:z=(x*(256-weight)+y*weight+128)//256
     else:z=sum(((((x>>s)&255)*(256-weight)+((y>>s)&255)*weight+128)//256)<<s for s in [0,8,16])
     out.append(z)
   b.add(mode,w,h,p0,p1,a,out,paired,encoded=name=='background_model' and mode==3)
 invalid=2 if name in ['fusion','temporal_denoise'] else 4
 b.add(invalid,2,2,0,0,[],[],error=1)
 return b.done()
