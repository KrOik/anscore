#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Offline, frozen finite unit matrix. No synthesis or external Python modules."""
from fractions import Fraction as F
from itertools import product
from math import comb
from pathlib import Path
import argparse, hashlib, json, os, random, re, subprocess, tempfile, time

ROOT=Path(__file__).resolve().parent
PROFILES=[(1,1,1),(3,1,3),(4,2,8),(8,2,8),(8,3,8),(16,3,32)]
NEGATIVES=[('w0',0,3,8),('w17',17,3,8),('d0',8,0,8),('d4',8,4,8),('t0',8,3,0),('t33',8,3,33)]
TIMEOUT=20
def sha(b): return hashlib.sha256(b).hexdigest()
def trim(p):
    p=list(p)
    while p and p[-1]==0:p.pop()
    return p
def divide(f,g):
    f=trim(f);g=trim(g);q=[F(0)]*max(0,len(f)-len(g)+1)
    if not g:raise ValueError('zero divisor')
    while len(f)>=len(g):
        k=len(f)-len(g);z=f[-1]/g[-1];q[k]=z
        for j,x in enumerate(g):f[j+k]-=z*x
        f=trim(f)
    return trim(q),f
def value(f,x):
    y=F(0)
    for z in reversed(f):y=y*x+z
    return y
def squarefree(f):
    f=trim(map(F,f));g=[i*f[i] for i in range(1,len(f))];h=f
    while g:_,r=divide(h,g);h,g=g,r
    q,r=divide(f,h)
    assert not r
    return q
def open_roots(f,a,b,depth=0,budget=None):
    # Descartes: positive roots after x=(a+b*t)/(1+t).
    # No Sturm or DUT discriminant/pseudo-remainder formulas are used.
    if budget is None:budget=[0]
    budget[0]+=1
    if depth>160 or budget[0]>4096:raise AssertionError('frozen oracle subdivision guard')
    n=len(f)-1;q=[F(0)]*(n+1)
    for i,z in enumerate(f):
        for j in range(i+1):
            for k in range(n-i+1):q[j+k]+=z*comb(i,j)*a**(i-j)*b**j*comb(n-i,k)
    signs=[z>0 for z in q if z]
    variations=sum(x!=y for x,y in zip(signs,signs[1:]))
    if variations<=1:return variations
    mid=(a+b)/2
    return open_roots(f,a,mid,depth+1,budget)+int(value(f,mid)==0)+open_roots(f,mid,b,depth+1,budget)
def oracle(w,d,t,cmd):
    cs,lo,hi,degree,tag=cmd
    status=1 if degree>d else 2 if lo>hi else 3 if cs[degree]==0 else 0
    count=endpoints=0
    if status==0:
        f=list(map(F,cs[:degree+1]));left=value(f,F(lo))==0;right=value(f,F(hi))==0
        endpoints=int(left)+2*int(right)
        if degree:
            if lo==hi:count=int(left)
            else:count=open_roots(squarefree(f),F(lo),F(hi))+int(left)+int(right)
    return (status,endpoints,count,degree,tag,lo,hi)
def selfcheck():
    examples=[([-0,-1,0,1],-2,2,3,3,0),([-2,0,1,0],-2,2,2,2,0),
              ([-2,0,1,0],0,1,2,0,0),([-2,0,1,0],1,2,2,1,0),
              ([0,0,-1,1],0,1,3,2,3),([-1,3,-3,1],1,1,3,1,3),
              ([0,0,1,0],0,0,2,1,3),([1,0,0,0],-2,2,0,0,0),
              ([0,0,0,1],-1,0,3,1,2),([1,0,0,1],-1,1,3,1,1)]
    for cs,lo,hi,degree,count,endpoints in examples:
        got=oracle(8,3,8,(cs,lo,hi,degree,0))
        assert got[1:3]==(endpoints,count),(cs,got)
def reset_ids(d):
    ids=[0,1,4,5,6,8,9,10,11,18,19,20,21,36,37,38,40]
    if d>=2:ids += [2,3,7,12,13,14,15,16,17,22,23,24,32,33,35,39,41,42,43]
    if d==3:ids += [25,26,27,28,29,30,31,34]+list(range(44,52))
    return sorted(ids)
