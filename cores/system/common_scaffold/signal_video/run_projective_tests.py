"""Independent signed rational inverse-matrix transform regression."""
from pathlib import Path
import sys
import random
import tempfile
import hashlib

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'integration'))
from tooling import evidence_dir, execute, write_json


def reference(image,w,h,dw,dh,mode,pw,lanes,m,pers):
    result=[];error=0
    def trunc(a,b):return (abs(a)//abs(b))*(-1 if (a<0)!=(b<0) else 1)
    for y in range(dh):
        for x in range(dw):
            nx=m[0]*x+m[1]*y+m[2];ny=m[3]*x+m[4]*y+m[5]
            den=m[6]*x+m[7]*y+m[8]
            if pers and den==0:qx=qy=-1;error=2
            else:qx,qy=(trunc(nx*256,den),trunc(ny*256,den)) if pers else (nx//256,ny//256)
            value=0
            if 0<=qx<w*256 and 0<=qy<h*256:
                ix,fx=divmod(qx,256);iy,fy=divmod(qy,256)
                if mode==0:value=image[min(h-1,iy+(fy>=128))*w+min(w-1,ix+(fx>=128))]
                else:
                    for lane in range(lanes):
                        mask=(1<<pw)-1
                        def sample(xx,yy):return (image[min(h-1,yy)*w+min(w-1,xx)]>>(lane*pw))&mask
                        total=sample(ix,iy)*(256-fx)*(256-fy)+sample(ix+1,iy)*fx*(256-fy)+sample(ix,iy+1)*(256-fx)*fy+sample(ix+1,iy+1)*fx*fy
                        value|=((total+32768)//65536)<<(lane*pw)
            result.append(value|(int(x==0 and y==0)<<33)|(int(x==dw-1)<<32))
    return result,error


def fixtures(folder,bits,pw,pers):
    rng=random.Random(87013);commands=[];inputs=[];outputs=[];matrices=[]
    supported=1<=pw<=16 and pw<=bits<=32 and bits%pw==0
    identity=[65536,0,0,0,65536,0,0,0,65536]
    def add(w,h,dw,dh,mode,m=None,image=None,error=0,bad=0,p0=0,p1=0):
        m=m or identity
        numeric=[]
        if image is not None:numeric,error=reference(image,w,h,dw,dh,mode,pw,bits//pw,m,pers)
        if bad:error=2;numeric=[]
        commands.extend([mode,w,h,dw,dh,p0,p1,error,bad,len(image or []),len(numeric)])
        inputs.extend(image or []);outputs.extend(numeric);matrices.extend(v&0xffffffff for v in m)
    if supported:
        transforms=[identity,[65536,0,32768,0,65536,16384,0,0,65536],
          [65536,0,-65536,0,65536,0,0,0,65536],[32768,16384,0,-8192,65536,65536,0,0,65536],
          [-65536,0,196608,0,65536,0,0,0,65536],[0,-65536,131072,65536,0,0,0,0,65536],
          [0,0,0,0,0,0,0,0,65536],[2147483647,0,0,0,2147483647,0,0,0,65536]]
        if pers:transforms += [[65536,0,0,0,65536,0,8192,4096,65536],
           [-65536,0,0,0,-65536,0,-4096,0,-65536],
           [65536,0,0,0,65536,0,65536,0,0],[65536,0,0,0,65536,0,0,0,0],
           [65536,0,-1,0,65536,0,0,0,-65536]]
        for w,h,dw,dh in [(1,1,2,2),(1,6,3,4),(8,1,4,3),(4,3,5,4),(8,6,8,6)]:
            for m in transforms:
                for mode in (0,1):add(w,h,dw,dh,mode,m,[rng.randrange(1<<bits) for _ in range(w*h)])
        for bad in (1,2):add(4,3,4,3,0,identity,[0]*12,bad=bad)
        for shape in [(0,2,2,2),(9,2,2,2),(2,7,2,2),(2,2,0,2),(2,2,2,0)]:add(*shape,0,error=2)
        add(2,2,2,2,3,error=1);add(2,2,2,2,0,error=2,p0=1);add(2,2,2,2,0,error=2,p1=1)
    else:add(2,2,2,2,0,error=2);add(2,2,2,2,3,error=1)
    for name,values in [('commands',commands),('inputs',inputs),('auxiliary',[0]*len(inputs)),('expected',outputs),('matrices',matrices)]:
        (folder/f'{name}.hex').write_text(''.join(format(v,'09x' if name=='expected' else '08x')+'\n' for v in values))
    return {'commands':len(commands)//11,'inputs':len(inputs),'outputs':len(outputs),'reset_cases':4 if supported else 0}


def main():
    evidence=evidence_dir('projective_adapter')
    sources=[HERE/'rtl/cip_image_projective_frame.v',HERE/'rtl/cip_image_affine.v',HERE/'rtl/cip_image_perspective.v']
    sources += [HERE.parents[2]/line.strip() for line in (HERE.parent/'image/rtl_sources.f').read_text().splitlines() if line.strip() and not line.startswith('#')]
    tracked=[*sources,HERE/'sim/tb_cip_image_projective.v',Path(__file__)]
    hashes={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    results=[]
    with tempfile.TemporaryDirectory(prefix='cip_projective_') as temporary:
        for pers,bits,pw in [(p,b,w) for p in (0,1) for b,w in [(1,1),(8,8),(24,8),(32,16),(10,8)]]:
            label=f'pers{pers}_dw{bits}_pw{pw}'
            folder=Path(temporary)/label;folder.mkdir()
            counts=fixtures(folder,bits,pw,pers)
            binary=folder/'sim.vvp'
            execute(['iverilog','-g2012',*(['-DPROJECTIVE_PERSPECTIVE'] if pers else []),'-s','tb_cip_image_projective',f'-Ptb_cip_image_projective.DW={bits}',f'-Ptb_cip_image_projective.PW={pw}',f'-Ptb_cip_image_projective.PERSPECTIVE={pers}','-o',binary,*sources,HERE/'sim/tb_cip_image_projective.v'],HERE,evidence/f'{label}_compile.log')
            output=execute(['vvp',binary,f'+folder={folder}',f'+commands={counts["commands"]}',f'+pixels={counts["inputs"]}',f'+outputs={counts["outputs"]}'],HERE,evidence/f'{label}_simulation.log')
            marker=f'PROJECTIVE PASS width={bits} pixel={pw} commands={counts["commands"]} pixels={counts["outputs"]}'
            if marker not in output:raise RuntimeError('Missing scaler PASS marker')
            print(output.strip());results.append({'perspective':pers,'data_w':bits,'pixel_w':pw,**counts})
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p)] for p in tracked):raise RuntimeError('Source changed during regression')
    write_json(evidence/'summary.json',{'status':'PASS','cases':results,'source_sha256':hashes,'synthesis':'not_run','board':'not_run'})
    print(f'evidence={evidence}')


if __name__=='__main__':main()
