"""Independent integer DCP, spatial dark channel, scalar transmission/recovery oracle.
ABI: same-size RGB888 (dark/recover/full); transmission input scalar8/output Q1.15.
Dark: mode0,p0 radius,p1=0. Transmission: p0={t0,omega},p1 scalar A (1..255).
Recover: p0={t0,0},p1 RGB A, atomic auxiliary Q1.15 transmission per pixel.
Full: p0={t0,omega},p1={2'b0,guided_radius[2:0],dark_radius[2:0],A[23:0]},
 mode0 manual,1 auto,2 manual+guided,3 auto+guided; compile-time permille1 epsilon100.
Inactive bases/strides must zero. Error1 mode,2 config/framing/range,3 internal.
"""
from pathlib import Path
import random,sys,tempfile,hashlib
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'integration'))
from tooling import evidence_dir,execute,write_json

def trunc(n,d):return abs(n)//d*(-1 if n<0 else 1)
def channels(p):return [(p>>s)&255 for s in (16,8,0)]
def pack(c):return (c[0]<<16)|(c[1]<<8)|c[2]
def box(values,w,h,r,fn):
 return [fn([values[min(h-1,max(0,y+dy))*w+min(w-1,max(0,x+dx))] for dy in range(-r,r+1) for dx in range(-r,r+1)]) for y in range(h) for x in range(w)]
def guided(rgb,p,w,h,r,eps=100):
 guide=[(77*c[0]+150*c[1]+29*c[2]+128)>>8 for c in map(channels,rgb)]
 n=(2*r+1)**2
 si=box(guide,w,h,r,sum);sp=box(p,w,h,r,sum);sii=box([i*i for i in guide],w,h,r,sum);sip=box([i*t for i,t in zip(guide,p)],w,h,r,sum)
 a=[trunc((n*ip-i*t)<<16,n*ii-i*i+n*n*eps) for ip,i,t,ii in zip(sip,si,sp,sii)]
 b=[trunc((t<<16)-aa*i,n) for t,aa,i in zip(sp,a,si)]
 sa=box(a,w,h,r,sum);sb=box(b,w,h,r,sum)
 return [max(0,min(32768,trunc(i*aa+bb,n<<16))) for i,aa,bb in zip(guide,sa,sb)]
def restore(rgb,a,t,t0):
 return pack([max(0,min(255,trunc((i-aa)*32768,max(t,t0))+aa)) for i,aa in zip(channels(rgb),channels(a))])
