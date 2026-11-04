#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Original exact circle oracle and frozen finite matrix; no online dependency."""
from collections import Counter
from fractions import Fraction as F
import hashlib
import itertools
import json
import os
from pathlib import Path
import random
import re
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parent
BASELINE='eb16eee7848694a1a1cd50e567b5742352751c93'
PROFILES=[(2,1,1),(2,4,3),(4,8,8),(8,8,8),(12,8,32)]
INVALID=[('COORD_W',1),('COORD_W',13),('MAX_POINTS',0),('MAX_POINTS',9),('TAG_W',0),('TAG_W',33)]
SOURCES=['.gitattributes','README.md','SOURCES.md','TEST_PLAN.json','files.f','example/files.f','example/feature_circle.sv',
    'rtl/minimum_enclosing_circle.sv','sim/tb_minimum_enclosing_circle.sv','run_tests.py']
sha=lambda b:hashlib.sha256(b).hexdigest()


def contains(c,p):
    return c is not None and (p[0]-c[0])**2+(p[1]-c[1])**2<=c[2]


def boundary(points):
    """Exact Cartesian center from Gaussian elimination of perpendicular bisectors."""
    if not points:return None
    if len(points)==1:return F(points[0][0]),F(points[0][1]),F(0)
    a,b=points[:2]
    if len(points)==2:
        x=F(a[0]+b[0],2);y=F(a[1]+b[1],2)
        return x,y,(x-a[0])**2+(y-a[1])**2
    c=points[2]
    mat=[[F(2*(p[0]-a[0])),F(2*(p[1]-a[1])),F(p[0]**2+p[1]**2-a[0]**2-a[1]**2)] for p in [b,c]]
    if mat[0][0]*mat[1][1]==mat[1][0]*mat[0][1]:return None
    for col in range(2):
        pivot=next(i for i in range(col,2) if mat[i][col])
        mat[col],mat[pivot]=mat[pivot],mat[col]
        q=mat[col][col];mat[col]=[v/q for v in mat[col]]
        for row in range(2):
            if row!=col:
                q=mat[row][col];mat[row]=[u-q*v for u,v in zip(mat[row],mat[col])]
    x,y=mat[0][2],mat[1][2]
    return x,y,(x-a[0])**2+(y-a[1])**2


def minimum_circle(points):
    """Recursive Welzl boundary-set solver, independent of hardware candidate scan."""
    p=list(points);random.Random(0x434952434c45).shuffle(p)
    def rec(n,support):
        if n==0 or len(support)==3:
            c=boundary(support)
            if c is None and support:
                options=[boundary(pair) for pair in itertools.combinations(support,2)]
                c=min((v for v in options if all(contains(v,q) for q in support)),key=lambda v:v[2])
            return c
        c=rec(n-1,support)
        return c if contains(c,p[n-1]) else rec(n-1,support+[p[n-1]])
    c=rec(len(p),[]);assert all(contains(c,q) for q in points)
    return c


def cross(a,b,c):return (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])


