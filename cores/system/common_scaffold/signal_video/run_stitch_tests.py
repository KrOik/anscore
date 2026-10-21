"""Independent SAD translation registration and union-canvas stitch regression."""
from pathlib import Path
import sys
import random
import tempfile
import hashlib

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / 'integration'))
from tooling import evidence_dir, execute, write_json


def registration(a,b,w,h,s):
    def luma(v):return (77*(v>>16)+150*((v>>8)&255)+29*(v&255)+128)//256
    costs=[]
    for dy in range(-s,s+1):
        for dx in range(-s,s+1):
            cost=sum(abs(luma(a[y*w+x])-luma(b[(y+dy)*w+x+dx])) for y in range(s,h-s) for x in range(s,w-s))
            costs.append((cost,dx,dy))
    ranked=sorted(enumerate(costs),key=lambda v:(v[1][0],v[0]))
    cost,dx,dy=ranked[0][1]
    confidence=0 if s==0 else ranked[1][1][0]-cost
    return dx,dy,confidence


def reference(a,b,w,h,s,weight,background,dx,dy):
    result=[];cw=w+2*s;ch=h+2*s
    for y in range(ch):
        for x in range(cw):
            xx=x-s;yy=y-s;ax=xx+dx;ay=yy+dy
            pa=0<=xx<w and 0<=yy<h;pb=0<=ax<w and 0<=ay<h
            if pa and pb:
                va=a[yy*w+xx];vb=b[ay*w+ax];value=0
                for shift in (0,8,16):value|=((((va>>shift)&255)*(256-weight)+((vb>>shift)&255)*weight+128)//256)<<shift
            elif pa:value=a[yy*w+xx]
            elif pb:value=b[ay*w+ax]
            else:value=background
            result.append(value|(int(x==0 and y==0)<<33)|(int(x==cw-1)<<32))
    return result


def fixtures(folder,bits,w,h,s):
    rng=random.Random(71387);commands=[];inputs=[];auxiliary=[];outputs=[];registrations=[]
    supported=bits==24 and w>2*s and h>2*s and s>=0
    def add(mode,a=None,b=None,p0=128,p1=0,error=0,bad=0,shape=None):
        numeric=[];shape=shape or (w,h,w+2*s,h+2*s)
        if a is not None and bad==0:
            if mode==0:
                dx,dy,confidence=registration(a,b,w,h,s);registrations.append({'dx':dx,'dy':dy,'confidence':confidence})
                if s!=0 and confidence<1:error=2
                else:numeric=reference(a,b,w,h,s,p0,p1,dx,dy)
            else:
                dx=p1&65535;dy=p1>>16
                if dx>=32768:dx-=65536
                if dy>=32768:dy-=65536
                numeric=reference(a,b,w,h,s,p0,0,dx,dy)
        commands.extend([mode,*shape,p0,p1,error,bad,len(a or []),len(numeric)])
        inputs.extend(a or []);auxiliary.extend(b or []);outputs.extend(numeric)
    if supported:
        for dy in range(-s,s+1):
            for dx in range(-s,s+1):
                a=[rng.randrange(1<<24) for _ in range(w*h)]
                b=[rng.randrange(1<<24) for _ in range(w*h)]
                for y in range(h):
                    for x in range(w):
                        if 0<=x+dx<w and 0<=y+dy<h:b[(y+dy)*w+x+dx]=a[y*w+x]
                for weight in (0,128,256):add(0,a,b,p0=weight,p1=0x71395b)
        for dx,dy in [(0,0),(-1,0),(1,1),(-s,-s),(s,s),(-32768,32767),(w,0)]:
            for weight in (0,1,127,128,255,256):
                add(1,[rng.randrange(1<<24) for _ in range(w*h)],[rng.randrange(1<<24) for _ in range(w*h)],p0=weight,p1=((dy&65535)<<16)|(dx&65535))
        for pattern in (0,0xffffff):add(0,[pattern]*(w*h),[pattern]*(w*h),p0=128,p1=0xabcdef)
        for bad in (1,3):add(1,[0],[0],bad=bad,error=2)
        for bad in (2,4):add(1,[0]*(w*h),[0]*(w*h),bad=bad,error=2)
        add(0,error=2) # capture timeout with no valid input
        for shape in [(0,h,w+2*s,h+2*s),(w+1,h,w+2*s,h+2*s),(w,h,w,h)]:
            if shape!=(w,h,w+2*s,h+2*s):add(0,error=2,shape=shape)
        add(2,error=1);add(0,error=2,p0=257);add(0,error=2,p1=0xff000000)
        add(1,[0]*(w*h),[0xffffff]*(w*h),p0=128)
    else:add(0,error=2);add(2,error=1)
    for name,values in [('commands',commands),('inputs',inputs),('auxiliary',auxiliary),('expected',outputs)]:
        (folder/f'{name}.hex').write_text(''.join(format(v,'09x' if name=='expected' else '08x')+'\n' for v in values))
    return {'commands':len(commands)//11,'inputs':len(inputs),'outputs':len(outputs),'reset_cases':3 if supported else 0,'registrations':registrations}


def main():
    evidence=evidence_dir('stitch_adapter')
    sources=[HERE/'rtl/cip_image_stitch.v']
    sources += [HERE.parents[2]/line.strip() for line in (HERE.parent/'image/rtl_sources.f').read_text().splitlines() if line.strip() and not line.startswith('#')]
    tracked=[*sources,HERE/'sim/tb_cip_image_stitch.v',Path(__file__)]
    hashes={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    results=[]
    with tempfile.TemporaryDirectory(prefix='cip_stitch_') as temporary:
        for bits,w,h,shift in [(24,4,3,1),(24,7,5,2),(24,1,1,0),(24,8,6,0),(8,4,3,1)]:
            label=f'dw{bits}_{w}x{h}_s{shift}'
            folder=Path(temporary)/label;folder.mkdir()
            counts=fixtures(folder,bits,w,h,shift)
            binary=folder/'sim.vvp'
            execute(['iverilog','-g2012','-s','tb_cip_image_stitch',f'-Ptb_cip_image_stitch.DW={bits}',f'-Ptb_cip_image_stitch.W={w}',f'-Ptb_cip_image_stitch.H={h}',f'-Ptb_cip_image_stitch.S={shift}','-o',binary,*sources,HERE/'sim/tb_cip_image_stitch.v'],HERE,evidence/f'{label}_compile.log')
            output=execute(['vvp',binary,f'+folder={folder}',f'+commands={counts["commands"]}',f'+pixels={counts["inputs"]}',f'+outputs={counts["outputs"]}'],HERE,evidence/f'{label}_simulation.log')
            marker=f'STITCH PASS width={bits} shape={w}x{h} shift={shift} commands={counts["commands"]} pixels={counts["outputs"]}'
            if marker not in output:raise RuntimeError('Missing scaler PASS marker')
            print(output.strip());results.append({'data_w':bits,'width':w,'height':h,'shift':shift,**counts})
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p)] for p in tracked):raise RuntimeError('Source changed during regression')
    write_json(evidence/'summary.json',{'status':'PASS','cases':results,'source_sha256':hashes,'synthesis':'not_run','board':'not_run'})
    print(f'evidence={evidence}')


if __name__=='__main__':main()
