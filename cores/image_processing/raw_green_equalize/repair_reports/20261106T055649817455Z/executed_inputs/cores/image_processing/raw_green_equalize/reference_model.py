"""SPDX-License-Identifier: Apache-2.0. Immutable 2-D CFA maps, no RTL schedule."""
from pathlib import Path
import hashlib, random

PROFILES=[dict(name='1x1_d8_t1',w=1,h=1,d=8,t=1),
          dict(name='9x7_d10_t8',w=9,h=7,d=10,t=8),
          dict(name='32x24_d12_t32',w=32,h=24,d=12,t=32)]
EXAMPLE=dict(name='example',w=16,h=12,d=10,t=8)
CASES=16

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def put(path,values,bits):
    path.write_text(''.join(f'{v:0{(bits+3)//4}x}\n' for v in values),encoding='ascii',newline='\n')

def make_cases(w,h,bits,tag_bits):
    maximum=(1<<bits)-1;scale=1<<(bits-8);result=[]
    for case in range(CASES):
        pattern=case%4;enable=case!=9;gap=maximum;edge=maximum
        rng=random.Random(3900+case)
        image={(x,y):rng.randrange(maximum+1) for y in range(h) for x in range(w)}
        if case<8:
            gap=8*scale-(case>=4);edge=0
            for x,y in image:
                plane=((y&1)*2+(x&1))^pattern
                image[x,y]=[7*scale,100*scale,108*scale,maximum-5][plane]
        elif case==10:
            edge=0
            image={(x,y):(17*x+31*y+5)*scale%(maximum+1) for x,y in image}
        elif case==11:
            image={(x,y):maximum-((((y&1)*2+(x&1))^pattern)==2) for x,y in image}
        elif case in (12,13):
            pattern=0;edge=(6 if case==12 else 5)*scale
            image={(x,y):(maximum//4+x*scale+2*y*scale+
                    (4*scale if (((y&1)*2+(x&1))^pattern)==1 else 0))%(maximum+1)
                   for x,y in image}
        elif case==15:
            gap=0;edge=0;image={(x,y):maximum for x,y in image}
        tag=((1<<(tag_bits-1))+13*case)&((1<<tag_bits)-1)
        result.append(dict(pattern=pattern,enable=int(enable),gap=gap,edge=edge,tag=tag,
                           image=image,bad_markers=case==14))
    return result

def equalize(image,w,h,cfg):
    output={};flags={};reasons={'eligible':0,'gap_rejected':0,'edge_rejected':0}
    for y in range(h):
        for x in range(w):
            center=image[x,y];applied=False
            site=((y&1)*2+(x&1))^cfg['pattern']
            if cfg['enable'] and site in (1,2) and 0<x<w-1 and 0<y<h-1:
                neighbors=[image[x+dx,y+dy] for dy in (-1,1) for dx in (-1,1)]
                average=(sum(neighbors)+2)//4
                range_ok=max(neighbors)-min(neighbors)<=cfg['edge']
                difference_ok=abs(center-average)<=cfg['gap']
                reasons['eligible']+=1
                reasons['edge_rejected']+=not range_ok
                reasons['gap_rejected']+=not difference_ok
                applied=range_ok and difference_ok
                value=(4*center+sum(neighbors)+4)//8 if applied else center
            else:value=center
            output[x,y]=value;flags[x,y]=(int(applied),int(value!=center))
    return output,flags,reasons

def demosaic(image,w,h,pattern):
    def sample(x,y):return image[max(0,min(w-1,x)),max(0,min(h-1,y))]
    output={}
    for y in range(h):
        for x in range(w):
            site=((y&1)*2+(x&1))^pattern;c=image[x,y]
            cross=sum(sample(x+dx,y+dy) for dx,dy in ((0,-1),(-1,0),(1,0),(0,1)))//4
            diagonal=sum(sample(x+dx,y+dy) for dy in (-1,1) for dx in (-1,1))//4
            horizontal=(sample(x-1,y)+sample(x+1,y))//2
            vertical=(sample(x,y-1)+sample(x,y+1))//2
            if site==0:rgb=(c,cross,diagonal)
            elif site==3:rgb=(diagonal,cross,c)
            elif site==1:rgb=(horizontal,c,vertical)
            else:rgb=(vertical,c,horizontal)
            output[x,y]=rgb
    return output

