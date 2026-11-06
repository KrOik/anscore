"""SPDX-License-Identifier: Apache-2.0. Independent integer coefficient specification."""
import hashlib,random

PROFILES=[dict(name='core_t1',kind='core',t=1),dict(name='core_t32',kind='core',t=32),
          dict(name='pair_1x1_t1',kind='pair',w=1,h=1,t=1),
          dict(name='pair_8x8_t28',kind='pair',w=8,h=8,t=28)]
CORE_N=2048
PAIR_N=256

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def put(p,values,bits):p.write_text(''.join(f'{v:0{(bits+3)//4}x}\n' for v in values),encoding='ascii',newline='\n')
def pack(p):return sum(c<<(24-8*i) for i,c in enumerate(p))
def rgba(v):return tuple((v>>shift)&255 for shift in (24,16,8,0))
def coefficients(mode,sa,da):
    return ((0,0),(255,0),(0,255),(255,255-sa),(255-da,255),(da,0),(0,sa),
            (255-da,0),(0,255-sa),(da,255-sa),(255-da,sa),(255-da,255-sa),(255,255))[mode]
def compose(s,d,mode):
    # Deliberately uses integer division rather than the RTL's bounded shift fold.
    error=1 if mode>12 else 2 if max(s[:3])>s[3] else 3 if max(d[:3])>d[3] else 0
    if error:return (0,0,0,0),error
    f,g=coefficients(mode,s[3],d[3])
    out=tuple(min(255,(x*f+y*g+127)//255) for x,y in zip(s,d))
    assert max(out[:3])<=out[3]
    return out,0
def premultiply(p):return tuple((c*p[3]+127)//255 for c in p[:3])+(p[3],)
def output(pixel,error,mode,x,y,tag):return pack(pixel)|(error<<32)|(mode<<34)|(x<<38)|(y<<54)|(tag<<70)

def arithmetic_audit():
    for total in range(130051):
        if total>=65025:fold=255
        else:
            t=total+127;fold=(t+1+(t>>8))>>8
        assert fold==min(255,(total+127)//255)
    # Every alpha pair and operator: extrema C=0 and C=A prove component closure
    # together with monotonicity of the common nonnegative coefficient quantizer.
    for sa in range(256):
        for da in range(256):
            for mode in range(13):
                f,g=coefficients(mode,sa,da)
                alpha=min(255,(sa*f+da*g+127)//255)
                for sc,dc in ((0,0),(sa,0),(0,da),(sa,da)):
                    assert min(255,(sc*f+dc*g+127)//255)<=alpha
    for a in range(256):
        for c in range(256):
            t=c*a+127
            assert (t+1+(t>>8))>>8==(c*a+127)//255<=a
    return dict(quantizer_totals=130051,alpha_mode_pairs=851968,extrema_checks=3407872,premultiply_pairs=65536)

def core_vectors(profile,dest):
    rng=random.Random(41001);cases=[]
    for mode in range(13):
        for sa in (0,1,127,128,254,255):
            for da in (0,1,127,128,254,255):cases.append(((sa,sa//2,0,sa),(0,da//2,da,da),mode))
    cases += [((128,0,0,128),(0,0,128,128),3)]
    for mode in range(16):
        cases.extend([((255,0,0,0),(0,0,0,0),mode),((0,0,0,0),(0,255,0,0),mode),
                      ((255,0,0,0),(0,255,0,0),mode)])
    while len(cases)<CORE_N:
        sa=rng.randrange(256);da=rng.randrange(256);mode=rng.randrange(16)
        s=tuple(rng.randrange(sa+1) for _ in range(3))+(sa,)
        d=tuple(rng.randrange(da+1) for _ in range(3))+(da,)
        cases.append((s,d,mode))
    inputs=[];gold=[];errors=[0]*4;modes=[0]*16
    for i,(s,d,mode) in enumerate(cases):
        x=(i*251+65500)&65535;y=(i*619+32768)&65535;tag=((1<<(profile['t']-1))+i*19)&((1<<profile['t'])-1)
        pixel,error=compose(s,d,mode);errors[error]+=1;modes[mode]+=1
        inputs.append(pack(s)|(pack(d)<<32)|(mode<<64)|(x<<68)|(y<<84)|(tag<<100))
        gold.append(output(pixel,error,mode,x,y,tag))
    assert compose((128,0,0,128),(0,0,128,128),3)==((128,0,64,192),0)
    files={'input.hex':(inputs,100+profile['t']),'golden.hex':(gold,70+profile['t']),
           'counts.hex':([CORE_N],32)}
    for n,(v,b) in files.items():put(dest/n,v,b)
    return dict(profile,n=CORE_N,checked=2*CORE_N,resets=4,modes=modes,errors=errors,
                expected_counters=dict(checked=2*CORE_N,resets=4,quant=130051),
                vectors_sha256={n:sha(dest/n) for n in files})

def pair_vectors(profile,dest):
    w,h,t=(profile[k] for k in ('w','h','t'));tex=[[],[]];pal=[[],[]];queries=[];gold=[]
    for phase in range(2):
        for bank in range(2):
            tex[bank].extend((i*17+bank*37+phase*13)&255 for i in range(w*h))
            for i in range(256):
                alpha=(0,1,127,128,254,255)[(i+bank+phase)%6]
                p=((i*73+phase*41+bank*19)&255,(i*29+51)&255,(i*11+217)&255,alpha)
                # Old sampler palette is {A,R,G,B}; query core stream is {R,G,B,A}.
                pal[bank].append((alpha<<24)|(pack(p)>>8))
        for i in range(PAIR_N):
            su=i%w;sv=(i//w)%h;du=(i*3+1)%w;dv=(i*7+2)%h
            if i%9==0:su=255
            if i%11==0:dv=255
            mode=i%16;x=(i*317+phase*23)&65535;y=(i*811+phase*17)&65535
            tag=((1<<(t-1))+i*23+phase)&((1<<t)-1)
            def sample(bank,u,v):
                if u>=w or v>=h:return (0,0,0,0)
                index=tex[bank][phase*w*h+v*w+u];a=pal[bank][phase*256+index]
                return ((a>>16)&255,(a>>8)&255,a&255,(a>>24)&255)
            s=premultiply(sample(0,su,sv));d=premultiply(sample(1,du,dv));pixel,error=compose(s,d,mode)
            queries.append(su|(sv<<8)|(du<<16)|(dv<<24)|(mode<<32)|(x<<36)|(y<<52)|(tag<<68))
            gold.append(output(pixel,error,mode,x,y,tag))
    files={'query.hex':(queries,68+t),'golden.hex':(gold,70+t),'tex0.hex':(tex[0],8),'tex1.hex':(tex[1],8),
           'pal0.hex':(pal[0],32),'pal1.hex':(pal[1],32),'counts.hex':([PAIR_N,w*h],32)}
    for n,(v,b) in files.items():put(dest/n,v,b)
    return dict(profile,n=PAIR_N,checked=2*PAIR_N+4,resets=3,
                expected_counters=dict(checked=2*PAIR_N+4,resets=3,commands=9,responses=8,pending=1),
                vectors_sha256={n:sha(dest/n) for n in files})

def prepare(report):
    audit=arithmetic_audit();profiles=[]
    for profile in PROFILES:
        dest=report/profile['name'];dest.mkdir()
        profiles.append(core_vectors(profile,dest) if profile['kind']=='core' else pair_vectors(profile,dest))
    return profiles,audit