def oracle(kind,image,aux,w,h,p0,p1,mode):
 if kind==0:return box([min(channels(p)) for p in image],w,h,p0,min)
 if kind==1:return [max(0,32768-((p0&65535)*d+(p1>>1))//p1) for d in image]
 if kind==2:return [restore(p,p1,min(t,32768),p0>>16) for p,t in zip(image,aux)]
 radius=(p1>>24)&7;a=p1&0xffffff;omega=p0&65535;t0=p0>>16
 dark=box([min(channels(p)) for p in image],w,h,radius,min)
 if mode&1:
  k=(len(image)+999)//1000;threshold=sorted(dark,reverse=True)[k-1]
  a=max(((sum(channels(p)),i,p) for i,(p,d) in enumerate(zip(image,dark)) if d>=threshold))[2]
 a=pack([max(1,c) for c in channels(a)])
 norm=[min((c*32768+aa//2)//aa for c,aa in zip(channels(p),channels(a))) for p in image]
 norm=box(norm,w,h,radius,min)
 t=[max(0,32768-((v*omega+16384)>>15)) for v in norm]
 if mode&2:t=guided(image,t,w,h,(p1>>27)&7)
 return [restore(p,a,tt,t0) for p,tt in zip(image,t)]

def fixtures(folder,kind,bits):
 rng=random.Random(239+kind);cmd=[];inp=[];aux=[];out=[]
 def add(w,h,image,p0,p1,mode=0,error=0,bad=0,dims=None,ts=None):
  dw,dh=dims or (w,h);n=len(image) if image is not None else 0
  cmd.extend([mode,w,h,dw,dh,p0,p1,error,bad,n])
  if image is not None:
   ts=ts or [rng.randrange(32769) for _ in image]
   numeric=oracle(kind,image,ts,w,h,p0,p1,mode)
   inp.extend(image);aux.extend(ts)
   out.extend(v|(int(i==0)<<33)|(int(i%w==w-1)<<32) for i,v in enumerate(numeric))
 supported=bits>=(16 if kind==1 else 24) and bits<=32
 if supported:
  for w,h in ([(1,1),(1,3),(4,1),(3,2),(3,3)] if kind==3 else [(1,1),(1,6),(8,1),(3,3),(5,4),(8,6)]):
   for pattern in range(4):
    image=[rng.randrange(256 if kind==1 else 1<<24) for _ in range(w*h)]
    if pattern==0:image=[0]*(w*h)
    if pattern==1:image=[255 if kind==1 else 0xffffff]*(w*h)
    if kind==0:
     for r in [0,1,3]:add(w,h,image,r,0)
    elif kind==1:
     for omega,a in [(0,1),(32768,255),(30000,97)]:add(w,h,image,(8192<<16)|omega,a)
    elif kind==2:
     for t0,a in [(1,0),(8192,0x5070a0),(32768,0xffffff)]:add(w,h,image,t0<<16,a,ts=[rng.choice([0,1,32768,8192]) for _ in image])
    else:
     mode=pattern;add(w,h,image,(8192<<16)|30000,0xc0d0e0|(int(pattern!=0)<<24)|(int(pattern==3)<<27),mode)
  p0=1 if kind==0 else (8192<<16)|(0 if kind==2 else 30000);p1=0 if kind==0 else (180 if kind==1 else 0xa0b0c0)
  for bad in ([1,2,3,4] if kind==2 else [1,2]):add(3,2,[rng.randrange(256 if kind==1 else 1<<24) for _ in range(6)],p0,p1,error=2,bad=bad)
  if bits>(8 if kind==1 else 24):add(2,2,[17,33,51,77] if kind==1 else [0x102030]*4,p0,p1,error=2,bad=5)
  if kind==2:add(2,2,[0x123456,0,0xffffff,0x234567],p0,p1,error=2,ts=[40000,32769,65535,65536])
  add(2,2,None,p0,p1,error=2,bad=7)
  if kind==0:
   for q0,q1 in [(4,0),(1,1)]:add(2,2,None,q0,q1,error=2)
  elif kind==1:
   for q0,q1 in [(p0,0),(p0,256),(p0,0x100001),((8192<<16)|32769,100),((32769<<16)|100,100)]:add(2,2,None,q0,q1,error=2)
  elif kind==2:
   for q0,q1 in [(p0|1,p1),(32769<<16,p1),(p0,1<<24)]:add(2,2,None,q0,q1,error=2)
  else:
   for q0,q1 in [((8192<<16)|32769,p1),((32769<<16)|100,p1),(p0,p1|(1<<30)),(p0,p1|(4<<24))]:add(2,2,None,q0,q1,error=2)
   add(2,2,None,p0,p1|(4<<27),mode=2,error=2)
  if kind==3:
   add(1,1,[0x345678],p0,0xc0d0e0|(3<<24)|(3<<27),mode=3)
   for omega,t0,a in [(0,32768,0),(32768,1,0),(32768,8192,0xff0012)]:add(2,2,[0x102030,0x8090a0,0,0xffffff],(t0<<16)|omega,a)
  for w,h,dw,dh in [(0,2,0,2),(9,2,9,2),(2,7,2,7),(2,2,3,2)]:add(w,h,None,p0,p1,error=2,dims=(dw,dh))
  add(2,2,None,p0,p1,mode=15,error=1)
  add(2,2,None,(4 if kind==0 else 0),p1,error=2)
 else:
  add(2,2,None,0,0,error=2);add(2,2,None,0,0,mode=15,error=1)
 for name,vals in [('commands',cmd),('inputs',inp),('auxiliary',aux),('expected',out)]:
  (folder/(name+'.hex')).write_text(''.join((f'{v:09x}\n' if name=='expected' else f'{v:08x}\n') for v in vals))
 return {'kind':kind,'width':bits,'commands':len(cmd)//10,'pixels':len(inp),'reset_cases':3 if supported else 0,'scope':'functional' if supported else 'rejection_only'}

def main():
 evidence=evidence_dir('dehaze_adapters');cases=[]
 names=['dark_channel','transmission','recover','dehaze']
 sources=[*(HERE/'rtl'/('cip_image_'+n+'.v') for n in names),HERE/'rtl/cip_image_dehaze_scalar_frame.v',HERE/'sim/tb_cip_image_dehaze_adapters.v',*sorted((HERE.parent/'image/dehaze').glob('*.v'))]
 tracked=[*sources,Path(__file__)];hashes={str(p.relative_to(HERE.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
 with tempfile.TemporaryDirectory(prefix='cip_dehaze_') as temporary:
  for kind,name in enumerate(names):
   for bits in ([16,24,32,8] if kind==1 else [24,32,16]):
    label=f'{name}_w{bits}';folder=Path(temporary)/label;folder.mkdir();counts=fixtures(folder,kind,bits);binary=folder/'test.vvp'
    execute(['iverilog','-g2012','-s','tb_cip_image_dehaze_adapters',f'-DCORE=cip_image_{name}',f'-Ptb_cip_image_dehaze_adapters.DW={bits}',f'-Ptb_cip_image_dehaze_adapters.KIND={kind}','-o',binary,*sources],HERE,evidence/(label+'_compile.log'))
    output=execute(['vvp',binary,f'+folder={folder}',f'+commands={counts["commands"]}',f'+pixels={counts["pixels"]}'],HERE,evidence/(label+'_simulation.log'))
    if 'DEHAZE_ADAPTER PASS' not in output:raise RuntimeError('missing PASS')
    print(output.strip(),flush=True);cases.append(counts)
 if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p.relative_to(HERE.parent))] for p in tracked):raise RuntimeError('source changed')
 write_json(evidence/'summary.json',{'status':'PASS','cases':cases,'source_sha256':hashes,'synthesis':'not_run','board':'not_run'})
 print(f'evidence={evidence}')
if __name__=='__main__':main()
