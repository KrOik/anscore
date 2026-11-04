#!/usr/bin/env python3
"""Frozen finite qualification. External implementations are never executed."""
from __future__ import annotations
import argparse
from collections import Counter
from fractions import Fraction as F
from functools import lru_cache
import hashlib
import itertools
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

ROOT=Path(__file__).resolve().parent
MARKER='polygon_triangulation_invalid_parameters__see_README'

def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def write_json(p,x): p.write_text(json.dumps(x,indent=2)+'\n',encoding='utf-8',newline='\n')
def cross(a,b,c): return (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])
def area(p): return sum(a[0]*b[1]-a[1]*b[0] for a,b in zip(p,p[1:]+p[:1]))

def intersection(a,b,c,d):
    """Exact parametric line intersection; return a set of points or overlap."""
    r=(b[0]-a[0],b[1]-a[1]);s=(d[0]-c[0],d[1]-c[1])
    den=r[0]*s[1]-r[1]*s[0]
    if den:
        q=(c[0]-a[0],c[1]-a[1])
        t=F(q[0]*s[1]-q[1]*s[0],den);u=F(q[0]*r[1]-q[1]*r[0],den)
        return {(F(a[0])+t*r[0],F(a[1])+t*r[1])} if 0<=t<=1 and 0<=u<=1 else set()
    if cross(a,b,c): return set()
    axis=0 if a[0]!=b[0] else 1
    lo=max(min(a[axis],b[axis]),min(c[axis],d[axis]))
    hi=min(max(a[axis],b[axis]),max(c[axis],d[axis]))
    if lo>hi:return set()
    if lo<hi:return 'overlap'
    return {tuple(map(F,p)) for p in [a,b,c,d] if p[axis]==lo}

def valid_polygon(p):
    n=len(p)
    if n<3 or len(set(p))!=n or area(p)==0:return False
    for i in range(n):
        for j in range(i+1,n):
            hit=intersection(p[i],p[(i+1)%n],p[j],p[(j+1)%n])
            adjacent=j==i+1 or (i==0 and j==n-1)
            if adjacent:
                common=p[j] if j==i+1 else p[0]
                if hit!={tuple(map(F,common))}:return False
            elif hit:return False
    return True

def inside(p,q):
    """Strict winding-number test, independently using rational ray intersections."""
    winding=0
    for a,b in zip(p,p[1:]+p[:1]):
        if cross(a,b,q)==0 and min(a[0],b[0])<=q[0]<=max(a[0],b[0]) and min(a[1],b[1])<=q[1]<=max(a[1],b[1]):return False
        if a[1]<=q[1]<b[1] or b[1]<=q[1]<a[1]:
            x=F(a[0])+F(q[1]-a[1],b[1]-a[1])*(b[0]-a[0])
            if x>q[0]:winding+=1 if b[1]>a[1] else -1
    return winding!=0

def visible(p,i,j):
    n=len(p)
    if (i-j)%n in [1,n-1]:return True
    a,b=p[i],p[j]
    for k in range(n):
        hit=intersection(a,b,p[k],p[(k+1)%n])
        if not hit:continue
        if hit=='overlap':return False
        allowed={tuple(map(F,p[x])) for x in [i,j] if x in [k,(k+1)%n]}
        if not hit<=allowed:return False
    return inside(p,((F(a[0])+b[0])/2,(F(a[1])+b[1])/2))

def interval_meshes(p,enumerate_all=False):
    """Independent global interval triangulation, rather than ear removal."""
    n=len(p);sign=1 if area(p)>0 else -1
    diagonal={(i,j):visible(p,i,j) for i in range(n) for j in range(i+1,n)}
    def edge(i,j):return diagonal[tuple(sorted((i,j)))]
    @lru_cache(None)
    def solve(i,j):
        if j-i<2:return ((),)
        result=[]
        for k in range(i+1,j):
            if cross(p[i],p[k],p[j])*sign<=0 or not all([edge(i,k),edge(k,j),edge(i,j)]):continue
            q=((F(p[i][0])+p[k][0]+p[j][0])/3,(F(p[i][1])+p[k][1]+p[j][1])/3)
            if not inside(p,q):continue
            for left in solve(i,k):
                for right in solve(k,j):
                    result.append(left+right+((i,k,j),))
                    if not enumerate_all:return tuple(result)
        return tuple(result)
    return solve(0,n-1)

