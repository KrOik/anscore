"""Independent centered-angle nearest/bilinear rotation regression."""
from pathlib import Path
import sys
import random
import tempfile
import hashlib

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'integration'))
from tooling import evidence_dir, execute, write_json


def reference(image,w,h,dw,dh,mode,pw,lanes,c,s):
    result=[]
    tx=((w-1)*65536-c*(dw-1)-s*(dh-1))//2
    ty=((h-1)*65536+s*(dw-1)-c*(dh-1))//2
    for y in range(dh):
        for x in range(dw):
            qx=(c*x+s*y+tx)//256;qy=(-s*x+c*y+ty)//256
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
    return result


def fixtures(folder,bits,pw,public):
    import math
    rng=random.Random(53127);commands=[];inputs=[];outputs=[]
    supported=1<=pw<=16 and pw<=bits<=32 and bits%pw==0
    def add(w,h,dw,dh,mode=0,c=65536,s=0,image=None,error=0,bad=0):
        numeric=reference(image,w,h,dw,dh,mode,pw,bits//pw,c,s) if image is not None and bad==0 else []
        commands.extend([mode,w,h,dw,dh,c&0xffffffff,s&0xffffffff,error,bad,len(image or []),len(numeric)])
        inputs.extend(image or []);outputs.extend(numeric)
    if supported:
        for w,h,dw,dh in [(1,1,1,1),(1,6,3,5),(8,1,4,3),(4,3,3,4),(5,4,4,5),(8,6,8,6),(7,5,9,8)]:
            for angle in (0,90,180,270,15,-15,30,-30,45,-45,73,123):
                c=round(math.cos(math.radians(angle))*65536);s=round(math.sin(math.radians(angle))*65536)
                for mode in (0,1):
                    image=[rng.randrange(1<<bits) for _ in range(w*h)]
                    add(w,h,dw,dh,mode,c,s,image)
                    if public:
                        # Interleave all preserved lossless modes with the new angle mode.
                        for old in range(4):
                            ow,oh=(h,w) if old%2 else (w,h)
                            numeric=[]
                            for yy in range(oh):
                                for xx in range(ow):
                                    sx,sy=[(xx,yy),(yy,h-1-xx),(w-1-xx,h-1-yy),(w-1-yy,xx)][old]
                                    numeric.append(image[sy*w+sx]|(int(xx==0 and yy==0)<<33)|(int(xx==ow-1)<<32))
                            commands.extend([8+old,w,h,ow,oh,0,0,0,0,len(image),len(numeric)])
                            inputs.extend(image);outputs.extend(numeric)
        for c,s in [(65535,0),(-65535,0),(0,65535),(0,-65535)]:
            for mode in (0,1):add(5,4,4,5,mode,c,s,[rng.randrange(1<<bits) for _ in range(20)])
        for c,s in [(0,0),(65534,0),(65537,0),(-65537,0),(0,65537),(65536,65536),(2147483647,0),(-2147483648,-2147483648)]:add(2,2,2,2,c=c,s=s,error=2)
        # Valid angles but center offsets outside signed Q16.16 range.
        add(8,6,65535,65535,c=-65536,s=0,error=2)
        add(8,6,65535,65535,c=0,s=65536,error=2)
        for shape in [(0,2,2,2),(9,2,2,2),(2,7,2,2),(2,2,0,2),(2,2,2,0)]:add(*shape,error=2)
        for bad in (1,2):add(4,3,5,4,1,46341,46341,[0]*12,error=2,bad=bad)
        add(2,2,2,2,image=[0,1,2,3])
    else:add(2,2,2,2,error=2)
    for name,values in [('commands',commands),('inputs',inputs),('auxiliary',[0]*len(inputs)),('expected',outputs)]:
        (folder/f'{name}.hex').write_text(''.join(format(v,'09x' if name=='expected' else '08x')+'\n' for v in values))
    return {'commands':len(commands)//11,'inputs':len(inputs),'outputs':len(outputs),'reset_cases':3 if supported else 0}


def main():
    evidence=evidence_dir('rotate_angle_adapter')
    sources=[HERE/'rtl/cip_image_rotate_angle_frame.v',HERE/'rtl/cip_image_rotate.v',HERE/'rtl/cip_image_permute_frame.v']
    sources += [HERE.parents[2]/line.strip() for line in (HERE.parent/'image/rtl_sources.f').read_text().splitlines() if line.strip() and not line.startswith('#')]
    tracked=[*sources,HERE/'sim/tb_cip_image_rotate_angle_frame.v',Path(__file__)]
    hashes={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    results=[]
    with tempfile.TemporaryDirectory(prefix='cip_rotate_angle_') as temporary:
        for public,bits,pw in [(p,b,w) for p in (0,1) for b,w in [(1,1),(8,8),(12,12),(24,8),(32,16),(10,8),(24,17)]]:
            label=f'public{public}_dw{bits}_pw{pw}'
            folder=Path(temporary)/label;folder.mkdir()
            counts=fixtures(folder,bits,pw,public)
            binary=folder/'sim.vvp'
            execute(['iverilog','-g2012',*(['-DROTATE_PUBLIC'] if public else []),'-s','tb_cip_image_rotate_angle_frame',f'-Ptb_cip_image_rotate_angle_frame.DW={bits}',f'-Ptb_cip_image_rotate_angle_frame.PW={pw}','-o',binary,*sources,HERE/'sim/tb_cip_image_rotate_angle_frame.v'],HERE,evidence/f'{label}_compile.log')
            output=execute(['vvp',binary,f'+folder={folder}',f'+commands={counts["commands"]}',f'+pixels={counts["inputs"]}',f'+outputs={counts["outputs"]}'],HERE,evidence/f'{label}_simulation.log')
            marker=f'ROTATE_ANGLE PASS width={bits} pixel={pw} commands={counts["commands"]} pixels={counts["outputs"]}'
            if marker not in output:raise RuntimeError('Missing scaler PASS marker')
            print(output.strip());results.append({'public':public,'data_w':bits,'pixel_w':pw,**counts})
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p)] for p in tracked):raise RuntimeError('Source changed during regression')
    write_json(evidence/'summary.json',{'status':'PASS','cases':results,'source_sha256':hashes,'synthesis':'not_run','board':'not_run'})
    print(f'evidence={evidence}')


if __name__=='__main__':main()
