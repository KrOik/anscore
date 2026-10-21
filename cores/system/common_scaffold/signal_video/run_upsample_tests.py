"""Independent packed-lane Q8 asymmetric-grid bilinear reference."""
from pathlib import Path
import random,sys,tempfile,hashlib
HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'integration'))
from tooling import evidence_dir,execute,write_json

def reference(image,w,h,scale,bits):
 out=[];dw=w*scale;dh=h*scale
 for y in range(dh):
  qy=y*256//scale;y0=qy//256;y1=min(h-1,y0+1);fy=qy%256
  for x in range(dw):
   qx=x*256//scale;x0=qx//256;x1=min(w-1,x0+1);fx=qx%256;pixel=0
   for lane in range(bits//8):
    a=(image[y0*w+x0]>>(8*lane))&255;b=(image[y0*w+x1]>>(8*lane))&255
    c=(image[y1*w+x0]>>(8*lane))&255;d=(image[y1*w+x1]>>(8*lane))&255
    value=(a*(256-fx)*(256-fy)+b*fx*(256-fy)+c*(256-fx)*fy+d*fx*fy+32768)//65536
    pixel|=value<<(8*lane)
   out.append(pixel|(int(x==0 and y==0)<<33)|(int(x==dw-1)<<32))
 return out

def fixtures(folder,bits):
 rng=random.Random(931);commands=[];inputs=[];outputs=[]
 def add(w,h,scale,image=None,error=0,bad=0,mode=0,dims=None,p1=0):
  dw,dh=dims or (w*scale,h*scale)
  expected=reference(image,w,h,scale,bits) if image is not None and bad==0 else []
  commands.extend([mode,w,h,dw,dh,scale,p1,error,bad,len(image or []),len(expected)])
  inputs.extend(image or []);outputs.extend(expected)
 if bits in (8,16,24,32):
  for w,h in [(1,1),(1,4),(5,1),(2,2),(5,3),(8,6)]:
   for scale in [1,2,3,7,15]:
    if scale>=7 and w*h>4:continue
    for pattern in range(3):
     mask=(1<<bits)-1
     image=[rng.getrandbits(bits) if pattern==0 else mask if pattern==1 else (i*0x19375b)&mask for i in range(w*h)]
     add(w,h,scale,image)
  for bad in [4,5,6]:add(2,2,2,error=2,bad=bad)
  for bad in [1,2]:add(3,2,2,[rng.getrandbits(bits) for _ in range(6)],error=2,bad=bad)
  for w,h,scale,dims,p1,mode,error in [(0,2,2,None,0,0,2),(9,2,2,None,0,0,2),(2,7,2,None,0,0,2),(2,2,0,None,0,0,2),(2,2,16,None,0,0,2),(2,2,2,(3,4),0,0,2),(2,2,2,None,1,0,2),(2,2,2,None,0,1,1),(65535,2,15,(65521,30),0,0,2)]:add(w,h,scale,error=error,dims=dims,p1=p1,mode=mode)
 else:
  add(2,2,2,error=2);add(2,2,2,error=1,mode=1)
 for name,values in [('commands',commands),('inputs',inputs),('auxiliary',inputs),('expected',outputs)]:
  (folder/f'{name}.hex').write_text(''.join((f'{v:09x}\n' if name=='expected' else f'{v:08x}\n') for v in values))
 return {'commands':len(commands)//11,'pixels':len(inputs),'outputs':len(outputs),'width':bits,'reset_cases':3 if bits in (8,16,24,32) else 0}

def main():
 evidence=evidence_dir('upsample_adapter');cases=[]
 geo=HERE.parent/'image/geometry/rtl'
 sources=[HERE/'rtl/cip_image_upsample.v',HERE/'sim/tb_cip_image_upsample.v']+[geo/name for name in ['img_geo_raster_coords.v','img_geo_integer_upsample.v','img_geo_frame_buffered.v','img_geo_frame_writer.v','img_geo_frame_transform.v','img_geo_inverse_map.v','img_geo_frame_sampler.v']]
 tracked=[*sources,Path(__file__)];hashes={str(p.relative_to(HERE.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
 with tempfile.TemporaryDirectory(prefix='cip_upsample_') as temporary:
  for bits in [8,16,24,32,7,12]:
   label=f'w{bits}';folder=Path(temporary)/label;folder.mkdir();counts=fixtures(folder,bits);binary=folder/'test.vvp'
   execute(['iverilog','-g2012','-s','tb_cip_image_upsample',f'-Ptb_cip_image_upsample.DW={bits}','-o',binary,*sources],HERE,evidence/f'{label}_compile.log')
   output=execute(['vvp',binary,f'+folder={folder}',f'+commands={counts["commands"]}',f'+pixels={counts["pixels"]}',f'+outputs={counts["outputs"]}'],HERE,evidence/f'{label}_simulation.log',timeout=120)
   if f'UPSAMPLE PASS width={bits}' not in output:raise RuntimeError('missing PASS')
   print(output.strip());cases.append(counts)
 if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p.relative_to(HERE.parent))] for p in tracked):raise RuntimeError('source changed')
 write_json(evidence/'summary.json',{'status':'PASS','cases':cases,'source_sha256':hashes,'board':'not_run','synthesis':'not_run'})
 print(f'evidence={evidence}')
if __name__=='__main__':main()
