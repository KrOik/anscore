"""Independent rational Catmull-Rom bicubic scaling regression."""
from pathlib import Path
import sys
import random
import tempfile
import hashlib

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'integration'))
from tooling import evidence_dir, execute, write_json


def weights(t):
    # Independent rational polynomial evaluation, floor to Q16.
    from fractions import Fraction
    x=Fraction(t,256)
    v=[-x/2+x*x-x*x*x/2,1-Fraction(5,2)*x*x+Fraction(3,2)*x*x*x,x/2+2*x*x-Fraction(3,2)*x*x*x]
    out=[int(a*65536//1) for a in v]
    return out+[65536-sum(out)]

def reference(image,w,h,dw,dh,pw,lanes,mode=2):
    out=[];mask=(1<<pw)-1
    for y in range(dh):
        iy,fy=divmod(y*h*256//dh,256);wy=weights(fy)
        for x in range(dw):
            ix,fx=divmod(x*w*256//dw,256);wx=weights(fx);value=0
            for lane in range(lanes):
                total=sum(((image[min(h-1,max(0,iy+j-1))*w+min(w-1,max(0,ix+i-1))]>>(lane*pw))&mask)*wx[i]*wy[j] for j in range(4) for i in range(4))
                if mode==0:
                    total=((image[min(h-1,iy+(fy>=128))*w+min(w-1,ix+(fx>=128))]>>(lane*pw))&mask)*(1<<32)
                elif mode==1:
                    total=sum(((image[min(h-1,iy+j)*w+min(w-1,ix+i)]>>(lane*pw))&mask)*([256-fx,fx][i])*([256-fy,fy][j]) for j in range(2) for i in range(2))*(1<<16)
                value|=min(mask,max(0,(total+(1<<31))//(1<<32)))<<(lane*pw)
            out.append(value|(int(x==0 and y==0)<<33)|(int(x==dw-1)<<32))
    return out

def fixtures(folder,bits,pw,public=0):
    rng=random.Random(91723);commands=[];inputs=[];outputs=[]
    supported=1<=pw<=16 and pw<=bits<=32 and bits%pw==0
    def add(w,h,dw,dh,image=None,error=0,bad=0,mode=2):
        expected=reference(image,w,h,dw,dh,pw,bits//pw,mode) if image is not None and not bad else []
        commands.extend([mode,w,h,dw,dh,0,0,error,bad,len(image or []),len(expected)])
        inputs.extend(image or []);outputs.extend(expected)
    if supported:
        shapes=[(1,1,1,1),(1,6,3,9),(8,1,13,4),(8,6,8,6),(7,5,11,9),(8,6,3,2),(2,2,17,13),(8,6,1,1)]
        for w,h,dw,dh in shapes:
            for pattern in range(6):
                image=[rng.randrange(1<<bits) if pattern==0 else (0 if pattern==1 else ((1<<bits)-1 if pattern==2 else (((1<<bits)-1) if (i%w+i//w)%2 else 0) if pattern==3 else (i*1234567)&((1<<bits)-1) if pattern==4 else (((1<<bits)-1) if i==w*h//2 else 0))) for i in range(w*h)]
                add(w,h,dw,dh,image)
                if public:
                    add(w,h,dw,dh,image,mode=0)
                    add(w,h,dw,dh,image,mode=1)
        for shape in [(0,2,2,2),(9,2,2,2),(2,7,2,2),(2,2,0,2),(2,2,2,0)]:add(*shape,error=2)
        for bad in (1,2):add(4,3,5,4,[0]*(1 if bad==1 else 12),error=2,bad=bad)
        add(2,2,3,3,[0,1,2,3])
    else:add(2,2,2,2,error=2)
    for name,values in [('commands',commands),('inputs',inputs),('auxiliary',[0]*len(inputs)),('expected',outputs)]:
        (folder/f'{name}.hex').write_text(''.join(format(v,'09x' if name=='expected' else '08x')+'\n' for v in values))
    return {'commands':len(commands)//11,'inputs':len(inputs),'outputs':len(outputs),'reset_cases':3 if supported else 0}

def main():
    evidence=evidence_dir('bicubic_adapter')
    sources=[HERE/'rtl/cip_image_bicubic_frame.v',HERE/'rtl/cip_image_scaler.v']
    sources += [HERE.parents[2]/line.strip() for line in (HERE.parent/'image/rtl_sources.f').read_text().splitlines() if line.strip() and not line.startswith('#')]
    tracked=[*sources,HERE/'sim/tb_cip_image_bicubic_frame.v',Path(__file__)]
    hashes={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    results=[]
    with tempfile.TemporaryDirectory(prefix='cip_bicubic_') as temporary:
        for public,bits,pw in [(p,b,w) for p in (0,1) for b,w in [(1,1),(8,8),(12,12),(24,8),(32,16),(10,8),(24,17)]]:
            label=f'public{public}_dw{bits}_pw{pw}'
            folder=Path(temporary)/label;folder.mkdir()
            counts=fixtures(folder,bits,pw,public)
            binary=folder/'sim.vvp'
            execute(['iverilog','-g2012',*(['-DBICUBIC_PUBLIC'] if public else []),'-s','tb_cip_image_bicubic_frame',f'-Ptb_cip_image_bicubic_frame.DW={bits}',f'-Ptb_cip_image_bicubic_frame.PW={pw}','-o',binary,*sources,HERE/'sim/tb_cip_image_bicubic_frame.v'],HERE,evidence/f'{label}_compile.log')
            output=execute(['vvp',binary,f'+folder={folder}',f'+commands={counts["commands"]}',f'+pixels={counts["inputs"]}',f'+outputs={counts["outputs"]}'],HERE,evidence/f'{label}_simulation.log',timeout=1200)
            marker=f'BICUBIC PASS width={bits} pixel={pw} commands={counts["commands"]} pixels={counts["outputs"]}'
            if marker not in output:raise RuntimeError('Missing scaler PASS marker')
            print(output.strip());results.append({'public':public,'data_w':bits,'pixel_w':pw,**counts})
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p)] for p in tracked):raise RuntimeError('Source changed during regression')
    write_json(evidence/'summary.json',{'status':'PASS','cases':results,'source_sha256':hashes,'synthesis':'not_run','board':'not_run'})
    print(f'evidence={evidence}')


if __name__=='__main__':main()

