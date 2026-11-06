"""SPDX-License-Identifier: Apache-2.0. Independent immutable 2-D order statistics."""
import hashlib,random

PROFILES=[dict(name='1x1_d8_t1',w=1,h=1,d=8,t=1),
          dict(name='9x7_d10_t8',w=9,h=7,d=10,t=8),
          dict(name='17x13_d10_t32',w=17,h=13,d=10,t=32)]
EXAMPLE=dict(name='example',w=16,h=12,d=8,t=8)
CASES=16

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def put(path,values,bits):
    path.write_text(''.join(f'{v:0{(bits+3)//4}x}\n' for v in values),encoding='ascii',newline='\n')

def csc(pixel,bits,inverse=False):
    """Direct specification matrix, no pipeline/product decomposition or HDL import."""
    mid=1<<(bits-1);maximum=(1<<bits)-1
    if inverse:
        x=(pixel[0],pixel[1]-mid,pixel[2]-mid)
        rows=((65536,0,91881),(65536,-22553,-46802),(65536,116130,0));bias=(0,0,0)
    else:
        x=pixel;rows=((19595,38470,7471),(-11058,-21710,32768),(32768,-27439,-5329));bias=(0,mid,mid)
    result=[]
    for row,b in zip(rows,bias):
        v=sum(a*c for a,c in zip(x,row))+b*65536
        q=(abs(v)+32768)//65536
        if v<0:q=-q
        result.append(max(0,min(maximum,q)))
    return tuple(result)