def scan_certificate(points,w):
    """Fixed work accounting, certified against independent recursive optimum."""
    optimum=minimum_circle(points);n=len(points);mw=3*w+5
    candidates=ops=checks=angle_checks=0;stats=Counter()
    sets=[(0,)]+list(itertools.combinations(range(n),2))+list(itertools.combinations(range(n),3))
    for ids in sets:
        candidates+=1;k=len(ids);support=[points[i] for i in ids]
        if k==2:ops+=2
        if k==3:
            ops+=6;angle_checks+=1;a,b,c=support
            u=(b[0]-a[0],b[1]-a[1]);v=(c[0]-a[0],c[1]-a[1]);nu=sum(x*x for x in u);nv=sum(x*x for x in v);dot=sum(x*y for x,y in zip(u,v))
            if dot<0 or dot>nu or dot>nv:stats['obtuse_rejects']+=1;continue
            ops+=2
            if cross(a,b,c)==0:stats['collinear_rejects']+=1;continue
            ops+=8
            stats['negative_orientation_candidates']+=cross(a,b,c)<0
        circle=boundary(support)
        assert circle is not None
        if k==3:
            # Center in the closed triangle is an independent optimality certificate.
            signs=[cross(support[z],support[(z+1)%3],circle[:2]) for z in range(3)]
            assert all(v>=0 for v in signs) or all(v<=0 for v in signs)
        inside=True
        for point in points:
            checks+=1
            if not contains(circle,point):inside=False;break
        if not inside:stats['outside_rejects']+=1;continue
        assert circle==optimum
        den=1 if k==1 else (2 if k==2 else abs(2*cross(*support)))
        values=(circle[0]*den,circle[1]*den,circle[2]*den*den)
        assert all(v.denominator==1 for v in values)
        latency=1+5*candidates+ops*(mw+2)+angle_checks+checks*(3+4*(mw+2))+candidates-1
        stats['support_'+str(k)]+=1;stats['fractional_center']+=circle[0].denominator>1 or circle[1].denominator>1
        stats['fractional_radius_sq']+=circle[2].denominator>1
        return (*map(int,values[:2]),den,int(values[2]),k,*(list(ids)+[0]*(3-k))),dict(candidates=candidates,point_checks=checks,multiply_steps=(ops+4*checks)*mw,latency=latency),stats
    raise AssertionError('Finite support theorem violated')


def pack(fields):
    word=0
    for value,width in fields:
        assert 0<=value<1<<width,(value,width);word=(word<<width)|value
    return word


def fixtures(w,m,t):
    lo=-(1<<(w-1));hi=(1<<(w-1))-1;rng=random.Random(0x4d454300+w*13+m+t)
    acute=[(-1,-1),(1,-1),(0,1)];obtuse=[(-2,-1),(1,-1),(0,0)]
    cases=[[],[(lo,lo)],[(hi,hi)],[(lo,hi)],[(0,0)]*m,[(lo,lo),(hi,hi)],[(hi,hi),(lo,lo)],
        [(lo,hi),(hi,lo)],[(lo,0),(hi,0),(0,0)],[(lo,lo)]*(m+2)]
    if m>=3:
        cases+=list(map(list,itertools.permutations(acute)))+list(map(list,itertools.permutations(obtuse)))
        cases += [[(-1,-1),(1,-1),(1,1),(-1,1)],[(lo,lo),(hi,lo),(hi,hi),(lo,hi)],
            acute+[acute[0]]*(m-3),[(lo,lo),(hi,lo),(lo,hi)]+[(0,0)]*(m-3),
            [acute[0],acute[0],acute[1],acute[2]],obtuse+[(0,1)]]
    for _ in range(12):cases.append([(rng.randint(lo,hi),rng.randint(lo,hi)) for k in range(rng.randrange(1,m+1))])
    if (w,m)==(2,4):
        for grid in [[(-1,-1),(-1,1),(1,-1),(1,1)],acute]:cases += list(map(list,itertools.product(grid,repeat=3)))
    if (w,m)==(4,8):
        grid=[(x,y) for y in [-2,-1,0,1] for x in [-1,1]]
        cases += [[point for k,point in enumerate(grid) if mask>>k&1] for mask in range(256)]
    iw=max(1,(m-1).bit_length());cw=max(1,m.bit_length());mw=3*w+5;rw=2*mw
    lines=[];records=[];coverage=Counter();totals=Counter(frames=len(cases));frameplan=[]
    for fi,points in enumerate(cases):
        count=min(len(points),m);status=2 if len(points)>m else int(not points)
        tag=(1<<t)-1 if fi%9==0 else (0 if fi%9==1 else rng.getrandbits(t))
        if status:values=(0,0,0,0,0,0,0,0);work=dict(candidates=0,point_checks=0,multiply_steps=0,latency=1)
        else:values,work,stats=scan_certificate(points,w);coverage.update(stats)
        xn,yn,den,rnum,support,i,j,k=values
        word=pack([(status,2),(support,2),(count,cw),(tag,t),(i,iw),(j,iw),(k,iw),
            (xn&((1<<mw)-1),mw),(yn&((1<<mw)-1),mw),(den,mw),(rnum,rw)])
        raw=[]
        if fi%2==0:raw.append((0,lo,hi))
        for index,point in enumerate(points):
            raw.append((1,*point))
            if index%3==1:raw.append((0,hi,lo))
        if not raw or fi%5==0:raw.append((0,hi,lo))
        lines.append(f'{len(raw)} {word:x} {work["latency"]} {work["candidates"]} {work["point_checks"]} {work["multiply_steps"]}\n')
        for bi,(keep,x,y) in enumerate(raw):
            lines.append(f'{keep} {x} {y} {int(bi==len(raw)-1)} {tag if bi==0 else rng.getrandbits(t):x}\n')
            totals['ii1_checks']+=bi>0 and not(fi%3==0 and bi%2==1)
        totals.update(dict(beats=len(raw),outputs=1,candidates=work['candidates'],point_checks=work['point_checks'],multiply_steps=work['multiply_steps']))
        coverage['status_'+str(status)]+=1;coverage['valid']+=status==0
        coverage['zero_radius']+=status==0 and rnum==0
        frameplan.append(dict(beats=len(raw),status=status,**work));records.append((word,work['latency']))
    totals['reset_probes']=20 if m==1 else 22;totals['queued_checks']=1
    assert all(coverage['status_'+str(i)] for i in [0,1,2])
    if m>=3:assert all(coverage[k] for k in ['support_1','support_2','support_3','fractional_center','fractional_radius_sq','negative_orientation_candidates','obtuse_rejects','collinear_rejects'])
    return ''.join(lines),records,dict(coverage),dict(totals),frameplan


