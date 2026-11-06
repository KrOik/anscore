"""SPDX-License-Identifier: Apache-2.0. One deterministic preparation per profile."""
import argparse,hashlib,json,random,sys
from pathlib import Path
sys.dont_write_bytecode=True
from reference_model import infer

def prepare(profile):
    maxin,maxout,maxw,maxh,tagw=profile
    rng=random.Random(420000+maxin*31+maxout)
    frames=[];totals=dict(frames=0,inputs=0,outputs=0,configs=0,clips=0,inexact=0)
    weights=None;meta=None
    def config(cin,cout):
        nonlocal weights,meta
        weights=[[rng.randrange(-8,8) for _ in range(cin)] for _ in range(4*cout)]
        meta=[];ops=[(2,0,0,0,0,0,0,0,0)]
        for r,ww in enumerate(weights):
            for word in range((cin+7)//8):
                packed=sum((w&15)<<(4*i) for i,w in enumerate(ww[8*word:8*word+8]))
                ops.append((0,r,word,packed,0,0,0,0,0))
            bias=[0,1,-1,2147483647,-2147483648,rng.randrange(-1000,1001)][r%6]
            scale=[1,0,65535,3,7,2][r%6]
            shift=[0,31,31,1,4,2][r%6]
            zero=[0,127,-128,1,-1,3][r%6]
            meta.append((bias,scale,shift,zero))
            ops.append((1,r,0,0,bias,scale,shift,zero,0))
        ops.extend([(3,0,0,0,0,0,0,0,2),(0,4*maxout,0,0,0,0,0,0,1),
                    (0,0,(maxin+7)//8,0,0,0,0,0,1)])
        return ops
    def add(w,h,cin,cout,ops=None,error=0,bad=None,reset=0):
        tag=rng.getrandbits(tagw);zero=rng.choice([0,128,255,17])
        if error in (1,2):
            samples=[];outputs=[]
        else:
            image=[[[rng.choice([0,255,128,rng.randrange(256)]) for _ in range(cin)] for _ in range(w)] for _ in range(h)]
            outputs=infer(image,weights,meta,zero,cout)
            samples=[(v,int(y==0 and x==0 and c==0),int(x==w-1 and c==cin-1),
                      int(y==h-1 and x==w-1 and c==cin-1))
                     for y,row in enumerate(image) for x,vec in enumerate(row) for c,v in enumerate(vec)]
            if bad is not None:
                index,field=bad
                samples=samples[:index+1]
                row=list(samples[-1]);row[field]^=1;samples[-1]=tuple(row)
                pixel=index//cin;sy,sx=divmod(pixel,w)
                outputs=outputs[:4*w*cout*sy+2*sx*cout]
        ops=ops or []
        head=(w,h,cin,cout,zero,tag,error,len(samples),len(outputs),len(ops),reset)
        lines=[' '.join(map(str,head))]
        lines += ['%d %d %d %08x %d %d %d %d %d'%o for o in ops]
        lines += [' '.join(map(str,s)) for s in samples]
        lines += [' '.join(map(str,o)) for o in outputs]
        frames.append('\n'.join(lines)+'\n')
        totals['frames']+=1;totals['inputs']+=len(samples);totals['outputs']+=len(outputs);totals['configs']+=len(ops)
        totals['clips']+=sum(o[1] for o in outputs);totals['inexact']+=sum(o[2] for o in outputs)
    # Unconfigured and invalid dimensions precede arithmetic and consume no input.
    add(1,1,1,1,[(2,0,0,0,0,0,0,0,0)],error=2)
    add(0,1,1,1,error=1)
    add(maxw+1,1,1,1,error=1)
    add(1,1,maxin+1,1,error=1)
    add(1,1,1,maxout+1,error=1)
    ci,co=min(maxin,9),min(maxout,3)
    ops=config(ci,co)
    add(min(maxw,5),min(maxh,3),ci,co,ops)
    add(min(maxw,3),min(maxh,2),ci,co)  # resident reuse without writes
    # Each independent malformed marker flushes weights; prove zero-input missing config,
    # then configure a complete future frame using the same original arithmetic oracle.
    for field in [1,2,3]:
        w,h=min(maxw,3),min(maxh,2)
        pixel=1 if w>1 else 0
        add(w,h,ci,co,config(ci,co),error=3,bad=(pixel*ci,field))
        add(1,1,ci,co,error=2)
        add(w,h,ci,co,config(ci,co))
    # Exact channel/buffer boundaries; no combined maximum-frame throughput claim.
    add(1,1,maxin,maxout,config(maxin,maxout))
    add(maxw,1,1,maxout,config(1,maxout))
    for i in range(8):
        ci=rng.randint(1,maxin);co=rng.randint(1,maxout)
        add(rng.randint(1,min(maxw,7)),rng.randint(1,min(maxh,4)),ci,co,config(ci,co))
    return str(len(frames))+'\n'+''.join(frames),totals

if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--profile',required=True);p.add_argument('--output',required=True)
    args=p.parse_args();profile=tuple(map(int,args.profile.split(',')))
    data,counts=prepare(profile);out=Path(args.output);out.write_bytes(data.encode())
    summary=dict(profile=list(profile),counts=counts,vector_sha256=hashlib.sha256(data.encode()).hexdigest(),vector_bytes=len(data))
    out.with_suffix('.summary.json').write_bytes((json.dumps(summary,indent=2)+'\n').encode())
    print('PASS prepare_subpixel '+json.dumps(summary,sort_keys=True))