def make_cases(w,h,bits,tag_bits,integration):
    maximum=(1<<bits)-1;scale=1<<(bits-8);result=[]
    for case in range(CASES):
        rng=random.Random(4000+case);threshold=maximum;enable=int(case!=1)
        image={(x,y):tuple(rng.randrange(maximum+1) for _ in range(3)) for y in range(h) for x in range(w)}
        if case in (0,1,8):
            threshold=0 if not integration else maximum
            image={(x,y):((100*scale,25*scale,220*scale) if (x%3==1 and y%3==1) else (100*scale,220*scale,25*scale)) for x,y in image}
        elif case==2:image={p:(maximum//2,maximum//2,maximum//2) for p in image};threshold=0
        elif case in (3,4):
            threshold=6*scale-(case==4)
            image={(x,y):((50+x+2*y)*scale,)*3 if integration else
                   ((50+x+2*y)*scale,25*scale if (x+y)%2 else 220*scale,220*scale if (x+y)%2 else 25*scale) for x,y in image}
        elif case in (5,6):
            threshold=maximum-(case==5)
            image={(x,y):((maximum if (x+y)%2 else 0,)*3 if integration else
                   (maximum if (x+y)%2 else 0,25*scale if x%2 else 220*scale,220*scale if y%2 else 25*scale)) for x,y in image}
        elif case==7:image={p:(maximum,maximum,maximum) for p in image}
        elif case==10:
            threshold=0;image={(x,y):(100*scale+(x//4+y//4),rng.randrange(maximum+1),rng.randrange(maximum+1)) for x,y in image}
        elif case==11:
            image={p:(100*scale,100*scale,100*scale) for p in image}
            image[w//2,h//2]=(100*scale,0,maximum);threshold=0 if not integration else maximum
        elif case==12:
            threshold=0;image={(x,y):(maximum if x>=w//2 else 0,rng.randrange(maximum+1),rng.randrange(maximum+1)) for x,y in image}
        elif case==13:image={p:(0,0,0) for p in image};threshold=0
        elif case==15:image={(x,y):((7*x+13*y)*scale%(maximum+1),(11*x+5*y)*scale%(maximum+1),(3*x+17*y)*scale%(maximum+1)) for x,y in image}
        tag=((1<<(tag_bits-1))+11*case)&((1<<tag_bits)-1)
        result.append(dict(enable=enable,threshold=threshold,tag=tag,image=image,bad_markers=case==14))
    return result

def suppress(image,w,h,cfg):
    result={};flags={};reasons=dict(eligible=0,range_rejected=0,equal_gate=0)
    for y in range(h):
        for x in range(w):
            center=image[x,y];apply=False
            if cfg['enable'] and 0<x<w-1 and 0<y<h-1:
                neighbors=[image[x+dx,y+dy] for dy in (-1,0,1) for dx in (-1,0,1)]
                spread=max(p[0] for p in neighbors)-min(p[0] for p in neighbors)
                apply=spread<=cfg['threshold'];reasons['eligible']+=1
                reasons['range_rejected']+=not apply;reasons['equal_gate']+=spread==cfg['threshold']
                output=(center[0],sorted(p[1] for p in neighbors)[4],sorted(p[2] for p in neighbors)[4]) if apply else center
            else:output=center
            result[x,y]=output;flags[x,y]=(int(apply),int(output!=center))
            assert output[0]==center[0]
    return result,flags,reasons

def vectors(profile,dest,integration=False):
    w,h,bits,tag_bits=(profile[k] for k in ('w','h','d','t'))
    configs=[];inputs=[];golden=[];done=[];applied=changed=0;reason_total={}
    for case,cfg in enumerate(make_cases(w,h,bits,tag_bits,integration)):
        working={p:csc(v,bits) for p,v in cfg['image'].items()} if integration else cfg['image']
        output,flags,reasons=suppress(working,w,h,cfg)
        for key,value in reasons.items():reason_total[key]=reason_total.get(key,0)+value
        a=sum(v[0] for v in flags.values());c=sum(v[1] for v in flags.values());applied+=a;changed+=c
        if not cfg['enable']:assert output==working
        assert all(not flags[x,y][0] and output[x,y]==working[x,y] for x,y in output if x in (0,w-1) or y in (0,h-1))
        if integration:output={p:csc(v,bits,True) for p,v in output.items()}
        configs.append(cfg['enable']|(cfg['threshold']<<1)|(cfg['tag']<<(bits+1)))
        for y in range(h):
            for x in range(w):
                i=y*w+x;sof=int(i==0);eol=int(x==w-1);last=int(i==w*h-1);markers=sof|(eol<<1)|(last<<2)
                if cfg['bad_markers']:
                    if i==0:markers^=1
                    if i==(w*h)//2:markers^=2
                    if i==w*h-1:markers^=4
                source=cfg['image'][x,y];pixel=output[x,y]
                inputs.append((source[0]<<(2*bits))|(source[1]<<bits)|source[2]|(markers<<(3*bits)))
                data=(pixel[0]<<(2*bits))|(pixel[1]<<bits)|pixel[2]
                fa,fc=flags[x,y]
                golden.append(data|((sof|(eol<<1)|(last<<2))<<(3*bits)) if integration else
                              data|(fa<<(3*bits))|(fc<<(3*bits+1))|(sof<<(3*bits+2))|(eol<<(3*bits+3))|(last<<(3*bits+4)))
        done.append(int(cfg['bad_markers'])|(a<<3)|(c<<20)|(cfg['tag']<<37))
    if w>=7 and h>=5:
        assert applied>changed>0 and reason_total['range_rejected']>0 and reason_total['equal_gate']>0
        assert ((done[3]>>3)&131071)>0 and ((done[4]>>3)&131071)==0
        assert ((done[5]>>3)&131071)==0 and ((done[6]>>3)&131071)>0
    values={'config.hex':(configs,1+bits+tag_bits),'input.hex':(inputs,3*bits+3),
            'golden.hex':(golden,3*bits+(3 if integration else 5)),
            'done.hex':(done,37+tag_bits),'counts.hex':([CASES,w*h,applied,changed],32)}
    for name,(data,width) in values.items():put(dest/name,data,width)
    return dict(profile,integration=integration,cases=CASES,commands=34,checked_done_records=32,
        checked_output_records=32*w*h,expected_applied=2*applied,expected_changed=2*changed,
        resets=4,live_resets=['after first input','held first output','held checked DONE'],
        frames_checked=32,marker_error_frames=2,reasons=reason_total,
        vectors_sha256={name:sha(dest/name) for name in values})

def prepare(report):
    profiles=[]
    for profile in PROFILES:
        dest=report/profile['name'];dest.mkdir();profiles.append(vectors(profile,dest))
    dest=report/'example';dest.mkdir()
    return profiles,vectors(EXAMPLE,dest,True)