def clip_triangle(subject,clip):
    poly=[tuple(map(F,p)) for p in subject]
    for a,b in zip(clip,clip[1:]+clip[:1]):
        old=poly;poly=[]
        if not old:break
        for s,e in zip(old,old[1:]+old[:1]):
            cs,ce=cross(a,b,s),cross(a,b,e)
            if (cs>=0)!=(ce>=0):
                t=cs/(cs-ce);poly.append((s[0]+t*(e[0]-s[0]),s[1]+t*(e[1]-s[1])))
            if ce>=0:poly.append(e)
    return abs(area(poly)) if poly else 0

def certify(p,triangles):
    n=len(p);assert len(triangles)==n-2
    faces=[tuple(p[i] for i in tri) for tri in triangles]
    assert all(len(set(t))==3 and all(0<=i<n for i in t) for t in triangles)
    assert all(cross(*t)>0 for t in faces)
    assert sum(cross(*t) for t in faces)==abs(area(p))
    edges=Counter((a,b) for t in triangles for a,b in zip(t,t[1:]+t[:1]))
    boundary=Counter((i,(i+1)%n) if area(p)>0 else ((i+1)%n,i) for i in range(n))
    for (a,b),v in list(edges.items()):
        if a>b:continue
        k=min(v,edges[(b,a)]);edges[(a,b)]-=k;edges[(b,a)]-=k
    assert +edges==boundary
    for t in faces:
        assert inside(p,((F(t[0][0])+t[1][0]+t[2][0])/3,(F(t[0][1])+t[1][1]+t[2][1])/3))
    for i,t in enumerate(faces):
        for u in faces[i+1:]:assert clip_triangle(list(t),list(u))==0
    if n<=4:
        alternatives=interval_meshes(p,True)
        normalized={frozenset(frozenset(t) for t in mesh) for mesh in alternatives}
        assert frozenset(frozenset(t) for t in triangles) in normalized

@lru_cache(None)
def oracle(p):
    if not valid_polygon(p):return None
    assert interval_meshes(p), 'independent interval DP must find a complete mesh'
    # Global Fraction diagonal visibility defines admissible boundary faces.
    # It never uses the RTL's closed-triangle blocker or cross-product schedule.
    remaining=list(range(len(p)));result=[];sign=1 if area(p)>0 else -1
    while len(remaining)>3:
        q=[p[i] for i in remaining]
        candidates=[]
        for k,i in enumerate(remaining):
            before=(k-1)%len(q);after=(k+1)%len(q)
            if cross(q[before],q[k],q[after])*sign>0 and visible(q,before,after):candidates.append((i,k))
        assert candidates
        _,k=min(candidates)
        tri=(remaining[k-1],remaining[k],remaining[(k+1)%len(remaining)])
        result.append(tri if sign>0 else (tri[0],tri[2],tri[1]));remaining.pop(k)
    tri=tuple(remaining);result.append(tri if sign>0 else (tri[0],tri[2],tri[1]))
    certify(p,result)
    return result

def signed_tag(v,t):
    v&=(1<<t)-1
    return v-(1<<32) if v>=(1<<31) else v

def tokens(p,t,index=0):
    result=[]
    first=[0,(1<<t)-1,1<<(t-1),index*37+3][index%4]
    for i,(x,y) in enumerate(p):result.append((x,y,1,int(i==len(p)-1),0,signed_tag(first if i==0 else i*131+11,t)))
    return result

def fresh_polygon(c,n):
    if n==3:return [(0,0),(1,0),(0,1)]
    if n==4:return [(-1,-1),(1,-1),(1,1),(-1,1)]
    half=(n-2)//2
    return [(x,x*x) for x in range(-half,half+1)]+[(0,(1<<(c-1))-1)]

