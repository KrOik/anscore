"""Independent tile histogram/strict redistribution/bilinear CLAHE oracle."""
from pathlib import Path
from collections import deque
import random
import sys
import tempfile
import hashlib

HERE=Path('D:\\sipeedTANG20K\\projects\\common_ip_scaffold\\signal_video')
CAND=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE.parent/'integration'))
from tooling import evidence_dir,execute,write_json

def clahe(image,w,h,tw,th,clip):
    nx,ny=(w+tw-1)//tw,(h+th-1)//th;luts=[]
    for ty in range(ny):
        for tx in range(nx):
            hist=[0]*256
            for y in range(ty*th,min(h,(ty+1)*th)):
                for x in range(tx*tw,min(w,(tx+1)*tw)):hist[image[y*w+x]]+=1
            excess=sum(max(0,v-clip) for v in hist);hist=[min(v,clip) for v in hist]
            # Independent capacity-level allocation equivalent to ascending repeated unit sweeps.
            while excess:
                eligible=[i for i,v in enumerate(hist) if v<clip]
                for i in eligible[:excess]:hist[i]+=1
                excess-=min(excess,len(eligible))
            cdf=0;lut=[]
            for v in hist:cdf+=v;lut.append(cdf*255//(min(tw,w-tx*tw)*min(th,h-ty*th)))
            luts.append(lut)
    def axis(pos,size,n,extent):
        centers=[2*i*size+min(size,extent-i*size)-1 for i in range(n)]
        pos=2*pos
        if pos<=centers[0]:return 0,0,0
        if pos>=centers[-1]:return n-1,n-1,0
        lo=next(i for i in range(n-1) if centers[i]<=pos<centers[i+1])
        return lo,lo+1,((pos-centers[lo])*256)//(centers[lo+1]-centers[lo])
    result=[]
    for y in range(h):
        y0,y1,fy=axis(y,th,ny,h)
        for x in range(w):
            x0,x1,fx=axis(x,tw,nx,w);g=image[y*w+x]
            total=sum(luts[yy*nx+xx][g]*wx*wy for xx,wx in [(x0,256-fx),(x1,fx)] for yy,wy in [(y0,256-fy),(y1,fy)])
            result.append((total+32768)//65536)
    return result

def fixtures(folder,bits,gray):
    rng=random.Random(7193);commands=[];inputs=[];outputs=[]
    def add(w,h,image,clip=1,tw=2,th=2,mode=0,error=0,bad=0,dims=None):
        dw,dh=dims or (w,h)
        commands.extend([mode,w,h,dw,dh,clip,(th<<16)|tw,error,bad,len(image) if image is not None else 0])
        if image is not None:
            inputs.extend(v | (256 if bad==3 and i==0 else 0) for i,v in enumerate(image))
            if bad not in (1,2):outputs.extend(v | (int(i==0)<<33) | (int(i%w==w-1)<<32) for i,v in enumerate(clahe(image,w,h,tw,th,clip)))
    supported=gray==8 and 8<=bits<=32
    if supported:
        for w,h,tw,th in [(2,2,2,2),(8,2,2,2),(2,6,2,2),(8,6,2,2),(8,6,4,6),(8,6,8,6),(6,4,6,2),
            (1,1,1,1),(1,7,1,3),(9,1,4,1),(9,9,3,3),(15,9,5,3),
            (8,6,3,4),(7,5,3,3),(8,7,3,3),(7,8,3,3),(5,5,5,5),
            (17,17,2,2)]:
            for pattern in range(6):
                image=[rng.randrange(256) for _ in range(w*h)]
                if pattern==0:image=[0]*(w*h)
                if pattern==1:image=[255]*(w*h)
                if pattern==2:image=[127]*(w*h)
                if pattern==3:image=[255 if i%w>=w//2 else 0 for i in range(w*h)]
                if pattern==4:image=[255 if (i%w+i//w)%2 else 0 for i in range(w*h)]
                for clip in [1,2,tw*th]:add(w,h,image,clip,tw,th)
        add(16,16,[i%256 for i in range(256)],1,1,1)
        add(17,15,[0]*255,1,1,1)
        add(32,18,[0]*576,3,32,18)
        add(32,18,[rng.randrange(256) for _ in range(576)],576,32,18)
        add(34,34,[127]*1156,5,34,34)
        add(32,18,None,2,32,18,error=2)
        add(34,34,None,1,2,2,error=2)
        add(17,16,None,1,1,1,error=2)
        for side in [4,5,6]:add(2,2,None,error=2,bad=side)
        for bad in [1,2]+([3] if bits>8 else []):add(4,4,list(range(16)),error=2,bad=bad)
        for kw in [dict(mode=1,error=1),dict(w=0),dict(w=35),dict(h=35),dict(tw=3),dict(tw=0),dict(th=0),dict(clip=0),dict(clip=16777216),dict(dims=(3,2))]:
            args=dict(w=2,h=2,image=None,error=2);args.update(kw);add(**args)
    else:add(2,2,None,error=2);add(2,2,None,mode=1,error=1)
    for name,values in [('commands',commands),('inputs',inputs),('auxiliary',inputs),('expected',outputs)]:
        (folder/f'{name}.hex').write_text(''.join((f'{v:09x}\n' if name=='expected' else f'{v:08x}\n') for v in values))
    return {'commands':len(commands)//10,'pixels':len(inputs),'outputs':len(outputs),'width':bits,'gray':gray,'scope':'functional' if supported else 'rejection_only'}

def main():
    evidence=evidence_dir('clahe_narrow_div_candidate');cases=[]
    sources=[CAND/'cip_image_clahe.v',HERE/'sim/tb_cip_image_clahe.v',CAND/'cip_image_clahe_frame.v',*[HERE.parent/'image/histogram/rtl'/n for n in ['img_hist_ratio_u8.v','img_hist_clahe_interp.v','img_hist_serial_multiply.v']]]
    tracked=[*sources,Path(__file__)]
    hashes={str(p.relative_to(HERE.parent)):hashlib.sha256(p.read_bytes()).hexdigest() for p in tracked}
    with tempfile.TemporaryDirectory(prefix='cip_clahe_') as temporary:
        for bits,gray in [(8,8),(24,8),(32,8),(4,8),(24,12)]:
            label=f'w{bits}_g{gray}';folder=Path(temporary)/label;folder.mkdir();counts=fixtures(folder,bits,gray);binary=folder/'test.vvp'
            execute(['iverilog','-g2012','-s','tb_cip_image_clahe',f'-Ptb_cip_image_clahe.DW={bits}',
                f'-Ptb_cip_image_clahe.GB={gray}','-o',binary,*sources],HERE,evidence/f'{label}_compile.log')
            output=execute(['vvp',binary,f'+folder={folder}',f'+commands={counts["commands"]}',f'+pixels={counts["pixels"]}',f'+outputs={counts["outputs"]}'],HERE,evidence/f'{label}_simulation.log',timeout=600)
            if f'CLAHE PASS width={bits}' not in output:raise RuntimeError('missing PASS')
            print(output.strip());cases.append(counts)
    if any(hashlib.sha256(p.read_bytes()).hexdigest()!=hashes[str(p.relative_to(HERE.parent))] for p in tracked):raise RuntimeError('source changed')
    write_json(evidence/'summary.json',{'status':'PASS','cases':cases,'source_sha256':hashes,'board':'not_run','synthesis':'not_run','reset_cases':9,'algorithm':'8bit strict clip iterative unit redistribution; direct CDF floor; Q8 tile-center bilinear round-half-up' })
    print(f'evidence={evidence}')

if __name__=='__main__':main()