def commands(w,d,t):
    low=-(1<<(w-1));high=(1<<(w-1))-1;alphabet=[-1,0] if w==1 else [-1,0,1]
    endpoints=alphabet;out=[]
    def add(cs,lo,hi,degree):
        cs=list(cs)+[0]*4;cs=cs[:4]
        if all(low<=x<=high for x in cs+[lo,hi]):out.append((cs,lo,hi,degree,len(out)&((1<<t)-1)))
    # Full Cartesian coefficient alphabet and all ordered legal alphabet intervals.
    for degree in range(d+1):
        for cs in product(alphabet,repeat=degree+1):
            for lo,hi in product(endpoints,repeat=2):
                if lo<=hi:add(cs,lo,hi,degree)
    # Explicit analytic, endpoint, cancellation, range and ignored coefficient cases.
    polys=[([1],0),([0,-1],1),([-1,1],1),([0,0,1],2),([-1,0,1],2),
           ([1,0,1],2),([-2,0,1],2),([1,-2,1],2),([0,-1,0,1],3),
           ([0,0,-1,1],3),([0,0,0,1],3),([1,0,0,1],3),([-1,3,-3,1],3),
           ([-6,11,-6,1],3),([0,2,-3,1],3),([1,1,1,1],3),([high,low,high,low],d)]
    intervals=[(low,high),(-1,1),(0,0),(-1,0),(0,1),(1,1),(low,low),(high,high)]
    for cs,degree in polys:
        if degree<=d:
            for lo,hi in intervals:add(cs,lo,hi,degree)
    for degree in range(d+1):
        add([low,high,low,high],low,high,degree)
        add([high,low,high,low],low,high,degree)
        add([0,0,0,0],low,high,degree)
        add([0,0,0,0],high,low,degree) # reversed interval before leading zero
    add([0,0,0,0],high,low,7) # bad degree has highest precedence
    for degree in range(d+1,8):add([low,high,low,high],low,high,degree)
    rng=random.Random(0xB180000+w*100+d)
    for _ in range(96):
        cs=[rng.randint(low,high) for _ in range(4)];degree=rng.randrange(d+1)
        lo,hi=sorted([rng.randint(low,high),rng.randint(low,high)])
        add(cs,lo,hi,degree)
    return out
def packed(values):
    z=0
    for val,bits in values:z=(z<<bits)|(val&((1<<bits)-1))
    return z
def fixture(w,d,t):
    rows=[];stats={'frames':0,'success':0,'errors':[0,0,0],'counts':[0,0,0,0],'endpoint_flags':[0,0,0,0]}
    width=8*w+2*t+13
    for cmd in commands(w,d,t):
        cs,lo,hi,degree,tag=cmd;result=oracle(w,d,t,cmd);status,ep,count,*_=result
        a=packed([(tag,t),(degree,3),(hi,w),(lo,w)]+[(cs[i],w) for i in (3,2,1,0)])
        b=packed([(status,2),(ep,2),(count,3),(degree,3),(tag,t),(lo,w),(hi,w)])
        ow=10+t+2*w;rows.append(f'{((a<<ow)|b):0{(width+3)//4}x}\n')
        stats['frames']+=1
        if status:stats['errors'][status-1]+=1
        else:
            stats['success']+=1;stats['counts'][count]+=1;stats['endpoint_flags'][ep]+=1
    return ''.join(rows).encode(),stats
def source_hashes():
    return {p.relative_to(ROOT).as_posix():sha(p.read_bytes()) for p in sorted(ROOT.rglob('*'))
            if p.is_file() and p.name not in ('TEST_PLAN.json','verification.json') and '__pycache__' not in p.parts}
def freeze():
    selfcheck();plans=[]
    (ROOT/'sim/fixtures').mkdir(parents=True,exist_ok=True)
    for w,d,t in PROFILES:
        name=f'w{w}_d{d}_t{t}';raw,stats=fixture(w,d,t);path=ROOT/f'sim/fixtures/{name}.mem';path.write_bytes(raw)
        plans.append(dict(name=name,w=w,d=d,t=t,fixture=path.relative_to(ROOT).as_posix(),sha256=sha(raw),
                          statistics=stats,reset_ids=reset_ids(d),latency_bound=22*(5*w+7)+100))
    plan=dict(schema=1,freeze='before first HDL child',timeout_seconds=TIMEOUT,
              profiles=plans,negative_parameters=NEGATIVES,children=21,
              source_hashes=source_hashes(),oracle='Fraction gcd square-free part + Descartes Mobius subdivision',
              oracle_guards=dict(depth=160,nodes=4096),reset_policy='immediate target edge; full analytic fresh after every reset',
              source_policy='actual next frozen vector held until accepted; reset cancellation only',
              no_synthesis=True,no_inherited_reruns=True)
    (ROOT/'TEST_PLAN.json').write_text(json.dumps(plan,indent=2)+'\n',encoding='utf-8',newline='\n')
    print('FROZEN',sha((ROOT/'TEST_PLAN.json').read_bytes()),[(x['name'],x['statistics']['frames'],len(x['reset_ids'])) for x in plans])
