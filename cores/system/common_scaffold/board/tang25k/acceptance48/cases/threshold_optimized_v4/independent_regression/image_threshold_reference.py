"""Independent rational 2-D and class-mean oracles for the legacy threshold ABI."""
from fractions import Fraction
import random


def otsu(pixels):
    counts=[pixels.count(i) for i in range(256)]
    n=len(pixels);total=sum(pixels);best=Fraction(-1);threshold=0
    for t in range(255):
        a=sum(counts[:t+1]);b=n-a
        if not a or not b:
            continue
        mean_a=Fraction(sum(i*counts[i] for i in range(t+1)),a)
        mean_b=Fraction(sum(i*counts[i] for i in range(t+1,256)),b)
        score=a*b*(mean_a-mean_b)**2
        if score>best:
            best=score;threshold=t
    return threshold


def fixtures(folder,width):
    rng=random.Random(0x971+width);maximum=(1<<width)-1
    commands=[];inputs=[];outputs=[]
    def add(mode,w,h,offset=0,invert=0,error=0,malformed=False,pattern=None,dims=None):
        dw,dh=dims or ((w,h) if mode<2 else (w-2,h-2))
        pixels=pattern if pattern is not None else [rng.randrange(maximum+1) for _ in range(w*h)]
        expected=[]
        if not error or malformed:
            if mode==0:
                expected=[maximum if ((p>=offset)^invert) else 0 for p in pixels]
            elif mode==1:
                threshold=otsu(pixels)
                if not malformed:
                    expected=[maximum if ((p>threshold)^invert) else 0 for p in pixels]
            else:
                weights=[1]*9 if mode==2 else [1,2,1,2,4,2,1,2,1]
                for y in range(1,h-1):
                    for x in range(1,w-1):
                        values=[pixels[(y+dy)*w+x+dx] for dy in [-1,0,1] for dx in [-1,0,1]]
                        mean=Fraction(sum(a*b for a,b in zip(values,weights)),sum(weights))
                        expected.append(maximum if ((pixels[y*w+x]>mean-offset)^invert) else 0)
        nin=w*h if not error or malformed else 0
        commands.extend([mode,w,h,dw,dh,offset&0xffffffff,invert,error,nin,len(expected)])
        for i,p in enumerate(pixels[:nin]):
            sof=i==0;eol=i%w==w-1
            if malformed and i==nin-1:
                eol=not eol
            inputs.append(p | (int(sof)<<33) | (int(eol)<<32))
        for i,p in enumerate(expected):
            outputs.append(p | (int(i==0)<<33) | (int(i%dw==dw-1)<<32))
    add(0,5,3,maximum//2)
    if width<=16:
        for mode in [2,3]:
            for index,offset in enumerate([0,1,-1,maximum,-(maximum+1)]):
                add(mode,3+index%3,3+index%2,offset,index%2)
            add(mode,5,4,-1,1,error=2,malformed=True)
            add(mode,3,3,1,pattern=[0]*9)
        add(2,3,3,maximum+1,error=2)
        add(3,3,3,-maximum-2,error=2)
        add(2,2,3,error=2)
        add(3,5,4,error=2,dims=(5,4))
    else:
        add(2,3,3,error=2);add(3,3,3,error=2)
    if width==8:
        for pattern in [[0]*20,[255]*20,[0,255]*10,list(range(20)),
                        [rng.randrange(256) for _ in range(20)]]:
            for invert in [0,1]:
                add(1,5,4,invert=invert,pattern=pattern)
        add(1,5,4,error=2,malformed=True)
        add(1,4,4,error=2);add(1,5,4,offset=1,error=2)
    else:
        add(1,5,4,error=2)
    add(15,3,3,error=1)
    # Valid recovery and mode switch after every error category.
    add(0,1,1,0,1,pattern=[0])
    for name,values in [('commands',commands),('inputs',inputs),('outputs',outputs)]:
        (folder/f'{name}.hex').write_text(''.join(f'{x:x}\n' for x in values))
    return {'commands':len(commands)//10,'inputs':len(inputs),'outputs':len(outputs),'width':width}
