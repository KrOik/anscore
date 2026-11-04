#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Frozen exact NNLS2 finite matrix, standard library only; no hardware tools."""
from fractions import Fraction as F
from itertools import product,combinations
from math import lcm
from pathlib import Path
import argparse,hashlib,json,os,random,re,subprocess,tempfile,time

ROOT=Path(__file__).resolve().parent
PROFILES=[(1,2,1),(3,3,3),(4,4,8),(8,8,8),(8,16,8),(16,16,32)]
NEGATIVES=[('w0',0,16,8),('w17',17,16,8),('n1',8,1,8),('n17',8,17,8),('t0',8,16,0),('t33',8,16,33)]
BASELINE='897cf84f5861f5fada3c1a5d64127e64cdb9af92'
def sha(b):return hashlib.sha256(b).hexdigest()
def gaussian(matrix,rhs):
    n=len(rhs);a=[[F(x) for x in row]+[F(y)] for row,y in zip(matrix,rhs)]
    for k in range(n):
        pivot=next((i for i in range(k,n) if a[i][k]),None)
        if pivot is None:return None
        a[k],a[pivot]=a[pivot],a[k];z=a[k][k];a[k]=[v/z for v in a[k]]
        for i in range(n):
            if i!=k:
                z=a[i][k];a[i]=[x-z*y for x,y in zip(a[i],a[k])]
    return [row[-1] for row in a]
def solution(rows):
    # Rank oracle: Cauchy-Binet over raw row-pair minors, not Gram determinant.
    det=sum((x[0]*y[1]-x[1]*y[0])**2 for x,y in combinations(rows,2))
    if det==0:return None,0
    candidates=[]
    for mask in range(4):
        cols=[j for j in range(2) if mask>>j&1]
        matrix=[[sum(row[i]*row[j] for row in rows) for j in cols] for i in cols]
        rhs=[sum(row[i]*row[2] for row in rows) for i in cols]
        restricted=gaussian(matrix,rhs)
        if restricted is None:continue
        x=[F(0),F(0)]
        for j,z in zip(cols,restricted):x[j]=z
        residual=[sum(row[j]*x[j] for j in range(2))-row[2] for row in rows]
        gradient=[sum(row[j]*r for row,r in zip(rows,residual)) for j in range(2)]
        if all(z>=0 for z in x+gradient) and all(x[j]*gradient[j]==0 for j in range(2)):
            candidates.append(tuple(x))
    assert candidates and len(set(candidates))==1,('unique original-row KKT certificate',rows,candidates)
    return candidates[0],det
def selfcheck():
    cases=[([(-1,0,-1),(0,-1,-1)],(F(1),F(1))),
           ([(-1,-1,0),(-1,0,-1)],(F(1,2),F(0))),
           ([(-1,-1,0),(0,-1,-1)],(F(0),F(1,2))),
           ([(-1,0,1),(0,-1,1)],(F(0),F(0))),
           ([(-1,0,-1),(0,-1,-1),(-1,-1,-1)],(F(2,3),F(2,3))),
           ([(1,-1,1),(0,1,0)],(F(1),F(0)))]
    for rows,expected in cases:assert solution(rows)[0]==expected
    assert solution([(1,1,2),(2,2,3)])[0] is None
def reset_ids(w):return [i for i in range(45) if w>1 or i not in (22,42)]
def frames(w,n,t):
    low=-(1<<(w-1));high=(1<<(w-1))-1;alphabet=[-1,0] if w==1 else [-1,0,1];out=[]
    def add(rows,mask=0):
        rows=[tuple(x) for x in rows]
        if all(low<=x<=high for row in rows for x in row):out.append((rows,mask))
    # Every ordered pair from the full small signed row alphabet at small profiles.
    if w<=4:
        rowset=list(product(alphabet,repeat=3))
        for x,y in product(rowset,repeat=2):add([x,y])
    directed=[[],[(-1,0,-1)],[(-1,0,-1),(0,-1,-1)],
              [(-1,-1,0),(-1,0,-1)],[(-1,-1,0),(0,-1,-1)],
              [(-1,0,0),(0,-1,0)],[(-1,0,1),(0,-1,1)],
              [(-1,0,-1),(0,-1,-1),(-1,-1,-1)],
              [(1,-1,1),(0,1,0)],[(1,0,-1),(1,1,1)],
              [(1,1,1),(2,2,-1)],[(0,0,0),(0,0,0)],
              [(low,high,low),(high,low,high)],[(low,0,low),(0,low,low)],
              [(high,high,low),(low,low,high)],[(low,high,high),(high,low,low)]]
    for rows in directed:
        add(rows);add(rows,1);add(list(reversed(rows)),2)
    # Full capacity, signed extrema, correlated columns and rank-deficient extremes.
    for k in range(12):
        rows=[]
        for i in range(n):
            basis=[(low,0,low),(0,low,low),(low,low,low),(high,low,high),
                   (low,high,low),(0,0,high)]
            rows.append(basis[(i+k)%len(basis)])
        add(rows,k%3)
    add([(low,0,low)]*n);add([(0,low,high)]*n)
    add([(low,0,low),(0,low,low)]+[(high,low,high)]*(n-1),1) # overflow
    add([(0,0,0)]*(n+3),2)
    rng=random.Random(0xB190000+w*100+n)
    for i in range(96):
        length=rng.randrange(n+3);rows=[tuple(rng.randint(low,high) for _ in range(3)) for _ in range(length)]
        add(rows,i%3)
    return out