def vectors(profile,dest,integration=False):
    w,h,bits,tag_bits=(profile[k] for k in ('w','h','d','t'))
    configs=[];inputs=[];golden=[];done=[];applied=changed=0;reasons_total={}
    cases=make_cases(w,h,bits,tag_bits)
    for case,cfg in enumerate(cases):
        out,flags,reasons=equalize(cfg['image'],w,h,cfg)
        for key,value in reasons.items():reasons_total[key]=reasons_total.get(key,0)+value
        if integration:rgb=demosaic(out,w,h,cfg['pattern'])
        a=sum(v[0] for v in flags.values());c=sum(v[1] for v in flags.values())
        applied+=a;changed+=c
        config=cfg['enable']|(cfg['pattern']<<1)|(cfg['gap']<<3)|(cfg['edge']<<(3+bits))|(cfg['tag']<<(3+2*bits))
        configs.append(config)
        for y in range(h):
            for x in range(w):
                i=y*w+x;sof=int(i==0);eol=int(x==w-1);last=int(i==w*h-1)
                markers=sof|(eol<<1)|(last<<2)
                if cfg['bad_markers']:
                    if i==0:markers^=1
                    if i==(w*h)//2:markers^=2
                    if i==w*h-1:markers^=4
                inputs.append(cfg['image'][x,y]|(markers<<bits))
                if integration:
                    r,g,b=rgb[x,y]
                    value=(r<<(2*bits))|(g<<bits)|b
                    golden.append(value|(sof<<(3*bits))|(eol<<(3*bits+1))|(last<<(3*bits+2)))
                else:
                    fa,fc=flags[x,y]
                    golden.append(out[x,y]|(fa<<bits)|(fc<<(bits+1))|(sof<<(bits+2))|(eol<<(bits+3))|(last<<(bits+4)))
        done.append(int(cfg['bad_markers'])|(a<<3)|(c<<20)|(cfg['tag']<<37))
        if not cfg['enable']:assert all(out[pos]==cfg['image'][pos] for pos in out)
        assert all(0<=v<(1<<bits) for v in out.values())
        assert all(not flags[x,y][0] for x,y in out if x in (0,w-1) or y in (0,h-1))
    if w>=7 and h>=5:
        assert changed>0 and reasons_total['gap_rejected']>0 and reasons_total['edge_rejected']>0
        # Exact equality gates and immediately adjacent rejected thresholds.
        assert (done[0]>>3)&131071>0 and ((done[4]>>3)&131071)==0
        assert ((done[12]>>3)&131071)>0 and ((done[13]>>3)&131071)==0
    values={'config.hex':(configs,3+2*bits+tag_bits),'input.hex':(inputs,bits+3),
            'golden.hex':(golden,3*bits+3 if integration else bits+5),
            'done.hex':(done,37+tag_bits),
            'counts.hex':([CASES,w*h,applied,changed],32)}
    for name,(data,width) in values.items():put(dest/name,data,width)
    return dict(profile,integration=integration,cases=CASES,commands=2*CASES+2,
        checked_done_records=2*CASES,checked_output_records=2*CASES*w*h,
        expected_applied=2*applied,expected_changed=2*changed,
        resets=4,live_resets=['after first input','held first output','held checked DONE'],
        frames_checked=2*CASES,marker_error_frames=2,reasons=reasons_total,
        vectors_sha256={name:sha(dest/name) for name in values})

def prepare(report):
    profiles=[]
    for p in PROFILES:
        dest=report/p['name'];dest.mkdir();profiles.append(vectors(p,dest))
    dest=report/'example';dest.mkdir()
    return profiles,vectors(EXAMPLE,dest,True)