def controls(c,n,t):
    lo,hi=-(1<<(c-1)),(1<<(c-1))-1
    tri=[(-1,-1),(1,-1),(-1,1)]
    raw=[[],[(0,0)],[(0,0),(1,0)],[(0,0),(1,0),(0,0)],
         [(-1,0),(0,0),(1,0)],[(0,0),(1,0),(-1,0)],tri+tri[:1],tri,tri,
         [(0,0)]*(n+1),[(0,0)]*(n+1),tri,
         [(lo,lo),(hi,lo),(lo,hi)],[(lo,hi),(hi,lo),(lo,lo)],
         [(-1,-1),(1,1),(-1,1),(1,-1)] if n>3 else [(0,0)]*3,tri]
    result=[]
    for i,p in enumerate(raw):
        q=tokens(p,t,i)
        if not q:q=[(0,0,0,1,0,signed_tag((1<<t)-1,t))]
        if i==7:q=[(0,0,0,1,1,signed_tag(1<<(t-1),t))]
        if i in [8,10]:q=[(*x[:4],int(k==0),x[5]) for k,x in enumerate(q)]
        if i==11:
            q=[(lo,hi,0,0,0,signed_tag((1<<t)-1,t))]+[(*x[:3],0,x[4],x[5]) for x in q]+[(hi,lo,0,1,0,0)]
        if i==15:q=[(0,0,0,0,0,signed_tag(1<<(t-1),t))]+q
        result.append(q)
    assert len(result)==16
    return result

def comb(n):
    if n==8:return [(0,0),(6,0),(6,6),(4,6),(4,2),(2,2),(2,6),(0,6)]
    teeth=(n-4)//4;width=4*teeth+2
    return [(0,0),(width,0),(width,10)]+[p for x in range(4*teeth-2,0,-4) for p in [(x+1,10),(x+1,3),(x,3),(x,10)]]+[(0,10)]

