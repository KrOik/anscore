"""SPDX-License-Identifier: Apache-2.0. Explicit finite deterministic vectors."""
import random
from reference_model import mean, classify
PROFILES=[(1,1,1,0),(5,31,8,0),(64,65536,32,0),(4,67,8,1)]
def label(p): return 'c%d_p%d_t%d_e%d'%tuple(p)
def vectors(C,P,T,EX):
    rng=random.Random(410061+C*991+P+EX)
    lines=[]
    counts=dict(frames=0,inputs=0,outputs=0,shape_errors=0,last_errors=0,inexact=0,clips=0,ii_checks=0)
    def frame(p,c,tag,mode=0,bad=None,pattern=None):
        err=1 if p<1 or p>P or c<1 or c>C else 0
        n=0 if err else p*c
        if bad is not None and not err: n=bad+1;err=2
        no=0 if err else 2 if EX else c
        lines.append('F '+' '.join(map(str,[p,c,tag,err,n,no,mode])))
        counts['frames']+=1;counts['inputs']+=n;counts['outputs']+=no
        if err:counts[{1:'shape_errors',2:'last_errors'}[err]]+=1
        if mode==1:counts['ii_checks']+=max(0,n-1)
        values=[[] for _ in range(c)] if not err else []
        for i in range(n):
            if pattern=='min': v=-128
            elif pattern=='max':v=127
            elif pattern=='ties':v=[-2,-1,0,1,2,3,-3,-4][(i//c+i%c)%8]
            elif pattern=='constant':v=((i%c)*7)%256-128
            else:v=rng.randrange(-128,128)
            last=int(i==p*c-1)
            if bad==i:last=1-last
            lines.append('S %d %d'%(v,last))
            if not err:values[i%c].append(v)
        if not err:
            result=[mean(v) for v in values]
            if EX:
                for v,clip in classify([v[0] for v in result]):
                    lines.append('O %d 0 0 %d'%(v,clip));counts['clips']+=clip
            else:
                for v,s,ine in result:
                    lines.append('O %d %d %d 0'%(v,s,ine));counts['inexact']+=ine
    channels=4 if EX else C
    frame(0,channels,0);frame(P+1,channels,1)
    if not EX:frame(1,0,2);frame(1,C+1,3);frame(131071,65535,4)
    frame(1,channels,5,1,pattern='min');frame(1,channels,6,1,pattern='max')
    frame(P,channels if EX else 1,7,1,pattern='min')
    frame(P,channels if EX else 1,8,1,pattern='max')
    if P>1:
        frame(2,channels,9,1,pattern='ties')
        frame(2,channels,10,0,pattern='constant')
    frame(min(P,3),channels,11,0,bad=0)
    frame(min(P,3),channels,12,0,bad=min(P,3)*channels-1)
    for j in range(24):frame(1+j%min(P,17),channels if EX else 1+j%C,(j+13)%2**T,j%2)
    return '\n'.join(lines)+'\n',counts
