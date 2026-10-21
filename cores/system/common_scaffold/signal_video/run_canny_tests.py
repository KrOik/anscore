"""Independent 2-D Gaussian/Sobel/NMS and queue-based Canny connectivity oracle."""
from pathlib import Path
from collections import deque
import random
import sys
import tempfile
import hashlib

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'integration'))
from tooling import evidence_dir,execute,write_json

def canny(image,w,h,low,high,maximum):
    def sample(values,x,y):return values[min(h-1,max(0,y))*w+min(w-1,max(0,x))]
    blur=[]
    for y in range(h):
        for x in range(w):
            total=sum(sample(image,x+dx,y+dy)*wx*wy for dy,wy in [(-1,1),(0,2),(1,1)] for dx,wx in [(-1,1),(0,2),(1,1)])
            blur.append((total+8)//16)
    magnitudes=[];directions=[]
    for y in range(h):
        for x in range(w):
            gx=sum((sample(blur,x+1,y+dy)-sample(blur,x-1,y+dy))*weight for dy,weight in [(-1,1),(0,2),(1,1)])
            gy=sum((sample(blur,x+dx,y+1)-sample(blur,x+dx,y-1))*weight for dx,weight in [(-1,1),(0,2),(1,1)])
            ax,ay=abs(gx),abs(gy)
            direction=(1,0) if ay*256<=ax*106 else (0,1) if ax*256<=ay*106 else (1,1) if (gx<0)==(gy<0) else (1,-1)
            magnitudes.append(ax+ay);directions.append(direction)
    labels=[];queue=deque();distance={}
    for i,mag in enumerate(magnitudes):
        x,y=i%w,i//w;dx,dy=directions[i]
        kept=mag>0 and mag>=sample(magnitudes,x-dx,y-dy) and mag>=sample(magnitudes,x+dx,y+dy)
        label=2 if kept and mag>=high else 1 if kept and mag>=low else 0
        labels.append(label)
        if label==2:queue.append(i);distance[i]=0
    promoted=0
    while queue:
        i=queue.popleft();x,y=i%w,i//w
        for yy in range(max(0,y-1),min(h,y+2)):
            for xx in range(max(0,x-1),min(w,x+2)):
                j=yy*w+xx
                if labels[j]==1:
                    labels[j]=2;promoted+=1;distance[j]=distance[i]+1;queue.append(j)
    return [maximum if label==2 else 0 for label in labels],promoted,max(distance.values(),default=0)

def fixtures(folder,bits,gray):
    rng=random.Random(7193);commands=[];inputs=[];outputs=[];stats={'promoted':0,'max_chain':0}
    maximum=(1<<gray)-1
    def add(w,h,image,low,high,mode=0,error=0,bad=0,dims=None):
        dw,dh=dims or (w,h);numeric=[]
        if image is not None:
            numeric,promoted,chain=canny(image,w,h,low,high,maximum)
            stats['promoted']+=promoted;stats['max_chain']=max(stats['max_chain'],chain)
        commands.extend([mode,w,h,dw,dh,low,high,error,bad,len(image) if image is not None else 0])
        if image is not None:
            inputs.extend((v | ((1<<gray) if bad==3 and i==0 else 0)) for i,v in enumerate(image))
            outputs.extend(v | (int(i==0)<<33) | (int(i%w==w-1)<<32) for i,v in enumerate(numeric))
    supported=1<=gray<=12 and gray<=bits<=32
    if supported:
        for w,h in [(1,1),(1,6),(8,1),(3,3),(5,4),(8,6)]:
            for pattern in range(6):
                image=[rng.randrange(maximum+1) for _ in range(w*h)]
                if pattern==0:image=[0]*(w*h)
                if pattern==1:image=[maximum]*(w*h)
                if pattern==2:image=[maximum if i%w>=w//2 else 0 for i in range(w*h)]
                if pattern==3:image=[maximum if (i%w+i//w)%2 else 0 for i in range(w*h)]
                if pattern==4:image=[maximum if i==w*(h//2)+w//2 else 0 for i in range(w*h)]
                for low,high in [(0,0),(maximum//3,maximum),(maximum,maximum*4)]:add(w,h,image,low,high)
        for bad in [1,2]+([3] if bits>gray else []):add(5,4,[rng.randrange(maximum+1) for _ in range(20)],0,maximum,error=2,bad=bad)
        # Find a reproducible frame requiring several weak-link promotions, using BFS rather than RTL raster sweeps.
        for _ in range(200):
            image=[rng.randrange(maximum+1) for _ in range(48)]
            _,promoted,chain=canny(image,8,6,0,maximum,maximum)
            if chain>=3:
                add(8,6,image,0,maximum);break
        if gray>=8 and stats['max_chain']<3:raise RuntimeError('fixture lacks long hysteresis chain')
        for mode,w,h,dw,dh,low,high,error in [(1,2,2,2,2,0,1,1),(0,0,2,0,2,0,1,2),
            (0,9,2,9,2,0,1,2),(0,2,7,2,7,0,1,2),(0,2,2,3,2,0,1,2),(0,2,2,2,2,2,1,2),
            (0,2,2,2,2,0,1<<(gray+4),2)]:add(w,h,None,low,high,mode,error,dims=(dw,dh))
    else:
        add(2,2,None,0,1,error=2);add(2,2,None,0,1,mode=1,error=1)
    for name,values in [('commands',commands),('inputs',inputs),('auxiliary',inputs),('expected',outputs)]:
        (folder/f'{name}.hex').write_text(''.join((f'{v:09x}\n' if name=='expected' else f'{v:08x}\n') for v in values))
    return {'commands':len(commands)//10,'pixels':len(inputs),'width':bits,'gray':gray,**stats,'scope':'functional' if supported else 'rejection_only'}

def main():
    evidence=evidence_dir('canny_adapter');cases=[]
    sources=[HERE/'rtl/cip_image_canny.v',HERE/'sim/tb_cip_image_canny.v',HERE.parent/'image/filters/rtl/img_edge_canny.v']
    tracked=[*sources,Path(__file__)]
    hashes={str(p.relative_to(HERE.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    with tempfile.TemporaryDirectory(prefix='cip_canny_') as temporary:
        for bits,gray in [(1,1),(8,8),(12,12),(24,8),(32,12),(4,8),(24,13)]:
            label=f'w{bits}_g{gray}';folder=Path(temporary)/label;folder.mkdir();counts=fixtures(folder,bits,gray);binary=folder/'test.vvp'
            execute(['iverilog','-g2012','-s','tb_cip_image_canny',f'-Ptb_cip_image_canny.DW={bits}',
                f'-Ptb_cip_image_canny.GB={gray}','-o',binary,*sources],HERE,evidence/f'{label}_compile.log')
            output=execute(['vvp',binary,f'+folder={folder}',f'+commands={counts["commands"]}',f'+pixels={counts["pixels"]}'],HERE,evidence/f'{label}_simulation.log')
            if f'CANNY PASS width={bits}' not in output:raise RuntimeError('missing PASS')
            print(output.strip());cases.append(counts)
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p.relative_to(HERE.parent))] for p in tracked):raise RuntimeError('source changed')
    write_json(evidence/'summary.json',{'status':'PASS','cases':cases,'source_sha256':hashes,'board':'not_run'})
    print(f'evidence={evidence}')

if __name__=='__main__':main()
