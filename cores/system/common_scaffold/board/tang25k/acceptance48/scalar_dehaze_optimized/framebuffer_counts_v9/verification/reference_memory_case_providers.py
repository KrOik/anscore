"""Framebuffer fixtures exercising actual persistent synchronous BRAM transactions."""
from pathlib import Path
import random
HERE=Path(__file__).resolve().parent;COMMON=HERE.parents[2];SV=COMMON/'signal_video'
CASE_NAMES=['framebuffer']
def describe(name):
 return {'module':'cip_image_framebuffer','data_w':24,'parameters':{'MAX_WIDTH':8,'MAX_HEIGHT':6},'sources':[SV/'rtl/cip_image_framebuffer.v',HERE/'rtl/acceptance48_bram_memory.v'],'case_id':int.from_bytes(b'FBUF','big'),'external_memory_model':True}
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
 b=Builder();rng=random.Random(27261);memory={}
 def add(mode,w,h,base,stride,a=None,error=0):
  image=[] if a is None else a
  if a is not None and not error:
   for i,v in enumerate(a):memory[base+i//w*stride+i%w*4]=v
  out=[memory[base+y*stride+x*4] for y in range(h) for x in range(w)] if mode in [0,2] and not error else []
  b.add(mode,w,h,0,0,image,out,error=error);b.commands[-1]|=base<<140|stride<<172
 for w,h in [(1,1),(1,6),(3,3),(5,4),(8,6)]:
  for mode in [0,1]:
   for pat in range(3):
    a=[rng.randrange(1<<24) for _ in range(w*h)] if pat==2 else [0 if pat==0 else 0xffffff]*(w*h)
    add(mode,w,h,256,w*4+8,a);add(2,w,h,256,w*4+8)
 add(1,3,2,1024,32,[rng.randrange(1<<24) for _ in range(6)])
 add(1,3,2,2048,16,[rng.randrange(1<<24) for _ in range(6)])
 add(2,3,2,1024,32);add(2,3,2,2048,16)
 add(1,1,1,4092,4,[0x123456],error=3);add(2,1,1,4092,4,error=3)
 add(0,2,2,256,16,[0x123456,0,0xffffff,0x50])
 add(3,2,2,256,16,error=1);add(0,2,2,257,16,error=2);add(0,2,2,256,4,error=2)
 add(2,3,2,1024,32)
 return b.done()
