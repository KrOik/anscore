"""2-D edge convolution and lossless signed-word legacy stream oracle."""
import random


def fixtures(folder,width,operation,shift):
    rng=random.Random(711+width+operation);maximum=(1<<width)-1
    commands=[];inputs=[];outputs=[];pixels_total=0
    words=(width+4+width-1)//width
    def add(mode=0,w=5,h=4,error=0,marker=None,p0=0,p1=0,dims=None,kind='random'):
        nonlocal pixels_total
        dw,dh=dims or (w-2,h-2);pixels=[];expected=[]
        if not error or marker:
            for y in range(h):
                for x in range(w):
                    if kind=='black':pixel=0
                    elif kind=='white':pixel=maximum
                    elif kind=='h_ramp':pixel=x*maximum//(w-1)
                    elif kind=='h_reverse':pixel=maximum-x*maximum//(w-1)
                    elif kind=='v_ramp':pixel=y*maximum//(h-1)
                    elif kind=='v_reverse':pixel=maximum-y*maximum//(h-1)
                    elif kind=='checker':pixel=((x+y)%2)*maximum
                    elif kind=='impulse':pixel=maximum if x==w//2 and y==h//2 else 0
                    else:pixel=rng.randrange(maximum+1)
                    pixels.append(pixel)
            for y in range(1,h-1):
                for x in range(1,w-1):
                    if operation==2:
                        gx=4*pixels[y*w+x]-sum(pixels[yy*w+xx] for xx,yy in [(x-1,y),(x+1,y),(x,y-1),(x,y+1)])
                        gy=0;magnitude=abs(gx)
                    else:
                        weights=[1,2,1] if operation==0 else [1,1,1]
                        gx=sum(a*(pixels[(y+dy)*w+x+1]-pixels[(y+dy)*w+x-1]) for a,dy in zip(weights,[-1,0,1]))
                        gy=sum(a*(pixels[(y+1)*w+x+dx]-pixels[(y-1)*w+x+dx]) for a,dx in zip(weights,[-1,0,1]))
                        magnitude=abs(gx)+abs(gy)
                    if not mode:encoded=[min(maximum,magnitude>>shift)]
                    else:
                        values=[gx] if operation==2 else [gx,gy,magnitude]
                        encoded=[(value>>(word*width))&maximum for value in values for word in range(words)]
                    pixel_index=(y-1)*dw+(x-1)
                    for word,value in enumerate(encoded):
                        expected.append(value | (int(pixel_index==0 and word==0)<<33) |
                            (int(x==w-2 and word==len(encoded)-1)<<32))
                    pixels_total+=1
        commands.extend([mode,w,h,dw&65535,dh&65535,p0,p1,error,len(pixels),len(expected)])
        for i,p in enumerate(pixels):
            sof=i==0;eol=i%w==w-1
            if marker=='sof' and i==0:sof=False
            if marker=='extra' and i==1:sof=True
            if marker=='eol' and i==len(pixels)-1:eol=not eol
            inputs.append(p|(int(sof)<<33)|(int(eol)<<32))
        outputs.extend(expected)
    for mode in [0,1]:
        for kind in ['black','white','h_ramp','h_reverse','v_ramp','v_reverse','checker','impulse','random']:
            for w,h in [(3,3),(5,3),(3,5),(7,6)]:add(mode,w,h,kind=kind)
        for marker in ['sof','extra','eol']:add(mode,error=2,marker=marker)
    add(mode=2,error=1);add(w=2,error=2);add(h=2,error=2);add(w=9,error=2)
    add(dims=(5,4),error=2);add(p0=1,error=2);add(p1=1,error=2)
    add(w=3,h=3,kind='black')
    for name,values in [('commands',commands),('inputs',inputs),('outputs',outputs)]:
        (folder/f'{name}.hex').write_text(''.join(f'{x:x}\n' for x in values))
    return {'commands':len(commands)//10,'inputs':len(inputs),'outputs':len(outputs),'pixels':pixels_total,
            'width':width,'operation':operation,'shift':shift}
