"""Complete RGB LUT transactions, with atomic rollback and direct lookup oracle."""
import math
import random


def fixtures(folder,width):
    rng=random.Random(0x6a77);commands=[];inputs=[];outputs=[];coeffs=[]
    active=None
    def add(mode=0,table=None,damage=None,w=16,h=16,error=0,marker=None,p0=0,p1=0,dims=None):
        nonlocal active
        dw,dh=dims or (w,h)
        if width!=24 and mode<=1:error=2
        if mode==1:w=h=dw=dh=0
        words=[]
        if mode==1 and width==24 and (not error or damage):
            words=list(enumerate(table))
            if damage=='duplicate':words[767]=words[766]
            if damage=='address':words[300]=(65535,words[300][1])
            if damage=='data':words[0]=(0,256)
            if damage=='order':words[12],words[13]=words[13],words[12]
            if not damage:active=table[:]
        pixels=[];expected=[]
        if mode==0 and width==24 and (not error or marker):
            # Every channel traverses all256 addresses in the default frame.
            pixels=[((i%256)<<16)|(((i*73+3)%256)<<8)|((i*151+255)%256) for i in range(w*h)]
            for pixel in pixels:
                if not p0:expected.append(pixel)
                else:expected.append(sum(active[channel*256+((pixel>>shift)&255)]<<shift for channel,shift in enumerate([16,8,0])))
        commands.extend([mode,w,h,dw,dh,p0,p1,error,len(pixels),len(expected),len(words)])
        for address,data in words:coeffs.append((address<<32)|data)
        for i,pixel in enumerate(pixels):
            sof=i==0;eol=i%w==w-1
            if marker=='sof' and i==0:sof=False
            if marker=='eol' and i==len(pixels)-1:eol=not eol
            inputs.append(pixel|(int(sof)<<33)|(int(eol)<<32))
        for i,pixel in enumerate(expected):outputs.append(pixel|(int(i==0)<<33)|(int(i%w==w-1)<<32))
    add()  # Reset bypass.
    add(p0=1,error=2)  # Unloaded LUT cannot silently supply uninitialized values.
    identity=list(range(256))*3
    curves=[identity,[255-i for i in range(256)]*3,
        [int(math.floor(255*(i/255)**exponent+0.5)) for exponent in [0.45,1.0,2.2] for i in range(256)],
        [rng.randrange(256) for _ in range(768)]]
    for table in curves:
        add(1,table=table)
        add(p0=1);add(p0=1,w=1,h=1);add(p0=1,w=1,h=7)
        add(p0=0,w=7,h=3);add(p0=1,w=5,h=4)
    # New table twice before a frame, with no commit between loads.
    add(1,table=identity);add(1,table=curves[1]);add(p0=1)
    for damage in ['duplicate','address','data','order']:
        add(1,table=identity,damage=damage,error=2);add(p0=1)
    add(p0=1,error=2,marker='sof');add(p0=1,error=2,marker='eol')
    add(p0=2,error=2);add(p1=1,error=2);add(w=0,error=2);add(dims=(15,16),error=2)
    add(mode=15,error=1);add(mode=1,table=identity,p0=1,error=2)
    add(p0=0,w=3,h=2);add(p0=1,w=3,h=2)
    for name,values in [('commands',commands),('inputs',inputs),('outputs',outputs),('coeffs',coeffs)]:
        (folder/f'{name}.hex').write_text(''.join(f'{x:x}\n' for x in values))
    return {'commands':len(commands)//11,'inputs':len(inputs),'outputs':len(outputs),'coeffs':len(coeffs),'width':width}
