"""SPDX-License-Identifier: Apache-2.0. Finite deterministic input generation."""
import random
from reference_model import fuse

PROFILES=[(1,1,1,0),(3,17,8,0),(64,4096,32,0),(1,64,8,1)]

def vectors(C,P,T,EX):
    rng=random.Random(400017+C*101+P+EX*1009)
    rows=[]; state={}; counts=dict(configs=0,frames=0,pairs=0,outputs=0,resets=0,
                                  shape_errors=0,missing_errors=0,last_errors=0,
                                  clips=0,inexact=0,latency_checks=0,ii_checks=0)
    def config(ch,meta,op=0,expected=0):
        rows.append('C '+' '.join(map(str,[op,ch,*meta,expected])))
        counts['configs']+=1
        if expected==0:
            if op==1: state.clear()
            elif op==0: state[ch]=meta
    def frame(p,c,tag,mode=0,bad=None,values=None):
        counts['frames']+=1
        err=1 if p<1 or p>P or c<1 or c>C else 2 if not EX and any(i not in state for i in range(c)) else 0
        n=p*c if not err else 0
        if bad is not None and not err: n=min(n,bad[0]+1);err=3
        out=n-(err==3)
        ba=int(err==3 and bad[1] in (1,3));bb=int(err==3 and bad[1] in (2,3))
        rows.append('F '+' '.join(map(str,[p,c,tag,err,out,ba,bb,n,mode])))
        if err:counts[{1:'shape_errors',2:'missing_errors',3:'last_errors'}[err]]+=1
        counts['pairs']+=n;counts['outputs']+=out
        if mode==1:counts['latency_checks']+=out;counts['ii_checks']+=max(0,out-1)
        for i in range(n):
            if values is not None:a,b=values[i%len(values)]
            elif EX:a,b=rng.randrange(-128,128),rng.randrange(-128,128)
            else:a,b=rng.randrange(256),rng.randrange(256)
            final=int(i==p*c-1);al=bl=final
            if err==3 and i==n-1:
                if ba:al=1-final
                if bb:bl=1-final
            if EX:
                exact=a+b;y=max(-128,min(127,exact));clip=int(y!=exact);inexact=0
            else:y,clip,inexact=fuse(a,b,state[i%c])
            if not(err==3 and i==n-1):counts['clips']+=clip;counts['inexact']+=inexact
            rows.append('S '+' '.join(map(str,[a,b,al,bl,y,clip,inexact])))
    def reset(kind):
        rows.append('R '+str(kind));state.clear();counts['resets']+=1
    identity=(1,1,0,128,128,0,-128,127)
    if EX:
        frame(0,1,1);frame(P+1,1,2)
        edge=[(-128,-128),(-128,127),(127,127),(-1,1),(0,0),(126,1),(-127,-1),(-128,0)]
        frame(P,1,3,1,values=edge)
        for j in range(18):frame(1+j%P,1,4+j,mode=j%2)
        frame(min(P,5),1,24,bad=(0,1));frame(min(P,5),1,25,bad=(min(P,5)-1,2))
        for k in range(1,7):reset(k);frame(min(P,3),1,26+k,1,values=edge)
    else:
        frame(1,1,1);frame(0,1,0);frame(P+1,1,1);frame(1,C+1,0);frame(65535,65535,1)
        config(0,identity,op=2,expected=2)
        config(C,identity,expected=1)
        config(0,(*identity[:-2],100,-100),expected=3)
        config(0,identity)
        config(0,(*identity[:-2],100,-100),expected=3)
        frame(min(P,3),1,0,1,values=[(0,0),(255,255),(255,1)])
        if C>1:frame(1,C,1)
        for ch in range(C):
            meta=(rng.randrange(65536),rng.randrange(65536),rng.randrange(32),rng.randrange(256),rng.randrange(256),rng.randrange(-128,128),-128,127)
            config(ch,meta)
        frame(1,C,(1<<T)-1,1)
        if P>100:frame(P,1,1,1)
        # Exact ties, opposite large products, zero scale, output-zero ordering,
        # upper/lower interval clamps and shifts above the numerator width.
        cases=[(1,1,s,128,128,z,-128,127) for s in range(32) for z in [0,1]]
        cases += [(65535,65535,0,128,127,0,-128,127),(65535,65535,8,0,255,-128,-128,127),
                  (0,0,31,255,0,127,-8,7),(1,3,1,128,128,1,-128,127),
                  (65535,1,17,255,0,1,5,5)]
        edge=[(0,0),(255,255),(127,128),(129,128),(125,128),(131,128),(255,0),(0,255)]
        for j,meta in enumerate(cases):
            config(0,meta);frame(min(P,8),1,j&((1<<T)-1),j%2,values=edge)
        for j in range(10):
            config(0,(rng.randrange(65536),rng.randrange(65536),rng.randrange(32),rng.randrange(256),rng.randrange(256),rng.randrange(-128,128),-64,63))
            frame(min(P,17),min(C,3),j&((1<<T)-1),j%2)
        frame(min(P,3),1,0,bad=(0,1));frame(min(P,3),1,1,bad=(min(P,3)-1,2))
        frame(1,1,0,bad=(0,3))
        config(0,identity,op=1);frame(1,1,0)
        for k in range(7):
            reset(k);frame(1,1,0);config(0,identity);frame(min(P,3),1,1,1,values=edge)
    return '\n'.join(rows)+'\n',counts