def main():
    plan=json.loads((ROOT/'TEST_PLAN.json').read_text());plans=[]
    for profile in PROFILES:plans.append((*profile,*fixtures(*profile)))
    frozen=[dict(COORD_W=w,MAX_POINTS=m,TAG_W=t,fixture_sha256=sha(data.encode()),**totals) for w,m,t,data,rec,cov,totals,fp in plans]
    assert frozen==plan['frozen_fixture_plan']
    report=dict(baseline=BASELINE,status=['NOT_RUN','HW_UNVERIFIED'],matrix_status='NOT_RUN',checks=[],profiles=[],
        frozen_fixture_plan=frozen,fixture_plan_sha256=sha(json.dumps(frozen,sort_keys=True).encode()),dependency_sha256={},
        qualified_commands=19,not_run=['synthesis','PnR','STA','hardware','expanded_regression'])
    path=ROOT/'verification.json'
    if path.is_file():
        old=json.loads(path.read_text())
        if old.get('matrix_status')=='INCOMPLETE_TIMEOUT':raise RuntimeError('Terminal prior timeout: no rerun')
        report['prior_failed_attempts']=old.get('prior_failed_attempts',[])
        if 'FAILED_OR_NOT_RUN' in old.get('status',[]):report['prior_failed_attempts'].append({k:v for k,v in old.items() if k!='prior_failed_attempts'})
    def save():path.write_bytes((json.dumps(report,indent=2)+'\n').encode())
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy();temporary=''
    env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    exe={k:str(suite/'bin'/f'{k}.exe') for k in ['iverilog','vvp']}
    def run(args,reject=False,version=False):
        try:r=subprocess.run([exe[args[0]],*args[1:]],cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
        except subprocess.TimeoutExpired as error:
            decode=lambda x:x.decode(errors='replace') if isinstance(x,bytes) else (x or '')
            report['checks'].append(dict(command=args,status='TIMEOUT',exit_code=None,stdout=decode(error.stdout),stderr=decode(error.stderr),timeout_seconds=20));report['matrix_status']='INCOMPLETE_TIMEOUT';raise
        okay=(r.returncode>0 and 'minimum_enclosing_circle_invalid_parameters' in r.stderr) if reject else r.returncode==0 and not r.stderr
        if args[0]=='iverilog' and not reject and not version:okay=okay and not r.stdout
        report['checks'].append(dict(command=args,status='PASS' if okay else 'FAIL',exit_code=r.returncode,stdout=r.stdout.strip(),stderr=r.stderr.strip(),timeout_seconds=20))
        if not okay:raise RuntimeError(r.stdout+r.stderr)
        return r.stdout.strip()
    try:
        for name in SOURCES:
            b=(ROOT/name).read_bytes();b.decode('utf-8','strict');assert b'\r' not in b and b.endswith(b'\n') and not b.startswith(b'\xef\xbb\xbf'),name
        report['source_sha256']={n:sha((ROOT/n).read_bytes()) for n in SOURCES};save()
        run(['iverilog','-V'],version=True)
        for top,manifest in [('minimum_enclosing_circle','files.f'),('feature_circle','example/files.f')]:run(['iverilog','-g2012','-Wall','-tnull','-s',top,'-f',manifest])
        with tempfile.TemporaryDirectory(prefix='anscore_mec_') as temporary:
            folder=Path(temporary)
            for w,m,t,data,records,coverage,totals,frameplan in plans:
                (folder/'cases.txt').write_bytes(data.encode());image=folder/'unit.vvp'
                run(['iverilog','-g2012','-Wall','-s','tb_minimum_enclosing_circle',f'-Ptb_minimum_enclosing_circle.COORD_W={w}',
                    f'-Ptb_minimum_enclosing_circle.MAX_POINTS={m}',f'-Ptb_minimum_enclosing_circle.TAG_W={t}',
                    f'-Ptb_minimum_enclosing_circle.FRAMES={len(records)}','-o',str(image),'-f','files.f','sim/tb_minimum_enclosing_circle.sv'])
                output=run(['vvp',str(image),f'+CASES={(folder/"cases.txt").as_posix()}',f'+TRACE={(folder/"trace.txt").as_posix()}'])
                marker=re.search(r'^PASS (.+)$',output,re.M);assert marker
                observed={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',marker.group(1))}
                for name,value in totals.items():assert observed[name]==value,(name,observed,totals)
                assert observed['latency_checks']==len(records) and observed['fresh_checks']==observed['reset_probes']
                assert observed['read_checks']==3*totals['candidates']+totals['point_checks']
                assert observed['product_checks']*(3*w+5)==totals['multiply_steps']
                assert observed['state_mask']==(48127 if m==1 else 65535)
                assert observed['held_cycles']>0 and observed['source_stalls']==13
                trace=(folder/'trace.txt').read_bytes();assert [(int(x.split()[0],16),int(x.split()[1])) for x in trace.decode().splitlines()]==records
                report['profiles'].append(dict(COORD_W=w,MAX_POINTS=m,TAG_W=t,coverage=coverage,planned=totals,frame_plan=frameplan,
                    observed=observed,result=output,trace_sha256=sha(trace)));print(output,flush=True)
            for name,value in INVALID:run(['iverilog','-g2012','-tnull','-s','minimum_enclosing_circle',f'-Pminimum_enclosing_circle.{name}={value}','-f','files.f'],reject=True)
        assert len(report['checks'])==19
        report['status']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'];report['matrix_status']='PASS'
    except subprocess.TimeoutExpired as error:report['status']=['NOT_RUN','HW_UNVERIFIED'];report['detail']=str(error)+'; terminal timeout, no retry';raise
    except (AssertionError,RuntimeError,OSError) as error:report['status']=['FAILED_OR_NOT_RUN','HW_UNVERIFIED'];report['detail']=repr(error);raise
    finally:
        if temporary:
            for c in report['checks']:c['command']=[v.replace(temporary,'<temporary>').replace(temporary.replace('\\','/'),'<temporary>') for v in c['command']]
        report['source_sha256']={n:sha((ROOT/n).read_bytes()) for n in SOURCES if (ROOT/n).is_file()}
        report['license_sha256']={n:sha((ROOT.parents[2]/n).read_bytes()) for n in ['LICENSE','NOTICE']};save()


if __name__=='__main__':main()