def run():
    selfcheck();plan=json.loads((ROOT/'TEST_PLAN.json').read_text(encoding='utf-8'));records=[];terminal=False
    suite=Path(r'D:\anscore\tools\oss-cad-suite\oss-cad-suite');binpath=suite/'bin';iv=binpath/'iverilog.exe';vv=binpath/'vvp.exe'
    env=os.environ.copy();env['PATH']=str(binpath)+os.pathsep+str(suite/'lib')+os.pathsep+env.get('PATH','')
    initial=source_hashes()
    assert plan['source_hashes']==initial,'source changed after first freeze; preserve receipts before repair'
    for p in plan['profiles']:assert sha((ROOT/p['fixture']).read_bytes())==p['sha256']
    def child(name,args,expect_fail=False):
        nonlocal terminal
        receipt=dict(name=name,argv=list(map(str,args)),timeout_seconds=TIMEOUT)
        if terminal:receipt.update(status='NOT_RUN',reason='terminal TIMEOUT');records.append(receipt);return False
        started=time.monotonic()
        try:
            cp=subprocess.run(list(map(str,args)),cwd=ROOT,env=env,capture_output=True,text=True,timeout=TIMEOUT)
            receipt.update(exit_code=cp.returncode,stdout=cp.stdout,stderr=cp.stderr,
                           status='PASS' if ((cp.returncode!=0 and 'invalid_parameter__see_README' in cp.stderr) if expect_fail else cp.returncode==0) else 'FAIL')
        except subprocess.TimeoutExpired as exc:
            terminal=True;receipt.update(status='TIMEOUT',stdout=(exc.stdout or b'').decode(errors='replace') if isinstance(exc.stdout,bytes) else exc.stdout or '',stderr='terminal hard limit')
        receipt['elapsed_seconds']=round(time.monotonic()-started,6);records.append(receipt)
        print(name,receipt['status'],receipt.get('stdout','')[-350:].strip(),flush=True)
        return receipt['status']=='PASS'
    with tempfile.TemporaryDirectory(prefix='anscore_b18_') as temp:
        temp=Path(temp)
        child('version',[iv,'-V'])
        child('core_syntax',[iv,'-g2012','-tnull','-s','polynomial_real_root_count','rtl/polynomial_real_root_count.sv'])
        child('example_syntax',[iv,'-g2012','-tnull','-s','polynomial_real_root_count_example','rtl/polynomial_real_root_count.sv','example/polynomial_real_root_count_example.sv'])
        for p in plan['profiles']:
            binary=temp/(p['name']+'.vvp')
            args=[iv,'-g2012','-s','tb_polynomial_real_root_count','-o',binary]
            for key,val in [('DATA_W',p['w']),('MAX_DEG',p['d']),('TAG_W',p['t']),('FRAMES',p['statistics']['frames']),('RESETS',len(p['reset_ids']))]:args += ['-P',f'tb_polynomial_real_root_count.{key}={val}']
            ok=child(p['name']+'_compile',args+['rtl/polynomial_real_root_count.sv','sim/tb_polynomial_real_root_count.sv'])
            if ok:child(p['name']+'_simulate',[vv,binary,'+FIXTURE='+p['fixture']])
            else:records.append(dict(name=p['name']+'_simulate',status='NOT_RUN',reason='compile not PASS'))
        for name,w,d,t in NEGATIVES:
            args=[iv,'-g2012','-tnull','-s','polynomial_real_root_count']
            for key,val in [('DATA_W',w),('MAX_DEG',d),('TAG_W',t)]:args+=['-P',f'polynomial_real_root_count.{key}={val}']
            child('reject_'+name,args+['rtl/polynomial_real_root_count.sv'],True)
    assert initial==source_hashes(),'source mutated during matrix'
    report=dict(schema=1,baseline='eb16eee7848694a1a1cd50e567b5742352751c93',plan_sha256=sha((ROOT/'TEST_PLAN.json').read_bytes()),
                source_hashes=initial,records=records,status='UNIT_SIM_PASS' if len(records)==21 and all(r['status']=='PASS' for r in records) else 'INCOMPLETE',
                hardware='HW_UNVERIFIED',profiles=plan['profiles'],bounded_finite_only=True)
    (ROOT/'verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
    print('REPORT',report['status'],len(records),sha((ROOT/'verification.json').read_bytes()))
    return 0 if report['status']=='UNIT_SIM_PASS' else 1
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('--freeze',action='store_true');p.add_argument('--run',action='store_true');args=p.parse_args()
    if args.freeze:freeze()
    elif args.run:raise SystemExit(run())
    else:p.error('choose --freeze or --run')
