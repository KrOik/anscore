"""Coordinate/color bilinear oracle for raw Bayer input, independent of RTL taps."""
import random


def fixtures(folder,width,raw_bits):
    rng=random.Random(0xba7e+raw_bits);maximum=(1<<max(raw_bits,1))-1
    commands=[];inputs=[];outputs=[]
    patterns=[(('R','G'),('G','B')),(('G','R'),('B','G')),
              (('G','B'),('R','G')),(('B','G'),('G','R'))]
    supported=width==24 and raw_bits in [8,10,12]
    def add(mode=0,w=5,h=4,error=0,marker=None,payload=False,constant=None,p0=0,p1=0,dims=None):
        dw,dh=dims or (w-2,h-2)
        if not supported and mode<=3:error=2
        pixels=[];expected=[]
        if supported and (not error or marker or payload):
            pixels=[rng.randrange(maximum+1) for _ in range(w*h)] if constant is None else [constant]*(w*h)
            def color(x,y):return patterns[mode][y%2][x%2]
            def average(locations):
                return (sum(pixels[y*w+x] for x,y in locations)+len(locations)//2)//len(locations)
            for y in range(1,h-1):
                for x in range(1,w-1):
                    center=color(x,y);channels={center:pixels[y*w+x]}
                    if center in ['R','B']:
                        channels['G']=average([(x-1,y),(x+1,y),(x,y-1),(x,y+1)])
                        channels['B' if center=='R' else 'R']=average([(x-1,y-1),(x+1,y-1),(x-1,y+1),(x+1,y+1)])
                    else:
                        channels[color(x-1,y)]=average([(x-1,y),(x+1,y)])
                        channels[color(x,y-1)]=average([(x,y-1),(x,y+1)])
                    expected.append(sum((channels[c]>>(raw_bits-8))<<shift for c,shift in zip('RGB',[16,8,0])))
        commands.extend([mode,w,h,dw&65535,dh&65535,p0,p1,error,len(pixels),len(expected)])
        for i,p in enumerate(pixels):
            sof=i==0;eol=i%w==w-1
            if marker=='sof' and i==0:sof=False
            if marker=='extra' and i==1:sof=True
            if marker=='eol' and i==len(pixels)-1:eol=not eol
            if payload and i==2:p|=1<<raw_bits
            inputs.append(p|(int(sof)<<33)|(int(eol)<<32))
        for i,p in enumerate(expected):outputs.append(p|(int(i==0)<<33)|(int(i%dw==dw-1)<<32))
    for pattern in range(4):
        for w,h in [(3,3),(5,3),(3,5),(4,4),(7,6),(8,4)]:add(pattern,w,h)
        add(pattern,constant=0);add(pattern,constant=maximum)
        for marker in ['sof','extra','eol']:add(pattern,error=2,marker=marker)
        add(pattern,error=2,payload=True)
    add(mode=15,error=1);add(w=2,error=2);add(h=2,error=2);add(w=9,error=2)
    add(dims=(5,4),error=2);add(p0=1,error=2);add(p1=1,error=2)
    add(3,3,3,constant=0)  # A clean frame after invalid commands and bad input.
    for name,values in [('commands',commands),('inputs',inputs),('outputs',outputs)]:
        (folder/f'{name}.hex').write_text(''.join(f'{x:x}\n' for x in values))
    return {'commands':len(commands)//10,'inputs':len(inputs),'outputs':len(outputs),'width':width,'raw_bits':raw_bits}
