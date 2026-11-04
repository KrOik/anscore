#!/usr/bin/env python3
"""Bounded assignment checks; independent residual min-cost flow and certificates."""
import hashlib
import itertools
import json
import os
from pathlib import Path
import random
import re
import shutil
import subprocess
import tempfile

ROOT=Path(__file__).resolve().parents[1]
REPO=ROOT.parents[2]
BASELINE='e2ccd5380052e92a5430e97b6fdbf0621a17503c'

def mincost(a):
    """Unit-capacity residual network, Bellman-Ford shortest augmentations."""
    n=len(a);s=2*n;t=s+1;v=t+1;edges=[]
    def edge(u,w,c):
        edges.append([u,w,c,1]);edges.append([w,u,-c,0])
    for i in range(n):
        edge(s,i,0);edge(n+i,t,0)
        for j in range(n):
            if a[i][j] is not None:edge(i,n+j,a[i][j])
    total=0
    for flow in range(n):
        dist=[None]*v;prev=[None]*v;dist[s]=0
        for iteration in range(v-1):
            changed=False
            for k,(u,w,c,cap) in enumerate(edges):
                if cap and dist[u] is not None and (dist[w] is None or dist[u]+c<dist[w]):
                    dist[w]=dist[u]+c;prev[w]=k;changed=True
            if not changed:break
        if dist[t] is None:return None
        total+=dist[t];node=t;guard=0
        while node!=s:
            k=prev[node];assert k is not None
            edges[k][3]-=1;edges[k^1][3]+=1;node=edges[k][0]
            guard+=1;assert guard<=v
    return total

def permutation(a):
    costs=[sum(a[i][j] for i,j in enumerate(p)) for p in itertools.permutations(range(len(a)))
           if all(a[i][j] is not None for i,j in enumerate(p))]
    return min(costs) if costs else None

