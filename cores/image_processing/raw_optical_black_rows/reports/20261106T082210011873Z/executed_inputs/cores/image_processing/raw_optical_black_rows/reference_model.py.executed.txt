"""SPDX-License-Identifier: Apache-2.0. Offline coordinate/statistics oracle; no RTL import."""
import hashlib,random
PROFILES=[dict(name='core_1x1_d8',w=1,h=1,b=8,l=2,r=0,t=1,wrap=0),
          dict(name='core_7x5_d10',w=7,h=5,b=10,l=3,r=4,t=8,wrap=0),
          dict(name='core_17x9_d12',w=17,h=9,b=12,l=32,r=32,t=32,wrap=0),
          dict(name='actual_32x8_d10',w=32,h=8,b=10,l=7,r=5,t=8,wrap=1)]
CASES=16
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def put(p,v,b):p.write_text(''.join(f'{x:0{(b+3)//4}x}\n' for x in v),encoding='ascii',newline='\n')
def outword(value,black,x,y,w,h,pattern,tag,b):
    return value|(black<<b)|(int(x==0 and y==0)<<(2*b))|(int(x==w-1)<<(2*b+1))|(int(x==w-1 and y==h-1)<<(2*b+2))|(x<<(2*b+3))|(y<<(2*b+19))|(pattern<<(2*b+35))|(tag<<(2*b+37))
def arithmetic_audit():
    checked=0
    for b in (8,10,12):
        maximum=(1<<b)-1
        for n in range(1,33):
            for s in range(n*maximum+1):
                # Mathematical nearest half-up versus the stated bounded numerator.
                expected=(2*s+n)//(2*n)
                numerator=s+n//2
                assert numerator<=131056 and 0<=expected<=maximum and numerator//n==expected
                checked+=1
    assert checked==2837040
    return dict(mean_pairs=checked,max_sum=131040,max_rounded_numerator=131056)
def vectors(p,dest):
    w,h,b,l,r,t,wrap=(p[k] for k in ('w','h','b','l','r','t','wrap'));sw=l+w+r;maximum=(1<<b)-1;scale=1<<(b-8)
    configs=[];sensors=[];gold=[];done=[];rows=[];per_case=[]
    for case in range(CASES):
        rng=random.Random(42000+case);low=0;high=maximum;minimum=1;target=0;pattern=case%4
        tag=((1<<(t-1))+case*31)&((1<<t)-1)
        image={};ordinals=[0,0]
        for y in range(h):
            ordinals=[0,0]
            for x in range(sw):
                active=l<=x<l+w;parity=x%2;base=(8+5*y+3*parity)*scale
                v=(100*scale+(x-l)*3+y+base) if active else base
                if case==1:v=0 if active else base
                elif case==2:v=maximum if active else 0
                elif case==3:v=(100*scale if active else 12*scale+ordinals[parity]%2)
                elif case==4:
                    high=maximum-1
                    if not active and parity==0 and ordinals[0]==0:v=maximum
                elif case==5:low=high=13*scale;v=100*scale if active else 13*scale
                elif case in (9,10):
                    high=maximum-1
                    if not active and y==min(1,h-1) and parity==case-9:v=maximum
                elif case==14:v=rng.randrange(maximum+1) if active else rng.randrange(64*scale)
                elif case==15:v=maximum
                image[x,y]=min(maximum,v)
                if not active:ordinals[parity]+=1
        if case==2:target=maximum
        if case==6:low=maximum;high=0
        if case==7:minimum=0
        if case==8:minimum=33
        if case in (14,15):target=maximum//4
        configs.append(low|(high<<b)|(target<<(2*b))|(minimum<<(3*b))|(pattern<<(3*b+6))|(tag<<(3*b+8)))
        marker_bad=1 if case==11 else sw-1 if case==12 else sw*h-1 if case==13 else None
        for y in range(h):
            for x in range(sw):
                i=y*sw+x;markers=int(i==0)|(int(x==sw-1)<<1)|(int(i==sw*h-1)<<2)
                if i==marker_bad:markers^=1 if case==11 else 2 if case==12 else 4
                sensors.append(image[x,y]|(markers<<b))
        result=[];rowwords=[];error=0;consumed=sw*h;complete_rows=0;cl=ch=0
        output_pattern=pattern^(l%2)
        if low>high or minimum==0 or minimum>32:error=1;consumed=0
        else:
            for y in range(h):
                if marker_bad is not None and marker_bad//sw==y:error=2;consumed=marker_bad+1;break
                ref={parity:[image[x,y] for x in range(sw) if not(l<=x<l+w) and x%2==parity and low<=image[x,y]<=high] for parity in (0,1)}
                if len(ref[0])<minimum:error=3;consumed=(y+1)*sw;break
                if len(ref[1])<minimum:error=4;consumed=(y+1)*sw;break
                means={k:(2*sum(v)+len(v))//(2*len(v)) for k,v in ref.items()}
                black0=means[l%2];black1=means[1-l%2]
                rowwords.append(black0|(black1<<b)|(target<<(2*b))|(output_pattern<<(3*b))|(y<<(3*b+2))|(tag<<(3*b+18)))
                for x in range(w):
                    raw=image[x+l,y];black=means[(x+l)%2];corrected=raw-black+target
                    cl+=corrected<0;ch+=corrected>maximum
                    value=max(0,min(maximum,corrected)) if wrap else raw
                    result.append(outword(value,black,x,y,w,h,output_pattern,tag,b))
                complete_rows+=1
        n=len(result);per_case.append(dict(error=error,rows=complete_rows,pixels=n,consumed=consumed,clip_low=cl if wrap else 0,clip_high=ch if wrap else 0))
        gold.extend(result+[0]*(w*h-n));rows.extend(rowwords+[0]*(h-len(rowwords)))
        done.append(error|(complete_rows<<4)|(n<<14)|(consumed<<31)|((cl if wrap else 0)<<49)|((ch if wrap else 0)<<66)|(tag<<83))
    checked=2*sum(c['pixels'] for c in per_case)+4*w*h
    files={'config.hex':(configs,3*b+8+t),'sensor.hex':(sensors,b+3),'golden.hex':(gold,2*b+37+t),
           'rows.hex':(rows,3*b+18+t),'done.hex':(done,83+t),'counts.hex':([CASES,sw*h,w*h,checked],32)}
    for n,(v,width) in files.items():put(dest/n,v,width)
    return dict(p,cases=CASES,per_case=per_case,checked=checked,expected_counters=dict(checked=checked,commands=40,done=36,resets=5,cancelled=4),
                vectors_sha256={n:sha(dest/n) for n in files})
def prepare(report):
    audit=arithmetic_audit();profiles=[]
    for p in PROFILES:
        dest=report/p['name'];dest.mkdir();profiles.append(vectors(p,dest))
    return profiles,audit
