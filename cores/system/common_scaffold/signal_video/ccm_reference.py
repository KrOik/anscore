"""Atomic CCM bank commands and independent rational matrix oracle."""
from fractions import Fraction
import random


def fixtures(folder,width):
    rng=random.Random(0xcc17);commands=[];inputs=[];outputs=[];coeffs=[]
    identity=[1024,0,0,0,1024,0,0,0,1024,0,0,0]
    active=identity[:]
    def add(mode=0,table=None,damage=None,w=7,h=3,error=0,marker=None,p0=0,p1=0,dims=None):
        nonlocal active
        dw,dh=dims or (w,h)
        if width!=24 and mode<=1:error=2
        if mode==1:
            w=h=dw=dh=0
        words=[]
        if mode==1 and (error==0 or damage) and width==24:
            order=list(range(12));rng.shuffle(order)
            words=[(index,table[index]&0xffffffff) for index in order]
            if damage=='duplicate':words[-1]=words[0]
            if damage=='address':words[-1]=(65535,words[-1][1])
            if damage=='sign':words[-1]=(words[-1][0],65535)
            if not damage:active=table[:]
        pixels=[];expected=[]
        if mode==0 and (not error or marker) and width==24:
            pixels=[rng.randrange(1<<24) for _ in range(w*h)]
            directed=[0,0xffffff,0x010101,0x7f8081,0xff0000,0xff00,0xff]
            pixels[:min(len(pixels),len(directed))]=directed[:len(pixels)]
            for pixel in pixels:
                channels=[(pixel>>shift)&255 for shift in [16,8,0]];out=0
                for row in range(3):
                    value=sum(Fraction(active[row*3+j]*channels[j],1024) for j in range(3))+Fraction(1,2)
                    value=value.numerator//value.denominator+active[9+row]
                    out=(out<<8)|max(0,min(255,value))
                expected.append(out)
        commands.extend([mode,w,h,dw,dh,p0,p1,error,len(pixels),len(expected),len(words)])
        for index,data in words:coeffs.append((index<<32)|data)
        for i,pixel in enumerate(pixels):
            sof=i==0;eol=i%w==w-1
            if marker=='sof' and i==0:sof=False
            if marker=='eol' and i==len(pixels)-1:eol=not eol
            inputs.append(pixel|(int(sof)<<33)|(int(eol)<<32))
        for i,pixel in enumerate(expected):outputs.append(pixel|(int(i==0)<<33)|(int(i%w==w-1)<<32))
    add()
    tables=[identity,[0,0,1024,1024,0,0,0,1024,0,0,0,0],
        [-1024,0,0,0,-1024,0,0,0,-1024,255,255,255],
        [512,-512,0,-512,512,0,512,0,512,127,127,0],
        [32767,-32768,32767,-32768,32767,-32768,32767,32767,-32768,32767,-32768,0]]
    tables += [[rng.randrange(-3000,3001) for _ in range(9)]+[rng.randrange(-30,31) for _ in range(3)] for _ in range(10)]
    for table in tables:
        add(1,table=table)
        add(w=17,h=5);add(w=1,h=1);add(w=1,h=7)
    for damage in ['duplicate','address','sign']:
        add(1,table=identity,damage=damage,error=2)
        add(w=5,h=4)  # Old matrix remains usable after rejected bank.
    add(error=2,marker='sof');add(error=2,marker='eol')
    add(p0=1,error=2);add(p1=1,error=2);add(w=0,error=2);add(dims=(6,3),error=2)
    add(mode=15,error=1)
    add(mode=1,table=identity,p0=1,error=2)
    add(w=3,h=2)
    for name,values in [('commands',commands),('inputs',inputs),('outputs',outputs),('coeffs',coeffs)]:
        (folder/f'{name}.hex').write_text(''.join(f'{x:x}\n' for x in values))
    return {'commands':len(commands)//11,'inputs':len(inputs),'outputs':len(outputs),'coeffs':len(coeffs),'width':width}
