"""SPDX-License-Identifier: Apache-2.0. Direct viewport enumeration, no RTL schedule."""
from pathlib import Path
import hashlib

PROFILES=[dict(name='1x1_t1',w=1,h=1,tw=1,th=1,t=1),
          dict(name='9x6_t8',w=9,h=6,tw=16,th=16,t=8),
          dict(name='128x128_t32',w=128,h=128,tw=256,th=256,t=32)]
ALPHAS=[0,1,127,128,254,255]

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def put(path,values,bits):path.write_text(''.join(f'{v:0{(bits+3)//4}x}\n' for v in values),encoding='ascii',newline='\n')
def rgba(index):return (ALPHAS[index%6]<<24)|(((index*43)&255)<<16)|(((255-index*7)&255)<<8)|((index*101+11)&255)
def texel(u,v):return rgba((u*17+v*31)&255)

def commands(w,h,tw,th):
    a=min(4,tw);b=min(3,th)
    # u,v,width,height,destination x/y,flip x/y
    return [(0,0,a,b,0,0,0,0),
      (0,0,a,b,1,1,1,0),(0,0,a,b,1,1,0,1),(0,0,a,b,1,1,1,1),
      (0,0,min(8,tw),min(5,th),-2,-1,0,0),
      (0,0,a,b,w-2,h-2,1,1),
      (0,0,tw,th,-32768,-32768,0,0),
      (0,0,tw,th,32767,32767,1,1),
      (255,255,0,256,0,0,1,1),(255,255,511,0,0,0,0,0),
      (0,0,257,1,0,0,0,0),(tw-1,0,2,1,0,0,0,0),(0,th-1,1,2,0,0,0,0),
      (tw-1,th-1,1,1,w-1,h-1,1,1),
      (0,0,a,b,-1,1,1,0),(0,0,a,b,1,-1,0,1),
      (0,0,a,b,0,0,0,0)]

def samples(command,w,h,tw,th):
    u,v,cw,ch,dx,dy,fx,fy=command
    if cw==0 or ch==0:return [],0
    if cw>256 or ch>256 or u+cw>tw or v+ch>th:return [],1
    # Enumerating the entire destination viewport independently avoids using
    # the hardware's clipped intersection, starting cursor or recurrence.
    result=[]
    for y in range(h):
      for x in range(w):
        col=x-dx;row=y-dy
        if 0<=col<cw and 0<=row<ch:
          su=u+(cw-1-col if fx else col);sv=v+(ch-1-row if fy else row)
          result.append((su,sv,x,y))
    return result,0 if result else 2

def pack_command(c,tag):
    u,v,w,h,x,y,fx,fy=c
    return u|(v<<8)|(w<<16)|(h<<25)|((x&65535)<<34)|((y&65535)<<50)|(fx<<66)|(fy<<67)|(tag<<68)

def core_vectors(p,dest):
    w,h,tw,th,t=(p[k] for k in ['w','h','tw','th','t'])
    cs=[];ds=[];qs=[];ss=[];ms=[];alphas=set()
    for i,c in enumerate(commands(w,h,tw,th)):
      tag=((1<<(t-1))+i*7)&((1<<t)-1);cs.append(pack_command(c,tag))
      points,status=samples(c,w,h,tw,th);written=skipped=0
      for u,v,x,y in points:
        color=texel(u,v);a=color>>24;rgb=color&0xffffff;visible=int(a!=0);alphas.add(a)
        qs.append(u|(v<<8)|(x<<16)|(y<<32)|(tag<<48))
        ss.append(rgb|(a<<24)|(visible<<32)|(x<<33)|(y<<49))
        if visible:ms.append(rgb|(a<<24)|(x<<32)|(y<<48));written+=1
        else:skipped+=1
      ds.append(len(points)|(written<<17)|(skipped<<34)|(status<<51)|(tag<<53))
    assert len(cs)==17 and len(qs)<4096 and len(ms)<4096
    if tw>1:assert set(ALPHAS)<=alphas
    values={'commands.hex':(cs,68+t),'done.hex':(ds,53+t),'requests.hex':(qs,48+t),
            'responses.hex':(ss,65),'fragments.hex':(ms,64),'counts.hex':([len(cs),len(qs),len(ms)],32)}
    for name,(data,bits) in values.items():put(dest/name,data,bits)
    return dict(p,commands=2*len(cs)+1,done_checks=2*len(cs),queries=2*len(qs),
                fragments=2*len(ms),resets=3,sampled_alphas=sorted(alphas),vectors_sha256={n:sha(dest/n) for n in values})

def scene_vectors(dest):
    w,h,tw,th=16,12,8,8;canvas={(x,y):0x102030 for y in range(h) for x in range(w)}
    texture=[(u*17+v*31)&255 for v in range(th) for u in range(tw)];palette=[rgba(i) for i in range(256)]
    cs=[];ds=[];seen=0;transparent=0;alphas=set()
    for i,c in enumerate(commands(w,h,tw,th)):
      cs.append(pack_command(c,i+1));points,status=samples(c,w,h,tw,th);written=skipped=0
      for u,v,x,y in points:
        color=palette[texture[v*tw+u]];alpha=color>>24;alphas.add(alpha)
        if alpha==0:skipped+=1;transparent+=1;continue
        rgb=color&0xffffff;old=canvas[x,y];value=0;written+=1;seen+=1
        for lane in range(3):
          a=(rgb>>(8*lane))&255;b=(old>>(8*lane))&255
          value|=((a*alpha+b*(255-alpha)+127)//255)<<(8*lane)
        canvas[x,y]=value
      ds.append(len(points)|(written<<17)|(skipped<<34)|(status<<51)|((i+1)<<53))
    assert set(ALPHAS)<=alphas and transparent>0
    values={'texture.hex':(texture,8),'palette.hex':(palette,32),'commands.hex':(cs,76),
            'done.hex':(ds,61),'frame.hex':([canvas[x,y] for y in range(h) for x in range(w)],24),
            'counts.hex':([len(cs),seen,transparent],32)}
    for name,(data,bits) in values.items():put(dest/name,data,bits)
    return dict(name='example',frames=2,commands=35,done_checks=34,checked_output_records=384,
                per_frame_seen=seen,per_frame_transparent=transparent,resets=2,
                vectors_sha256={n:sha(dest/n) for n in values})

def prepare(report):
    profiles=[]
    for p in PROFILES:
      dest=report/p['name'];dest.mkdir();profiles.append(core_vectors(p,dest))
    dest=report/'example';dest.mkdir();return profiles,scene_vectors(dest)
