"""Packed pixel oracle; brightness uses rational rounding around an arbitrary pivot."""
from fractions import Fraction
import random


def convert(pixel,inverse):
    values=[(pixel>>shift)&255 for shift in [16,8,0]]
    if inverse:
        values[1]-=128;values[2]-=128
        rows=[(256,0,359),(256,-88,-183),(256,454,0)]
        offsets=[0,0,0]
    else:
        rows=[(77,150,29),(-43,-85,128),(128,-107,-21)]
        offsets=[0,128,128]
    channels=[]
    for row,offset in zip(rows,offsets):
        exact=sum(Fraction(c*v,256) for c,v in zip(row,values))+Fraction(1,2)
        channels.append(max(0,min(255,exact.numerator//exact.denominator+offset)))
    return sum(c<<shift for c,shift in zip(channels,[16,8,0]))


def fixtures(folder,width,kind):
    rng=random.Random(1923+width+kind);maximum=(1<<width)-1
    commands=[];inputs=[];outputs=[]
    gains=[256,256,256]
    def add(p0=0,p1=0,mode=0,w=7,h=5,error=0,malformed=False,dims=None,pattern=None,marker='eol'):
        nonlocal gains
        dw,dh=dims or (w,h)
        valid_width=kind==0 or width==24
        if (mode==0 or (kind==2 and mode==1)) and not valid_width:
            error=2;malformed=False
        pixels=pattern if pattern is not None else [rng.randrange(maximum+1) for _ in range(w*h)]
        nin=w*h if error==0 or malformed else 0
        expected=[]
        for p in pixels[:nin]:
            if kind==0:
                out=p^p0
            elif kind==3:
                out=sum(min(255,(((p>>shift)&255)*gain+128)//256)<<shift for shift,gain in zip([16,8,0],gains))
            elif kind==2:
                out=convert(p,mode)
            else:
                gain=p1&0xffff;pivot=(p1>>16)&255
                out=0
                for shift in [16,8,0]:
                    value=Fraction((((p>>shift)&255)-pivot)*gain,256)+Fraction(1,2)
                    rounded=value.numerator//value.denominator
                    out|=max(0,min(255,rounded+pivot+p0))<<shift
            expected.append(out)
        if kind==3 and nin:
            sums=[sum((p>>shift)&255 for p in pixels[:nin]) for shift in [16,8,0]]
            target=sum(sums)//3;minimum=p0&65535;maximum_gain=p0>>16
            gains=[maximum_gain if value==0 else min(maximum_gain,max(minimum,target*256//value)) for value in sums]
            if sum(sums)==0:
                # Existing solver explicitly uses neutral gains for all-black statistics.
                gains=[256,256,256]
        commands.extend([mode,w,h,dw,dh,p0&0xffffffff,p1,error,nin,len(expected)])
        for i,p in enumerate(pixels[:nin]):
            sof=i==0
            eol=i%w==w-1
            if malformed:
                if marker=='eol' and i==nin-1:eol=not eol
                if marker=='missing_sof' and i==0:sof=False
                if marker=='extra_sof' and i==1:sof=True
            inputs.append(p | (int(sof)<<33) | (int(eol)<<32))
        for i,p in enumerate(expected):
            outputs.append(p | (int(i==0)<<33) | (int(i%w==w-1)<<32))
    if kind==0:
        for mask in [0,maximum,maximum//3,maximum//5,1,1<<(width-1)]:
            add(mask)
        add(maximum,w=1,h=1,pattern=[0])
        add(maximum,malformed=True,error=2)
        if width<32:add(1<<width,error=2)
        add(0,1,error=2)
    elif kind==1:
        for gain in [0,1,128,255,256,257,512,65535]:
            for pivot in [0,128,255]:
                for offset in [-512,-1,0,1,511]:
                    add(offset,(pivot<<16)|gain,w=8,h=2,
                        pattern=[0,0xffffff,0x7f8081,0x00ff80]+[rng.randrange(maximum+1) for _ in range(12)])
        add(0,0x800100,malformed=True,error=2)
        add(-513,error=2);add(512,error=2);add(0,1<<24,error=2)
    elif kind==2:
        # Packed full-range code-value cube; direction-specific integer oracle.
        cube=[(a<<16)|(b<<8)|c for a in range(0,256,17) for b in range(0,256,17) for c in range(0,256,17)]
        neutral=[(a<<16)|(a<<8)|a for a in range(256)]
        for direction in [0,1]:
            for start in range(0,len(cube),256):
                add(mode=direction,w=16,h=16,pattern=cube[start:start+256])
            add(mode=direction,w=16,h=16,pattern=neutral)
            for w,h in [(1,1),(1,7),(5,1),(7,9),(13,3),(3,2)]:
                add(mode=direction,w=w,h=h)
            add(mode=direction,malformed=True,error=2)
        add(1,error=2);add(0,1,error=2)
    else:
        bounds=(1024<<16)|64
        for color in [0xc83220,0x208030,0x2030c0,0x808080,0,0x00ff80,0xffffff]:
            add(bounds,w=5,h=3,pattern=[color]*15)
            add(bounds,w=3,h=2)
        for limits in [(0,65535),(256,256),(0,0),(511,512),(64,1024)]:
            p=(limits[1]<<16)|limits[0]
            add(p,w=1,h=1,pattern=[0x010203]);add(p,w=1,h=7)
        add(bounds,error=2,malformed=True)
        add(0,w=1,h=1,pattern=[0]);add(bounds,w=3,h=2)
        add((63<<16)|64,error=2);add(bounds,1,error=2);add(bounds,mode=1,error=1)
    add(mode=15,error=1);add(w=0,error=2);add(dims=(6,5),error=2)
    for marker in ['missing_sof','extra_sof']:
        add(11 if kind==1 else maximum if kind==0 else (1024<<16)|64 if kind==3 else 0,0x800100 if kind==1 else 0,
            mode=1 if kind==2 else 0,malformed=True,error=2,marker=marker)
    add((1024<<16)|64 if kind==3 else 0,0x800100 if kind==1 else 0,w=1,h=1,pattern=[0])
    for name,values in [('commands',commands),('inputs',inputs),('outputs',outputs)]:
        (folder/f'{name}.hex').write_text(''.join(f'{x:x}\n' for x in values))
    return {'commands':len(commands)//10,'inputs':len(inputs),'outputs':len(outputs),'width':width,'kind':kind}