def pack(fields):
    z=0
    for val,bits in fields:z=(z<<bits)|(val&((1<<bits)-1))
    return z
def fixture(w,n,t):
    iw=(n-1).bit_length();cw=n.bit_length();ew=4*w+2*iw+4;cmdw=3*w+t+2;ow=4*ew+cw+t+4
    lines=[];stats=dict(frames=0,beats=0,success=0,status=[0]*4,positive=[0]*4,fractional=0,full_rank_full_capacity=0)
    for index,(rows,mask) in enumerate(frames(w,n,t)):
        retained=rows[:n];tag=(index*37+13)&((1<<t)-1);count=len(retained)
        status=2 if len(rows)>n else 1 if not rows else 0;x=det=None
        if status==0:
            x,det=solution(retained)
            if x is None:status=3
        if status:
            nx=ny=den=det=positive=0
        else:
            den=lcm(x[0].denominator,x[1].denominator);nx=int(x[0]*den);ny=int(x[1]*den)
            positive=int(x[0]>0)+2*int(x[1]>0);stats['success']+=1;stats['positive'][positive]+=1
            stats['fractional']+=any(z.denominator>1 for z in x)
            stats['full_rank_full_capacity']+=count==n
        latency=1 if status in (1,2) else 14+count*(5*w+11)+6*ew
        expected=pack([(status,2),(positive,2),(count,cw),(tag,t),(det,ew),(nx,ew),(ny,ew),(den,ew)])
        tokens=[]
        if mask:tokens.append((0,0,0,0,tag)) # masked first owns tag
        for j,row in enumerate(rows):
            tokens.append((*row,1,tag if not tokens else tag^((1<<t)-1)))
            if mask==2 and j%3==0:tokens.append((0,0,0,0,0))
        if not tokens:tokens=[(0,0,0,0,tag)]
        if mask==1:tokens.append((0,0,0,0,0)) # masked tail seals a full frame
        for j,(a0,a1,b,keep,token_tag) in enumerate(tokens):
            last=j==len(tokens)-1;cmd=pack([(token_tag,t),(last,1),(keep,1),(a0,w),(a1,w),(b,w)])
            word=((expected<<(32+cmdw))|(latency<<cmdw) if last else 0)|cmd
            lines.append(f'{word:0{(ow+32+cmdw+3)//4}x}\n')
        stats['frames']+=1;stats['beats']+=len(tokens);stats['status'][status]+=1
    assert stats['success'] and stats['fractional'] and stats['full_rank_full_capacity']
    assert all(stats['status'])
    return ''.join(lines).encode(),stats
def source_hashes():
    return {p.relative_to(ROOT).as_posix():sha(p.read_bytes()) for p in sorted(ROOT.rglob('*'))
            if p.is_file() and p.name not in ('TEST_PLAN.json','verification.json') and '__pycache__' not in p.parts}
def freeze():
    selfcheck();profiles=[];(ROOT/'sim/fixtures').mkdir(parents=True,exist_ok=True)
    for w,n,t in PROFILES:
        raw,stats=fixture(w,n,t);name=f'w{w}_n{n}_t{t}';path=ROOT/f'sim/fixtures/{name}.mem';path.write_bytes(raw)
        profiles.append(dict(name=name,w=w,n=n,t=t,fixture=path.relative_to(ROOT).as_posix(),sha256=sha(raw),statistics=stats,reset_ids=reset_ids(w)))
    plan=dict(baseline=BASELINE,frozen_before_first_hdl=True,profiles=profiles,negatives=NEGATIVES,children=21,timeout_seconds=20,
              oracle='exact active-subset Gaussian solve; original-row residual KKT; Cauchy-Binet rank/determinant',
              source_policy='actual next frozen token held until acceptance or reset cancellation',
              reset_policy='immediate observed low-clock target, then complete analytic two-row fresh solve',source_hashes=source_hashes())
    (ROOT/'TEST_PLAN.json').write_text(json.dumps(plan,indent=2)+'\n',encoding='utf-8',newline='\n')
    print('FROZEN',sha((ROOT/'TEST_PLAN.json').read_bytes()),[(x['name'],x['statistics'],len(x['reset_ids'])) for x in profiles])
