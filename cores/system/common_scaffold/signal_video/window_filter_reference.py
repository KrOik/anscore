"""Independent 2-D window arithmetic/order-statistic frame-filter oracle."""
from fractions import Fraction
import random


def fixtures(folder,width,operation):
    rng=random.Random(713+width*19+operation);maximum=(1<<width)-1
    commands=[];inputs=[];outputs=[]
    def add(mode=0,w=5,h=4,error=0,marker=None,p0=0,p1=0,dims=None,kind='random'):
        dw,dh=dims or (w-2,h-2)
        pixels=[];expected=[]
        if not error or marker:
            for y in range(h):
                for x in range(w):
                    if kind=='black':pixel=0
                    elif kind=='white':pixel=maximum
                    elif kind=='checker':pixel=((x+y)%2)*maximum
                    elif kind=='impulse':pixel=maximum if x==w//2 and y==h//2 else 0
                    elif kind=='ramp':pixel=(x+3*y)*maximum//max(1,w+3*h-4)
                    else:pixel=rng.randrange(maximum+1)
                    pixels.append(pixel)
            weights=[1,2,1,2,4,2,1,2,1]
            for y in range(1,h-1):
                for x in range(1,w-1):
                    window=[pixels[(y+dy)*w+x+dx] for dy in [-1,0,1] for dx in [-1,0,1]]
                    if operation==2:out=sorted(window)[4]
                    else:
                        mean=Fraction(sum(window),9) if operation==0 else Fraction(sum(a*b for a,b in zip(window,weights)),16)
                        value=mean+Fraction(1,2);out=value.numerator//value.denominator
                    expected.append(out)
        commands.extend([mode,w,h,dw&65535,dh&65535,p0,p1,error,len(pixels),len(expected)])
        for i,p in enumerate(pixels):
            sof=i==0;eol=i%w==w-1
            if marker=='sof' and i==0:sof=False
            if marker=='extra' and i==1:sof=True
            if marker=='eol' and i==len(pixels)-1:eol=not eol
            inputs.append(p|(int(sof)<<33)|(int(eol)<<32))
        for i,p in enumerate(expected):outputs.append(p|(int(i==0)<<33)|(int(i%dw==dw-1)<<32))
    for kind in ['black','white','checker','impulse','ramp','random']:
        for w,h in [(3,3),(5,3),(3,5),(4,4),(7,6),(8,4)]:add(w=w,h=h,kind=kind)
    for marker in ['sof','extra','eol']:add(error=2,marker=marker)
    add(mode=1,error=1);add(w=2,error=2);add(h=2,error=2);add(w=9,error=2)
    add(dims=(5,4),error=2);add(p0=1,error=2);add(p1=1,error=2)
    add(w=3,h=3,kind='black')
    for name,values in [('commands',commands),('inputs',inputs),('outputs',outputs)]:
        (folder/f'{name}.hex').write_text(''.join(f'{x:x}\n' for x in values))
    return {'commands':len(commands)//10,'inputs':len(inputs),'outputs':len(outputs),'width':width,'operation':operation}