def collinear_rectangle(c,n,extreme=False):
    half=n//2;lo=-(1<<(c-1)) if extreme else 0
    hi=(1<<(c-1))-1 if extreme else half-1
    xx=[lo+(hi-lo)*i//(half-1) for i in range(half)]
    y0,y1=(lo,hi) if extreme else (0,2)
    return [(x,y0) for x in xx]+[(xx[-1],y1)]+[(x,y1) for x in reversed(xx[:-1])]

def shapes(c,n):
    q=fresh_polygon(c,n);r=collinear_rectangle(c,n)
    arrow=[(0,0),(4,0),(4,4),(2,1),(0,4)]
    concave=[(-2,-2),(2,-2),(-1,-1),(-2,2)]
    return [q,list(reversed(q)),r,list(reversed(r)),arrow,list(reversed(arrow)),
      concave[2:]+concave[:2],[(-2,-2),(2,-2),(-3,3),(-2,1)],
      [(-3,-2),(0,-2),(2,-3),(-3,3)],[(0,-2),(2,-2),(-2,2),(-2,-2)],
      [(-1,-1),(1,1),(-1,1),(1,-1)],[(0,0),(4,0),(4,4),(2,0),(0,4)],
      [(0,0),(3,0),(1,0),(0,3)],[(0,0),(3,0),(3,3),(0,0),(0,3)],
      [(0,0),(3,0),(3,0),(0,3)],comb(n)]

def bound(n):
    if n<3:return 2
    return 9*n*(n-1)//2+33*n*(n-3)//2+32*n-1+sum(20*k*k-36*k-2 for k in range(4,n+1))

def evaluate(q,n):
    p=[(x,y) for x,y,keep,*_ in q if keep];error=int(len(p)>n)|2*int(any(x[4] for x in q))
    retained=p[:n];mesh=None if error else oracle(tuple(retained))
    if not error and mesh is None:error=4
    out=[(0,)*9] if error else [tuple(tri)+tuple(v for i in tri for v in retained[i]) for tri in mesh]
    return dict(inputs=q,vertices=0 if error else len(p),error=error,tag=q[0][5],outputs=out,
                bound=2 if error&3 or len(p)<3 else bound(len(p)))

def owner(c,n,t,target):
    base=fresh_polygon(c,n)
    if target==0:return []
    if target==1:return [(0,0,1,0,0,17&((1<<t)-1))]
    if target==2:return [(0,0,0,0,0,17&((1<<t)-1))]
    if target==3:return [(0,0,1,0,0,17&((1<<t)-1))]*(n+1)
    if target==6:base=[(0,0),(1,0),(-1,0)]
    if target==12:base=list(reversed(base))
    if target==15:base=[(-1,-1),(-2,2),(-2,-2),(2,-2)]
    if target==16:base=[(-2,-2),(2,-2),(-3,3),(-2,1)]
    if target==17:base=[(-3,-2),(0,-2),(2,-3),(-3,3)]
    if target==18:base=[(-2,-2),(2,-2),(-1,-1),(-2,2)]
    if target==38:base=[(0,-2),(2,-2),(-2,2),(-2,-2)]
    if target==37:base=[(-1,-1),(1,1),(-1,1),(1,-1)]
    if target in [28,39]:base=[(0,0)]*(n+1)
    if target==30:return [(0,0,0,1,0,0)]
    q=tokens(base,t,target)
    if target in [29,39]:q=[(*x[:4],int(i==0),x[5]) for i,x in enumerate(q)]
    return q

def fixture(path,frames):
    rows=[]
    for target,own,e in frames:
        rows.append(' '.join(map(str,(target,len(own),len(e['inputs']),len(e['outputs']),e['vertices'],e['error'],e['tag'],e['bound']))))
        rows+=[' '.join(map(str,q)) for q in own+e['inputs']]
        rows+=[' '.join(map(str,q)) for q in e['outputs']]
    path.write_text('\n'.join(rows)+'\n',encoding='utf-8',newline='\n')
    return dict(path=path.relative_to(ROOT).as_posix(),sha256=sha(path),frames=len(frames),
                inputs=sum(len(e['inputs']) for _,_,e in frames),outputs=sum(len(e['outputs']) for _,_,e in frames),
                targets=[target for target,_,_ in frames if target>=0],
                statuses=dict(Counter(e['error'] for _,_,e in frames)))

def sources():
    return {p.relative_to(ROOT).as_posix():sha(p) for p in sorted(ROOT.rglob('*')) if p.is_file()
            and p.name not in ['TEST_PLAN.json','verification.json'] and 'failure_archive' not in p.relative_to(ROOT).parts}

def freeze():
    assert not (ROOT/'TEST_PLAN.json').exists()
    matrix=json.loads((ROOT/'MATRIX.json').read_text(encoding='utf-8'))
    profiles=[];grid=list(itertools.product(matrix['small_grid'],repeat=2))
    fixtures=ROOT/'sim/fixtures';fixtures.mkdir(parents=True,exist_ok=True)
    for p0 in matrix['profiles']:
        p=dict(p0);c,n,t=p['c'],p['n'],p['t'];control=controls(c,n,t);main={}
        if n==3:main['all']=[tokens(list(x),t,i) for i,x in enumerate(itertools.product(grid,repeat=3))]+control
        elif n==4:
            raw=[tokens(list(x),t,i) for i,x in enumerate(itertools.permutations(grid,4))]
            main.update({f'g{k}':raw[k*756:(k+1)*756] for k in range(4)});main['control']=control
        elif n==32:
            good=[fresh_polygon(c,n),list(reversed(fresh_polygon(c,n))),comb(n),collinear_rectangle(c,n,True)]
            for k,points in enumerate(good):
                assert len(points)==n and valid_polygon(points)
                bad=list(points)
                if k==0:bad[1],bad[n//2]=bad[n//2],bad[1]
                elif k in [1,2]:bad[n//3]=bad[0]
                else:bad[1],bad[2]=bad[2],bad[1]
                assert not valid_polygon(bad)
                main[f'g{k}']=[tokens(points,t,k),tokens(bad,t,k+11)]
            main['control']=control
        else:main['all']=control+[tokens(x,t,i+16) for i,x in enumerate(shapes(c,n))]
        p['main_fixtures']=[]
        for group,count in p['main']:
            assert len(main[group])==count
            frames=[(-1,[],evaluate(q,n)) for q in main[group]]
            p['main_fixtures'].append(fixture(fixtures/f"{p['name']}_main_{group}.txt",frames))
        selected=[i for i in range(40) if n>3 or i not in matrix['n3_unreachable_reset_ids']]
        p['reset_fixtures']=[]
        for g in range(0,len(selected),matrix['reset_group_size']):
            frames=[]
            for target in selected[g:g+4]:
                q=fresh_polygon(c,n)
                if target%2:q=list(reversed(q))
                fresh=tokens(q,t,target+73);fresh[0]=(*fresh[0][:5],signed_tag(target+73,t))
                e=evaluate(fresh,n);assert not e['error'] and e['vertices']==n
                frames.append((target,owner(c,n,t,target),e))
            p['reset_fixtures'].append(fixture(fixtures/f"{p['name']}_reset_{g//4:02d}.txt",frames))
        p['first_valid_bound']=bound(n)
        p['scalar_bits']=22*c+5*math.ceil(math.log2(n+1))+9*math.ceil(math.log2(n))+t+57
        iw=math.ceil(math.log2(n));p['ram_bits']=2*c*n+n*iw+3*(n-2)*iw
        profiles.append(p)
    children=['version','core_syntax','example_syntax']
    for p in profiles:
        children+=[p['name']+'_compile']
        children += [Path(f['path']).stem+'_simulate' for f in p['main_fixtures']+p['reset_fixtures']]
    children += ['reject_'+q[0] for q in matrix['negative_parameters']]
    plan=dict(matrix_sha256=sha(ROOT/'MATRIX.json'),frozen_before_first_hdl=True,timeout_seconds=20,
              profiles=profiles,children=children,source_sha256=sources(),not_run=matrix['not_run'])
    write_json(ROOT/'TEST_PLAN.json',plan)
    print('FROZEN',sha(ROOT/'TEST_PLAN.json'),'children',len(children),
          'main',sum(f['frames'] for p in profiles for f in p['main_fixtures']),
          'reset',sum(f['frames'] for p in profiles for f in p['reset_fixtures']))
    print([(p['name'],p['scalar_bits'],p['ram_bits'],p['first_valid_bound']) for p in profiles])

def run():
    plan=json.loads((ROOT/'TEST_PLAN.json').read_text(encoding='utf-8'))
    matrix=json.loads((ROOT/'MATRIX.json').read_text(encoding='utf-8'))
    assert plan['matrix_sha256']==sha(ROOT/'MATRIX.json') and plan['source_sha256']==sources()
    assert not (ROOT/'verification.json').exists(),'never replace qualification receipt'
    toolbin=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite/bin'
    iv,vvp=toolbin/'iverilog.exe',toolbin/'vvp.exe';assert iv.is_file() and vvp.is_file()
    env=dict(os.environ);env['PATH']=str(toolbin)+os.pathsep+str(toolbin.parent/'lib')+os.pathsep+env.get('PATH','')
    receipt=dict(status='IN_PROGRESS',hardware='HW_UNVERIFIED',plan_sha256=sha(ROOT/'TEST_PLAN.json'),
                 source_sha256=sources(),records=[],results=[],terminal_timeout=False)
    def save():write_json(ROOT/'verification.json',receipt)
    def child(name,argv,reject=False):
        assert name==plan['children'][len(receipt['records'])]
        record=dict(name=name,argv=list(map(str,argv)),timeout_seconds=20);start=time.monotonic()
        try:
            r=subprocess.run(record['argv'],cwd=ROOT,env=env,capture_output=True,text=True,
                             encoding='utf-8',errors='replace',timeout=20)
            good=(r.returncode!=0 and MARKER in r.stdout+r.stderr) if reject else r.returncode==0
            record.update(exit_code=r.returncode,stdout=r.stdout,stderr=r.stderr,status='PASS' if good else 'FAIL')
        except subprocess.TimeoutExpired as exc:
            decode=lambda v:v.decode('utf-8','replace') if isinstance(v,bytes) else v or ''
            record.update(exit_code=None,stdout=decode(exc.stdout),stderr=decode(exc.stderr),status='TIMEOUT')
            receipt['terminal_timeout']=True
        record['elapsed_seconds']=round(time.monotonic()-start,3);receipt['records'].append(record);save()
        print(name,record['status'],record['elapsed_seconds'],flush=True)
        if record['status']!='PASS':raise RuntimeError(name+' '+record['status'])
        return record
    temp_root=Path(tempfile.gettempdir()).resolve();tmp=Path(tempfile.mkdtemp(prefix='anscore_b22_mesh_',dir=temp_root)).resolve()
    assert tmp.parent==temp_root and tmp.name.startswith('anscore_b22_mesh_')
    try:
        child('version',[iv,'-V'])
        child('core_syntax',[iv,'-g2012','-Wall','-tnull','-s','polygon_triangulation','-f','files.f'])
        child('example_syntax',[iv,'-g2012','-Wall','-tnull','-s','polygon_mesh16','-f','example/files.f'])
        for p in plan['profiles']:
            binary=tmp/(p['name']+'.vvp')
            argv=[iv,'-g2012','-Wall','-s','tb_polygon_triangulation','-o',binary]
            for param,key in [('COORD_W','c'),('MAX_VERTICES','n'),('TAG_W','t')]:argv+=['-P',f"tb_polygon_triangulation.{param}={p[key]}"]
            argv+=['rtl/polygon_triangulation.sv','sim/tb_polygon_triangulation.sv']
            child(p['name']+'_compile',argv)
            for kind,key in [('main','main_fixtures'),('reset','reset_fixtures')]:
                for f in p[key]:
                    assert sha(ROOT/f['path'])==f['sha256']
                    r=child(Path(f['path']).stem+'_simulate',[vvp,binary,'+FIXTURE='+str(ROOT/f['path']),'+MODE='+kind])
                    summaries=[s for s in r['stdout'].splitlines() if s.startswith('PASS mode=')];assert len(summaries)==1
                    words=dict(re.findall(r'(\w+)=([^ ]+)',summaries[0]))
                    assert words['mode']==kind
                    for name in ['frames','inputs','outputs']:assert int(words[name])==f[name]
                    assert int(words['resets'])==int(words['fresh'])==(f['frames'] if kind=='reset' else 0)
                    assert int(words['queued'])==(f['frames']-1 if kind=='main' else 0)
                    mask=sum(1<<target for target in f['targets']);assert int(words['targets'],16)==mask
                    receipt['results'].append(dict(profile=p['name'],kind=kind,fixture=f,observed=words));save()
        for name,c,n,t in matrix['negative_parameters']:
            child('reject_'+name,[iv,'-g2012','-tnull','-s','polygon_triangulation',
                '-P',f'polygon_triangulation.COORD_W={c}','-P',f'polygon_triangulation.MAX_VERTICES={n}',
                '-P',f'polygon_triangulation.TAG_W={t}','rtl/polygon_triangulation.sv'],True)
        assert sources()==plan['source_sha256'] and len(receipt['records'])==len(plan['children'])
        receipt['status']='UNIT_SIM_PASS';save();print('QUALIFIED',sha(ROOT/'verification.json'))
    except Exception as exc:
        receipt['status']='TIMEOUT_NOT_RUN' if receipt['terminal_timeout'] else 'FAIL';receipt['error']=str(exc)
        receipt['records'] += [dict(name=name,status='NOT_RUN') for name in plan['children'][len(receipt['records']):]]
        save();index=0
        while (ROOT/'failure_archive'/f'attempt_{index:02d}').exists():index+=1
        archive=ROOT/'failure_archive'/f'attempt_{index:02d}';archive.mkdir(parents=True)
        for name in [*plan['source_sha256'],'TEST_PLAN.json','verification.json']:
            destination=archive/name;destination.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(ROOT/name,destination)
        (archive/'NOT_RUN.txt').write_text('\n'.join(r['name'] for r in receipt['records'] if r['status']=='NOT_RUN')+'\n',encoding='utf-8',newline='\n')
        raise
    finally:
        assert tmp.parent==temp_root and tmp.name.startswith('anscore_b22_mesh_');shutil.rmtree(tmp)

if __name__=='__main__':
    parser=argparse.ArgumentParser();g=parser.add_mutually_exclusive_group(required=True)
    g.add_argument('--freeze',action='store_true');g.add_argument('--run',action='store_true');args=parser.parse_args()
    if args.freeze:freeze()
    else:run()
