"""Independent direct box-statistics and exhaustive patch-SSD reference tests."""
from pathlib import Path
import math,random,sys,tempfile,hashlib
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'integration'))
from tooling import evidence_dir,execute,write_json

def trunc(n,d):return (-1 if n<0 else 1)*(abs(n)//d)
def reference(a,g,w,h,p0,p1,guided):
 def get(v,x,y):return v[max(0,min(h-1,y))*w+max(0,min(w-1,x))]
 if guided:
  r=p0;n=(2*r+1)**2;eps=(p1+255)//256;aa=[];bb=[]
  for y in range(h):
   for x in range(w):
    v=[(get(g,x+dx,y+dy),get(a,x+dx,y+dy)*128) for dy in range(-r,r+1) for dx in range(-r,r+1)]
    si=sum(i for i,p in v);sp=sum(p for i,p in v)
    ac=trunc((n*sum(i*p for i,p in v)-si*sp)*65536,n*sum(i*i for i,p in v)-si*si+n*n*eps)
    aa.append(ac);bb.append(trunc(sp*65536-ac*si,n))
  out=[]
  for y in range(h):
   for x in range(w):
    sa=sum(get(aa,x+dx,y+dy) for dy in range(-r,r+1) for dx in range(-r,r+1))
    sb=sum(get(bb,x+dx,y+dy) for dy in range(-r,r+1) for dx in range(-r,r+1))
    q=max(0,min(32768,trunc(sa*g[y*w+x]+sb,n*65536)));out.append(min(255,(q+64)//128))
  return out
 pr=p0&255;sr=p0>>8;n=(2*pr+1)**2;out=[]
 for y in range(h):
  for x in range(w):
   weights=[]
   for dy in range(-sr,sr+1):
    for dx in range(-sr,sr+1):
     ssd=sum((get(a,x+px,y+py)-get(a,x+dx+px,y+dy+py))**2 for py in range(-pr,pr+1) for px in range(-pr,pr+1))
     index=min(255,ssd*1048576//(n*p1*p1));weight=int(65535*math.exp(-index/16)+0.5)
     weights.append((weight,get(a,x+dx,y+dy)))
   sw=sum(v for v,p in weights);out.append((sum(v*p for v,p in weights)+sw//2)//sw)
 return out

def fixtures(folder,bits,gray,guided):
 rng=random.Random(621);cmd=[];inputs=[];aux=[];outputs=[];changed=0
 def add(w,h,a,g,p0,p1,mode=0,error=0,bad=0,dims=None):
  nonlocal changed
  dw,dh=dims or (w,h);cmd.extend([mode,w,h,dw,dh,p0,p1,error,bad,len(a) if a is not None else 0])
  if a is None:return
  out=reference(a,g,w,h,p0,p1,guided);changed+=sum(x!=y for x,y in zip(a,out))
  inputs.extend(v|((1<<gray) if bad==3 and i==0 else 0) for i,v in enumerate(a));aux.extend(g)
  outputs.extend(v|(int(i==0)<<33)|(int(i%w==w-1)<<32) for i,v in enumerate(out))
 supported=gray<=bits<=32 and (gray==8 if guided else 1<=gray<=12)
 if supported:
  maximum=(1<<gray)-1
  configs=[(0,1),(1,256),(2,6400),(3,16776960)] if guided else [(0,256),(256,30*256),(257,40*256),(769,65535)]
  for w,h in [(1,1),(1,4),(5,1),(3,3),(5,4),(8,6)]:
   for pattern in range(3):
    a=[rng.randrange(maximum+1) for _ in range(w*h)];g=[rng.randrange(256) for _ in a]
    if pattern==0:a=[maximum]*(w*h);g=[0]*(w*h)
    if pattern==1:a=[maximum if i%2 else 0 for i in range(w*h)];g=[255-v*255//max(1,maximum) for v in a]
    for p0,p1 in configs:
     if not guided:p1=min(p1,(1<<(gray+8))-1)
     add(w,h,a,g,p0,p1)
  for bad in [1,2]+([3] if bits>gray else [])+([4,5] if guided else []):
   add(3,3,[rng.randrange(maximum+1) for _ in range(9)],[rng.randrange(256) for _ in range(9)],1 if guided else 257,min(6400,(1<<(gray+8))-1),error=2,bad=bad)
  for mode,w,h,dw,dh,p0,p1,error in [(1,2,2,2,2,0,256,1),(0,0,2,0,2,0,256,2),(0,9,2,9,2,0,256,2),(0,2,7,2,7,0,256,2),(0,2,2,3,2,0,256,2),(0,2,2,2,2,0,0,2),(0,2,2,2,2,4 if guided else 2,256,2),(0,2,2,2,2,0,16776961 if guided else 1<<(gray+8),2)]:add(w,h,None,None,p0,p1,mode,error,dims=(dw,dh))
 else:
  add(2,2,None,None,0,256,error=2);add(2,2,None,None,0,256,mode=1,error=1)
 for name,values in [('commands',cmd),('inputs',inputs),('auxiliary',aux),('expected',outputs)]:
  (folder/(name+'.hex')).write_text(''.join((f'{v:09x}\n' if name=='expected' else f'{v:08x}\n') for v in values))
 return {'commands':len(cmd)//10,'pixels':len(inputs),'changed_pixels':changed,'width':bits,'gray':gray,'reset_cases':3 if supported else 0}

def main():
 evidence=evidence_dir('guided_nlm_adapter');cases=[];all_hashes={}
 deps=[HERE.parent/'image/dehaze'/name for name in ['img_dh_guided_frame.v','img_dh_guided_refine.v']]
 for kind in ['guided_filter','nlm_denoise']:
  guided=kind=='guided_filter'
  sources=[HERE/f'rtl/cip_image_{kind}.v',HERE/f'sim/tb_cip_image_{kind}.v',HERE.parent/f'image/filters/rtl/img_filter_{"guided" if guided else "nlm"}.v']
  sources+=deps if guided else [HERE.parent/'image/filters/rtl/img_filter_nlm_serial_engine.v',HERE.parent/'image/filters/rtl/img_filter_exp_weight.v']
  hashes={str(p.relative_to(HERE.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+[Path(__file__)]}
  all_hashes.update(hashes)
  with tempfile.TemporaryDirectory(prefix='cip_'+kind) as temporary:
   for bits,gray in ([(8,8),(24,8),(32,8),(4,8),(24,12)] if guided else [(1,1),(8,8),(24,8),(32,12),(4,8),(24,13)]):
    label=f'{kind}_w{bits}_g{gray}';folder=Path(temporary)/label;folder.mkdir();counts=fixtures(folder,bits,gray,guided);binary=folder/'test.vvp';top='tb_cip_image_'+kind
    execute(['iverilog','-g2012','-s',top,f'-P{top}.DW={bits}',f'-P{top}.GB={gray}','-o',binary,*sources],HERE,evidence/f'{label}_compile.log')
    output=execute(['vvp',binary,f'+folder={folder}',f'+commands={counts["commands"]}',f'+pixels={counts["pixels"]}'],HERE,evidence/f'{label}_simulation.log',timeout=120)
    if kind.upper()+' PASS' not in output:raise RuntimeError('missing PASS')
    print(output.strip());cases.append({'kind':kind,**counts})
  if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p.relative_to(HERE.parent))] for p in sources+[Path(__file__)]):raise RuntimeError('source changed')
 write_json(evidence/'summary.json',{'status':'PASS','cases':cases,'source_sha256':all_hashes,'board':'not_run','synthesis':'not_run'})
 print('evidence='+str(evidence))
if __name__=='__main__':main()