def run():
    selfcheck();plan=json.loads((ROOT/'TEST_PLAN.json').read_bytes());initial=source_hashes();assert initial==plan['source_hashes']
    previous=json.loads((ROOT/'verification.json').read_bytes()) if (ROOT/'verification.json').exists() else {}
    if previous:raise RuntimeError('Existing receipt: preserve original bytes and explicit fixed-matrix repair before any further execution')
    suite=Path(r'D:\anscore\tools\oss-cad-suite\oss-cad-suite');env=os.environ.copy()
    env['PATH']=str(suite/'bin')+os.pathsep+str(suite/'lib')+os.pathsep+env.get('PATH','');iv=suite/'bin/iverilog.exe';vv=suite/'bin/vvp.exe'
    report=dict(baseline=BASELINE,status='NOT_RUN',hardware='HW_UNVERIFIED',plan_sha256=sha((ROOT/'TEST_PLAN.json').read_bytes()),
                source_sha256=dict(initial,**{'TEST_PLAN.json':sha((ROOT/'TEST_PLAN.json').read_bytes())}),profiles=plan['profiles'],records=[],terminal_timeout=False)
    def save():(ROOT/'verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
    def child(name,args,negative=False):
        rec=dict(name=name,argv=list(map(str,args)),timeout_seconds=20)
        if report['terminal_timeout']:rec.update(status='NOT_RUN',reason='terminal TIMEOUT');report['records'].append(rec);save();return False
        start=time.monotonic()
        try:
            cp=subprocess.run(list(map(str,args)),cwd=ROOT,env=env,capture_output=True,text=True,timeout=20)
            good=(cp.returncode>0 and 'nonnegative_least_squares2_invalid_parameter__see_README' in cp.stderr) if negative else cp.returncode==0
            rec.update(status='PASS' if good else 'FAIL',exit_code=cp.returncode,stdout=cp.stdout,stderr=cp.stderr)
        except subprocess.TimeoutExpired as exc:
            report['terminal_timeout']=True;decode=lambda x:x.decode(errors='replace') if isinstance(x,bytes) else x or ''
            rec.update(status='TIMEOUT',stdout=decode(exc.stdout),stderr=decode(exc.stderr))
        rec['elapsed_seconds']=round(time.monotonic()-start,6);report['records'].append(rec);save()
        print(name,rec['status'],rec.get('stdout','')[-420:].strip(),flush=True);return rec['status']=='PASS'
    save()
    with tempfile.TemporaryDirectory(prefix='anscore_b19_nnls2_') as temp:
        temp=Path(temp);child('version',[iv,'-V'])
        child('core_syntax',[iv,'-g2012','-Wall','-tnull','-s','nonnegative_least_squares2','-f','files.f'])
        child('example_syntax',[iv,'-g2012','-Wall','-tnull','-s','nonnegative_fit16','-f','example/files.f'])
        for p in plan['profiles']:
            assert sha((ROOT/p['fixture']).read_bytes())==p['sha256'];binary=temp/(p['name']+'.vvp')
            args=[iv,'-g2012','-Wall','-s','tb_nonnegative_least_squares2','-o',binary]
            for key,val in [('DATA_W',p['w']),('MAX_SAMPLES',p['n']),('TAG_W',p['t']),('BEATS',p['statistics']['beats']),('FRAMES',p['statistics']['frames']),('RESETS',len(p['reset_ids']))]:
                args += ['-P',f'tb_nonnegative_least_squares2.{key}={val}']
            ok=child(p['name']+'_compile',args+['rtl/nonnegative_least_squares2.sv','sim/tb_nonnegative_least_squares2.sv'])
            if ok:child(p['name']+'_simulate',[vv,binary,'+FIXTURE='+p['fixture']])
            else:report['records'].append(dict(name=p['name']+'_simulate',status='NOT_RUN',reason='compile not PASS'));save()
        for name,w,n,t in NEGATIVES:
            args=[iv,'-g2012','-tnull','-s','nonnegative_least_squares2']
            for key,val in [('DATA_W',w),('MAX_SAMPLES',n),('TAG_W',t)]:args += ['-P',f'nonnegative_least_squares2.{key}={val}']
            child('reject_'+name,args+['rtl/nonnegative_least_squares2.sv'],True)
    assert source_hashes()==initial
    if len(report['records'])==21 and all(x['status']=='PASS' for x in report['records']):report['status']='UNIT_SIM_PASS'
    save();print('REPORT',report['status'],sha((ROOT/'verification.json').read_bytes()))
    return 0 if report['status']=='UNIT_SIM_PASS' else 1
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--freeze',action='store_true');p.add_argument('--run',action='store_true');args=p.parse_args()
    if args.freeze:freeze()
    elif args.run:raise SystemExit(run())
    else:p.error('choose --freeze or --run')
