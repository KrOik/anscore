"""Independent programmable four-convolution/PixelShuffle2 fixed-point oracle."""
from pathlib import Path
import random,tempfile,sys,hashlib
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'integration'))
from tooling import evidence_dir,execute,write_json

def layout(f):
 layers=[];offset=0
 for nin,nout,k in [(1,f,5),(f,f,3),(f,f,3),(f,4,3)]:
  layers.append((offset,offset+nin*nout*k*k,nin,nout,k));offset+=nin*nout*k*k+nout
 return layers,offset

def infer(image,w,h,model,f):
 data=[[[image[y*w+x]] for x in range(w)] for y in range(h)]
 for wi,bi,nin,nout,k in layout(f)[0]:
  result=[]
  for y in range(h):
   row=[]
   for x in range(w):
    pixel=[]
    for oc in range(nout):
     total=model[bi+oc]
     for ic in range(nin):
      for ky in range(k):
       for kx in range(k):
        xx=x+kx-k//2;yy=y+ky-k//2
        if 0<=xx<w and 0<=yy<h:total+=data[yy][xx][ic]*model[wi+((oc*nin+ic)*k+ky)*k+kx]
     maximum=255 if nout==4 and bi==layout(f)[0][-1][1] else 65535
     pixel.append(max(0,min(maximum,(total+128)//256)))
    row.append(pixel)
   result.append(row)
  data=result
 return [data[y//2][x//2][(y%2)*2+x%2] for y in range(h*2) for x in range(w*2)]

def model_for(f,kind,rng):
 layers,n=layout(f);m=[0]*n
 for li,(wi,bi,nin,nout,k) in enumerate(layers):
  for oc in range(nout):
   if kind==0:m[wi+(oc*nin*k+k//2)*k+k//2]=256
   else:
    for j in range(nin*k*k):m[wi+oc*nin*k*k+j]=rng.choice([-32768,32767]) if kind==3 else rng.randint(-80,96)
    m[bi+oc]=rng.randint(-768,3072)
  if kind==2:
   for oc in range(nout):m[bi+oc]=2147483647 if oc%2==0 else -2147483648
 return m

def fixtures(folder,dw,f):
 rng=random.Random(583+f);commands=[];inputs=[];outputs=[];weights=[];addresses=[];model=None;changed=0
 def add(mode,w=0,h=0,error=0,bad=0,image=None,loaded=None,invalid=0,dims=None):
  nonlocal model,changed
  cs=[];ad=[];out=[]
  if loaded is not None:
   ad=list(range(len(loaded)));rng.shuffle(ad);cs=[loaded[i]&0xffffffff for i in ad]
   if invalid==1:ad[-1]=ad[0]
   if invalid==2:ad[-1]=65535
   if invalid==3:
    j=ad.index(0);cs[j]=0x00008000
   if not invalid:model=loaded
  if image is not None and error==0:
   out=infer(image,w,h,model,f);changed+=sum(v!=image[(i//(w*2)//2)*w+(i%(w*2)//2)] for i,v in enumerate(out))
  ww,hh=dims or (2*w,2*h)
  commands.extend([mode,w,h,ww,hh,error,bad,len(image) if image is not None else 0,len(out),len(cs)])
  if image is not None:inputs.extend(v|((256 if bad==3 and i==0 else 0)) for i,v in enumerate(image))
  outputs.extend(v|(int(i==0)<<33)|(int(i%(2*w)==2*w-1)<<32) for i,v in enumerate(out));weights.extend(cs);addresses.extend(ad)
 supported=8<=dw<=32 and 1<=f<=16
 if supported:
  add(1,2,2,error=2);add(2,error=1)
  for kind in range(4):
   m=model_for(f,kind,rng);add(0,loaded=m)
   for w,h in [(1,1),(1,4),(5,1),(3,3),(5,4),(8,6)]:
    image=[rng.randrange(256) for _ in range(w*h)]
    add(1,w,h,image=image)
   for invalid in [1,2,3]:
    add(0,loaded=model_for(f,1,rng),invalid=invalid,error=2)
    add(1,3,2,image=[rng.randrange(256) for _ in range(6)])
  for bad in [1,2]+([3] if dw>8 else []):add(1,3,2,image=[rng.randrange(256) for _ in range(6)],bad=bad,error=2)
  add(0,1,0,error=2);add(0,error=2,bad=7)
  for w,h,dims in [(0,2,(0,4)),(9,2,(18,4)),(2,7,(4,14)),(2,2,(5,4))]:add(1,w,h,error=2,dims=dims)
  add(1,2,2,error=2,bad=7)
 else:add(0,error=2);add(1,2,2,error=2);add(2,error=1)
 for name,values in [('commands',commands),('inputs',inputs),('weights',weights),('addresses',addresses),('expected',outputs)]:
  (folder/(name+'.hex')).write_text(''.join((f'{v:09x}\n' if name=='expected' else f'{v:04x}\n' if name=='addresses' else f'{v:08x}\n') for v in values))
 return {'commands':len(commands)//10,'inputs':len(inputs),'outputs':len(outputs),'weights':len(weights),'width':dw,'features':f,'changed_pixels':changed,'reset_cases':4 if supported else 0}

def main():
 evidence=evidence_dir('super_resolution_adapter');cases=[]
 sources=[HERE/'rtl/cip_image_super_resolution.v',HERE/'sim/tb_cip_image_super_resolution.v'];tracked=[*sources,Path(__file__)]
 hashes={str(p.relative_to(HERE.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
 with tempfile.TemporaryDirectory(prefix='cip_superres_') as tmp:
  for dw,f in [(8,1),(24,2),(32,4),(24,16),(4,1)]:
   name=f'w{dw}_f{f}';folder=Path(tmp)/name;folder.mkdir();case=fixtures(folder,dw,f);binary=folder/'test.vvp';top='tb_cip_image_super_resolution'
   execute(['iverilog','-g2012','-s',top,f'-P{top}.DW={dw}',f'-P{top}.F={f}','-o',binary,*sources],HERE,evidence/(name+'_compile.log'))
   output=execute(['vvp',binary,f'+folder={folder}',*[f'+{k}={case[k]}' for k in ['commands','inputs','outputs','weights']]],HERE,evidence/(name+'_simulation.log'),timeout=600)
   if 'SUPER_RESOLUTION PASS' not in output:raise RuntimeError('missing PASS')
   print(output.strip());cases.append(case)
 if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p.relative_to(HERE.parent))] for p in tracked):raise RuntimeError('source changed during test')
 write_json(evidence/'summary.json',{'status':'PASS','cases':cases,'source_sha256':hashes,'synthesis':'not_run','board':'not_run','quality':'programmable inference only; no pretrained model or quality claim'})
 print('evidence='+str(evidence))
if __name__=='__main__':main()
