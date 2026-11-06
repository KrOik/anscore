"""SPDX-License-Identifier: Apache-2.0. Independent direct-index/Fraction oracles."""
from fractions import Fraction
import hashlib,random

PROFILES=[dict(name='1x1_t1',w=1,h=1,t=1,epochs=3,q=16,protocol=0),
          dict(name='9x5_t8',w=9,h=5,t=8,epochs=3,q=72,protocol=1),
          dict(name='256x256_t32',w=256,h=256,t=32,epochs=1,q=72,protocol=0)]

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def hexfile(path,values,bits):
    path.write_text(''.join(f'{v:0{(bits+3)//4}x}\n' for v in values),encoding='ascii',newline='\n')

def assets(w,h,epoch):
    indices=[(x*17+y*29+epoch*73)&255 for y in range(h) for x in range(w)]
    palette=[]
    for i in range(256):
        alpha=[0,1,127,128,254,255][(i+epoch)%6]
        rgb=(((i*43+epoch*17)&255)<<16)|(((255-i+epoch*11)&255)<<8)|((i*101+epoch)&255)
        palette.append((alpha<<24)|rgb)
    return indices,palette

def core_vectors(profile,dest):
    w,h,t,epochs,q=(profile[k] for k in ['w','h','t','epochs','q'])
    all_indices=[];all_palette=[];requests=[];golden=[];counts=dict(visible=0,transparent=0,out_of_range=0)
    sampled_indices=set();sampled_alphas=set()
    for epoch in range(epochs):
        indices,palette=assets(w,h,epoch);all_indices.extend(indices);all_palette.extend(palette)
        rng=random.Random(370000+w*101+h*17+epoch)
        coords=[(0,0),(w-1,h-1),(min(w,255),0),(0,min(h,255)),(255,255),
                (min(1,w-1),min(1,h-1)),(0,h-1),(w-1,0)]
        if w==256:coords.extend((15*k,0) for k in range(1,7))
        coords += [(i%w,(i//w)%h) for i in range(min(w*h,q-len(coords)))]
        while len(coords)<q:coords.append((rng.randrange(256),rng.randrange(256)))
        for i,(u,v) in enumerate(coords[:q]):
            x=(65535-i*257)&65535;y=(32768+epoch*101+i*513)&65535;tag=((1<<(t-1))+epoch*7+i)&((1<<t)-1)
            if u>=w or v>=h:rgb=alpha=visible=0;reason=1;counts['out_of_range']+=1
            else:
                index=indices[v*w+u];rgba=palette[index];rgb=rgba&0xffffff;alpha=rgba>>24
                sampled_indices.add(index);sampled_alphas.add(alpha)
                visible=int(alpha!=0);reason=0 if visible else 2
                counts['visible' if visible else 'transparent']+=1
            requests.append(x|(y<<16)|(u<<32)|(v<<40)|(tag<<48))
            golden.append(x|(y<<16)|(rgb<<32)|(alpha<<56)|(visible<<64)|(reason<<65)|(tag<<67))
    values={'texture.hex':(all_indices,8),'palette.hex':(all_palette,32),
            'requests.hex':(requests,48+t),'golden.hex':(golden,67+t)}
    for name,(data,bits) in values.items():hexfile(dest/name,data,bits)
    assert counts['visible'] and counts['transparent']
    if w<256 or h<256:assert counts['out_of_range']
    if w==256:assert 255 in sampled_indices and {0,1,127,128,254,255}<=sampled_alphas
    counts.update(sampled_indices=sorted(sampled_indices),sampled_alphas=sorted(sampled_alphas))
    return dict(profile,checked=q*(epochs+(5 if profile['protocol'] else 0)),resets=6 if profile['protocol'] else 1,
                coverage=counts,vectors_sha256={n:sha(dest/n) for n in values})

def scene_assets():
    texture,palette=assets(4,4,0);texture=list(range(16));texture[10]=3
    # Known transparent/opaque/half-alpha texels used by scene anchors.
    palette[0]=0x00112233;palette[3]=0x8000ff00;palette[5]=0xffff0000
    return texture,palette

def primitives():
    # vertices, texel coordinates, Z, depth function, Z write, RGB mask
    return [
        ([(0,0),(8,0),(0,8)],[(0,0),(3,0),(0,3)],100,1,1,7),
        ([(8,0),(8,8),(0,8)],[(3,0),(3,3),(0,3)],100,1,1,7),
        ([(1,1),(9,1),(1,9)],[(1,1)]*3,200,1,1,7),
        ([(2,2),(7,2),(2,7)],[(2,2)]*3,50,1,1,7),
        ([(0,8),(8,8),(0,12)],[(255,255)]*3,0,0,1,7),
        ([(0,0),(2,0),(0,2)],[(0,0),(2,0),(0,2)],25,0,1,7),
        ([(0,0),(0,8),(8,0)],[(0,0),(0,3),(3,0)],75,2,0,5),
        ([(0,0),(1,1),(2,2)],[(0,0)]*3,0,0,1,7),
        ([(-5,-5),(-4,-5),(-5,-4)],[(1,1)]*3,0,0,1,7)]

def triangle_samples(vertices,uv,w=16,h=12):
    # Whole viewport enumeration and exact rational affine attributes; no RTL bbox recurrence.
    def edge(a,b,x,y):return (b[0]-a[0])*(y-a[1])-(b[1]-a[1])*(x-a[0])
    area=edge(vertices[0],vertices[1],*vertices[2]);vertices=list(vertices);uv=list(uv)
    if area==0:return [],1
    if area<0:vertices[1],vertices[2]=vertices[2],vertices[1];uv[1],uv[2]=uv[2],uv[1];area=-area
    if max(x for x,y in vertices)<0 or min(x for x,y in vertices)>=w or max(y for x,y in vertices)<0 or min(y for x,y in vertices)>=h:return [],2
    pairs=[(vertices[1],vertices[2]),(vertices[2],vertices[0]),(vertices[0],vertices[1])]
    inclusive=[b[1]<a[1] or b[1]==a[1] and b[0]>a[0] for a,b in pairs]
    samples=[]
    for y in range(h):
        for x in range(w):
            weights=[edge(a,b,Fraction(2*x+1,2),Fraction(2*y+1,2)) for a,b in pairs]
            if not all(value>0 or value==0 and inc for value,inc in zip(weights,inclusive)):continue
            attrs=[sum(weight*coords[c] for weight,coords in zip(weights,uv))/area for c in [0,1]]
            rounded=[int(value+Fraction(1,2)) for value in attrs]
            assert all(0<=value<=255 for value in rounded)
            samples.append((x,y,*rounded))
    return samples,0

def scene_vectors(dest):
    texture,palette=scene_assets();canvas={(x,y):(65535,0x102030) for y in range(12) for x in range(16)}
    commands=[];statistics=[];seen=passed=transparent=oob_uv=0
    for i,(vertices,uv,z,func,zw,cw) in enumerate(primitives()):
        packed=0
        for j,(x,y) in enumerate(vertices):packed|=(x&1023)<<(j*20);packed|=(y&1023)<<(j*20+10)
        for j,(u,v) in enumerate(uv):packed|=u<<(60+j*16);packed|=v<<(68+j*16)
        packed|=z<<108;packed|=func<<124;packed|=zw<<126;packed|=cw<<127;packed|=(i+1)<<130;commands.append(packed)
        samples,status=triangle_samples(vertices,uv);visible_count=0
        if i==5:assert samples[0]==(0,0,1,1) # exact half-up UV before point lookup
        for x,y,u,v in samples:
            if u>=4 or v>=4:oob_uv+=1;continue
            rgba=palette[texture[v*4+u]];a=rgba>>24
            if a==0:transparent+=1;continue
            visible_count+=1;seen+=1;old_z,old_rgb=canvas[x,y]
            if not (func==0 or func==1 and z<old_z or func==2 and z<=old_z):continue
            passed+=1;rgb=rgba&0xffffff;result=old_rgb
            for lane in range(3):
                if cw&(1<<lane):
                    src=(rgb>>(8*lane))&255;old=(old_rgb>>(8*lane))&255
                    value=(src*a+old*(255-a)+127)//255
                    result=(result&~(255<<(8*lane)))|(value<<(8*lane))
            canvas[x,y]=(z if zw else old_z,result)
        statistics.append(len(samples)|(visible_count<<17)|(status<<34))
    assert transparent>0 and oob_uv>0 and seen>passed
    # The UV-outside primitive must leave its entire lower region at initial depth.
    assert all(canvas[x,y][0]==65535 for y in range(9,12) for x in range(16))
    golden=[(canvas[x,y][0]<<24)|canvas[x,y][1] for y in range(12) for x in range(16)]
    values={'texture.hex':(texture,8),'palette.hex':(palette,32),'triangles.hex':(commands,138),
            'triangle_stats.hex':(statistics,36),'frame.hex':(golden,40),'frame_stats.hex':([(seen<<64)|(passed<<32)],96)}
    for name,(data,bits) in values.items():hexfile(dest/name,data,bits)
    return dict(name='example',triangles=len(commands),frames=2,checked=384,seen=seen,passed=passed,
                transparent=transparent,uv_out_of_range=oob_uv,vectors_sha256={n:sha(dest/n) for n in values})

def prepare(report):
    profiles=[]
    for p in PROFILES:
        dest=report/p['name'];dest.mkdir();profiles.append(core_vectors(p,dest))
    dest=report/'example';dest.mkdir();example=scene_vectors(dest)
    return profiles,example
