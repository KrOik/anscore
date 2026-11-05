"""Independent coordinate-centering Fraction oracle. No RTL/assembler imports."""
from fractions import Fraction as F
import argparse,json,hashlib
from pathlib import Path
from functools import lru_cache
EXPONENTS=(3,6,9,9,18,12,18)
def hu(width,height,pixels):
    return centered(width,height,tuple(pixels))
@lru_cache(maxsize=256)
def centered(width,height,pixels):
    points=[(x,y) for y in range(height) for x in range(width) if pixels[y*width+x]]
    m=len(points)
    if not m:return 0,[]
    cx=F(sum(x for x,y in points),m);cy=F(sum(y for x,y in points),m)
    mu={}
    for degree in (2,3):
        for p in range(degree+1):
            q=degree-p
            mu[p,q]=sum(((F(x)-cx)**p*(F(y)-cy)**q for x,y in points),F(0))
    a,b,c=mu[2,0],mu[1,1],mu[0,2]
    d,e,f,g=mu[3,0],mu[2,1],mu[1,2],mu[0,3]
    p=d-3*f;q=3*e-g;u=d+f;v=e+g
    values=[(a+c)/m**2,((a-c)**2+4*b*b)/m**4,
            (p*p+q*q)/m**5,(u*u+v*v)/m**5,
            (p*u*(u*u-3*v*v)+q*v*(3*u*u-v*v))/m**10,
            ((a-c)*(u*u-v*v)+4*b*u*v)/m**7,
            (q*u*(u*u-3*v*v)-p*v*(3*u*u-v*v))/m**10]
    return m,values
def verify_case(c,q):
    w,h=q['WIDTH'],q['HEIGHT'];n=w*h;tokens=c['tokens'];complete=len(tokens)==n
    assert c['complete']==complete
    errors=0
    for k,(bit,sof,eol,bad,tag) in enumerate(tokens):
        assert bit in (0,1) and bad in (0,1) and 0<=tag<(1<<q['TAG_W'])
        if sof!=int(k==0):errors|=2
        if eol!=int(k%w==w-1):errors|=4
        if bad:errors|=8
    area=sum(t[0] for t in tokens)
    if complete and area==0:errors|=1
    assert (errors,area)==(c['errors'],c['area'])
    if not complete:assert not c['outputs'];return
    if errors:
        assert c['outputs']==[dict(num=0,den=1,contract_den=1,index=0,keep=0,last=1,errors=errors,tag=c['tag'],area=area)]
        return
    mass,values=hu(w,h,[t[0] for t in tokens]);assert mass==area
    assert len(c['outputs'])==7
    for k,(out,value,power) in enumerate(zip(c['outputs'],values,EXPONENTS)):
        assert out==dict(num=value.numerator,den=value.denominator,contract_den=mass**power,
                         index=k,keep=1,last=int(k==6),errors=0,tag=c['tag'],area=mass)
        assert (value*mass**power).denominator==1
def verify_plan(path):
    path=Path(path);plan=json.loads(path.read_text());count=0;anchors={}
    for q in plan['profiles']:
        for kind in ('main','resets'):
            for g in q[kind]:
                data=(path.parent/g['json']).read_bytes();assert hashlib.sha256(data).hexdigest()==g['json_sha256']
                assert hashlib.sha256((path.parent/g['text']).read_bytes()).hexdigest()==g['text_sha256']
                fixture=json.loads(data);cases=fixture['frames'] if kind=='main' else [fixture['owner'],fixture['fresh']]
                for c in cases:verify_case(c,q);count+=1
                if kind=='main':
                    for c in cases:
                        if c['label'] in ('skew','mirror','rot90','translate') and c['errors']==0:anchors[q['name'],c['label']]=[F(o['num'],o['den']) for o in c['outputs']]
    # These geometries contain the transformed point set without clipping or wrap.
    for profile in ('p4','p5'):
        base=anchors[profile,'skew']
        assert anchors[profile,'rot90']==base and anchors[profile,'translate']==base
        mirrored=anchors[profile,'mirror'];assert mirrored[:6]==base[:6] and mirrored[6]==-base[6]
        assert base[6]!=0,'asymmetric reflection anchor must exercise H7 sign'
    print('PASS fixture_oracles cases='+str(count)+' fixtures='+str(plan['totals']['simulations']))
if __name__=='__main__':
    a=argparse.ArgumentParser();a.add_argument('--verify-plan',required=True);args=a.parse_args();verify_plan(args.verify_plan)