def fixtures(n,w):
    lo=-(1<<(w-1));hi=(1<<(w-1))-1;frames=[]
    def add(edges):frames.append(edges or [(0xffffffff,0xffffffff,lo,0,0)])
    def dense(a):return [(i,j,a[i][j],1,1) for i in range(n) for j in range(n)]
    add([]);add([(i,i,lo,1,1) for i in range(n)])
    add([(i,i,hi,1,1) for i in range(n)])
    add(dense([[0]*n for _ in range(n)]))
    add(dense([[lo if j==(i+1)%n else hi for j in range(n)] for i in range(n)]))
    add([(i,0,lo,1,1) for i in range(n)])
    add([(i,i,0,1,1) for i in range(n)]+[(0,0,hi,0,1)])
    add([(i,i,0,1,1) for i in range(n)]+[(0,0,lo,1,1),(0xffffffff,n,hi,1,0)])
    if n==2:
        for cells in itertools.product([None,lo,hi],repeat=4):
            add([(i//n,i%n,c,1,1) for i,c in enumerate(cells) if c is not None])
    rng=random.Random(20261110+31*n+w)
    for f in range(16):
        edges=[(i,j,rng.randint(lo,hi),1,1) for i in range(n) for j in range(n) if rng.randrange(4)]
        if f<4:
            edges += [(i,i,rng.randint(lo,hi),1,1) for i in range(n)]
        add([(n,0xffffffff,hi,1,0)]+edges)
        if f<4:
            final={(i,j):(c,allowed) for i,j,c,allowed,keep in edges if keep}
            replay=[(i,j,c,k,1) for (i,j),(c,k) in final.items()];rng.shuffle(replay);add(replay)
    add([(n,0,lo,1,1)]);add([(0,0xffffffff,hi,0,1)])
    add([(i,i,hi,1,1) for i in range(n)]+[(0xffffffff,0,lo,1,1)])
    return frames

def pack(values):
    x=0
    for v,w in values:x=(x<<w)|(v&((1<<w)-1))
    return f'{x:x}'

def vectors(n,w,t):
    inputs=[];refs=[];cross=0
    for f,raw in enumerate(fixtures(n,w)):
        a=[[None]*n for _ in range(n)];bad=False;tag=(f*17+5)&((1<<t)-1)
        for k,(i,j,c,allowed,keep) in enumerate(raw):
            if keep:
                if i>=n or j>=n:bad=True
                else:a[i][j]=c if allowed else None
            inputs.append(pack([(i,32),(j,32),(c,w),(allowed,1),(keep,1),(k==len(raw)-1,1),
                                (tag if k==0 else tag^((1<<t)-1),t)]))
        opt=None if bad else mincost(a)
        if not bad and n<=5:assert opt==permutation(a);cross+=1
        refs.append({'a':a,'bad':bad,'opt':opt,'tag':tag,'count':n if opt is not None else 1})
    return inputs,refs,cross

def check(path,refs,n,w,t):
    iw=max(1,(n-1).bit_length());tw=w+(n-1).bit_length();dw=w+2*(n-1).bit_length()+3
    fields=[('keep',1,0),('last',1,0),('status',2,0),('tag',t,0),('row',iw,0),('col',iw,0),
            ('cost',w,1),('total',tw,1),('u',dw,1),('v',dw,1),('hr',n,0),('hc',n,0)]
    actual=[]
    for line in path.read_text().splitlines():
        bits=int(line,16);r={}
        for name,width,signed in reversed(fields):
            v=bits&((1<<width)-1);bits>>=width
            r[name]=v-(1<<width) if signed and v>>(width-1) else v
        assert bits==0;actual.append(r)
    cursor=0;replays={};repeat=0;hall=0;success=0
    for ref in refs:
        chunk=actual[cursor:cursor+ref['count']];cursor+=ref['count'];assert len(chunk)==ref['count']
        a=ref['a'];opt=ref['opt'];bad=ref['bad']
        assert all(r['tag']==ref['tag'] and r['last']==(k==len(chunk)-1) for k,r in enumerate(chunk)),(ref,chunk)
        if opt is None:
            r=chunk[0];assert r['keep']==0 and r['status']==(1 if bad else 2),(ref,r)
            assert all(r[k]==0 for k in ['row','col','cost','total','u','v'])
            if bad:assert r['hr']==r['hc']==0
            else:
                rows={i for i in range(n) if r['hr']>>i&1};cols={j for j in range(n) if r['hc']>>j&1}
                assert len(rows)>len(cols)
                assert all(j in cols for i in rows for j in range(n) if a[i][j] is not None)
                hall+=1
        else:
            assert [r['row'] for r in chunk]==list(range(n))
            assert sorted(r['col'] for r in chunk)==list(range(n))
            us=[r['u'] for r in chunk];vs=[0]*n
            for r in chunk:
                i=r['row'];j=r['col'];vs[j]=r['v']
                assert r['keep']==1 and r['status']==0 and r['hr']==r['hc']==0
                assert a[i][j] is not None and r['cost']==a[i][j] and r['total']==opt,(ref,chunk)
                assert r['u']+r['v']==r['cost']
            assert all(us[i]+vs[j]<=a[i][j] for i in range(n) for j in range(n) if a[i][j] is not None)
            assert sum(r['cost'] for r in chunk)==sum(us)+sum(vs)==opt
            key=tuple(tuple(row) for row in a);solution=tuple((r['col'],r['u'],r['v']) for r in chunk)
            if key in replays:assert replays[key]==solution;repeat+=1
            replays[key]=solution;success+=1
    assert cursor==len(actual)
    return {'success_certificates':success,'hall_certificates':hall,'deterministic_replays':repeat,
            'actual_sha256':hashlib.sha256(path.read_bytes()).hexdigest()}

def main():
    (ROOT/'verification.json').write_text(json.dumps({'status':['NOT_RUN','HW_UNVERIFIED']})+'\n',encoding='utf-8',newline='\n')
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    iv=shutil.which('iverilog',path=env['PATH']);vv=shutil.which('vvp',path=env['PATH']);assert iv and vv
    commands=[];profiles=[]
    def run(cmd,cwd,negative=False):
        p=subprocess.run([str(x) for x in cmd],cwd=cwd,env=env,capture_output=True,text=True,timeout=20)
        r={'argv':[str(x) for x in cmd],'returncode':p.returncode,'stdout':p.stdout,'stderr':p.stderr,'timeout_seconds':20}
        commands.append(r)
        if negative:assert p.returncode>0 and 'min_cost_assignment_invalid_parameters__see_README' in p.stderr,r
        else:assert p.returncode==0 and not p.stderr,r
        return p.stdout
    run([iv,'-V'],ROOT)
    run([iv,'-g2012','-Wall','-tnull','-s','min_cost_assignment','-s','assignment4','-f','files.f','examples/assignment4.sv'],ROOT)
    with tempfile.TemporaryDirectory(prefix='anscore_assignment_') as tmp:
        target=Path(tmp)
        for n,w,t in [(1,1,1),(2,2,5),(3,4,8),(5,8,8),(8,16,8),(32,24,32)]:
            inputs,refs,cross=vectors(n,w,t);data=('\n'.join(inputs)+'\n').encode();(target/'input.hex').write_bytes(data)
            run([iv,'-g2012','-Wall','-s','tb_min_cost_assignment',f'-Ptb_min_cost_assignment.N={n}',
                 f'-Ptb_min_cost_assignment.COST_W={w}',f'-Ptb_min_cost_assignment.TAG_W={t}',
                 '-o','sim.vvp',ROOT/'rtl/min_cost_assignment.sv',ROOT/'sim/tb_min_cost_assignment.sv'],target)
            outcount=sum(r['count'] for r in refs)
            output=run([vv,'sim.vvp',f'+INPUT={target/"input.hex"}',f'+OUTPUT={target/"actual.hex"}',
                        f'+COUNT={len(inputs)}',f'+OUTCOUNT={outcount}'],target)
            cov=re.search(r'PASS records=(\d+) blocked=(\d+) stalled=(\d+) reset_phases=18 max_latency=(\d+) bound=(\d+)',output);assert cov,output
            assert int(cov[1])==outcount and int(cov[2])>0 and int(cov[3])>0
            profiles.append({'N':n,'COST_W':w,'TAG_W':t,'status':'PASS','frames':len(refs),'output_tokens':outcount,
                             'input_tokens':len(inputs),'permutation_crosschecks':cross,'reset_probes':18,
                             'blocked_cycles':int(cov[2]),'held_cycles':int(cov[3]),'output':output.strip(),
                             'maximum_checked_first_latency':int(cov[4]),'conservative_first_bound':int(cov[5]),
                             'input_sha256':hashlib.sha256(data).hexdigest(),**check(target/'actual.hex',refs,n,w,t)})
            print(f'PASS assignment N={n} W={w} frames={len(refs)}',flush=True)
        invalid=[('N',0),('N',33),('COST_W',0),('COST_W',25),('TAG_W',0),('TAG_W',33),('INDEX_W',9),('TOTAL_W',99),('DUAL_W',99)]
        for key,value in invalid:
            run([iv,'-g2012','-tnull','-s','min_cost_assignment',f'-Pmin_cost_assignment.{key}={value}','-f','files.f'],ROOT,True)
    files=['.gitattributes','files.f','rtl/min_cost_assignment.sv','examples/assignment4.sv','sim/tb_min_cost_assignment.sv','sim/run.py']
    for f in files:
        raw=(ROOT/f).read_bytes();raw.decode('utf-8',errors='strict');assert b'\r' not in raw
    report={'baseline_commit':BASELINE,'status':['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],
            'oracle':'independent Bellman-Ford residual min-cost flow; exhaustive permutations N<=5; primal/dual and Hall certificates',
            'profiles':profiles,'commands':commands,'invalid_parameter_rejections':len(invalid),
            'frames':sum(p['frames'] for p in profiles),'output_tokens':sum(p['output_tokens'] for p in profiles),
            'reset_probes':sum(p['reset_probes'] for p in profiles),
            'source_sha256':{f:hashlib.sha256((ROOT/f).read_bytes()).hexdigest() for f in files},
            'not_run':['synthesis','PnR','STA','hardware','expanded regression']}
    (ROOT/'verification.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8',newline='\n')
    print(f'PASS assignment profiles={len(profiles)} frames={report["frames"]} commands={len(commands)}')

if __name__=='__main__':main()
