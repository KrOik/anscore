#!/usr/bin/env python3
"""Frozen finite qualification; no automatic retries or stimulus reductions."""
import argparse
from collections import Counter
import hashlib
import itertools
import json
import os
from pathlib import Path
import random
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[2]
PROFILES = [(1,1,1),(2,3,3),(3,5,8),(5,12,8),(8,32,8),(16,64,32)]
REJECTS = [(p,v) for p,lo,hi in [('NUM_NODES',0,17),('MAX_EDGES',0,65),('TAG_W',0,33)] for v in (lo,hi)]
TARGETS = list(range(21))
PUBLIC = ['.gitattributes','README.md','SOURCES.md','files.f','rtl/directed_euler_trail.sv',
          'example/trail8.sv','sim/run.py','sim/tb_directed_euler_trail.sv','TEST_PLAN.json','SOURCE_FREEZE.json',
          'history/attempt_00.json','history/repair_01.diff']

def encode(x):
    return (json.dumps(x,sort_keys=True,indent=2)+'\n').encode('utf-8')

def sha(x):
    return hashlib.sha256(x).hexdigest()

def feasible(edges,start,n):
    """Degree and weak-connectivity theorem; independent of Hierholzer."""
    if not edges:
        return True
    indeg=[0]*n;outdeg=[0]*n;adj=[set() for _ in range(n)]
    for a,b in edges:
        outdeg[a]+=1;indeg[b]+=1;adj[a].add(b);adj[b].add(a)
    active={i for i in range(n) if indeg[i]+outdeg[i]}
    seen={start};todo=[start]
    for v in todo:
        for w in adj[v]-seen:
            seen.add(w);todo.append(w)
    delta=[outdeg[i]-indeg[i] for i in range(n)]
    balanced=all(x==0 for x in delta)
    open_path=(delta[start]==1 and delta.count(1)==1 and delta.count(-1)==1 and
               all(x in (-1,0,1) for x in delta))
    return active <= seen and start in active and (balanced or open_path)

def enumerate_trail(edges,start):
    """Direct edge-permutation search for tiny inputs, no splice stack."""
    for order in itertools.permutations(range(len(edges))):
        v=start
        for i in order:
            if edges[i][0]!=v:
                break
            v=edges[i][1]
        else:
            return True
    return False

def schedule(edges,start):
    """Secondary cycle/order certificate, never the feasibility oracle."""
    used=set();stack=[];route=[];cur=(start,0);reads=0;pushes=0
    while True:
        for i,(a,b) in enumerate(edges):
            reads+=1
            if i not in used and a==cur[0]:
                used.add(i);stack.append(cur);cur=(b,i);pushes+=1
                break
        else:
            route.append(cur)
            if stack:
                cur=stack.pop()
                continue
            break
    latency=2*reads+4*pushes+3
    if len(used)!=len(edges):
        return {'error':8,'latency':latency,'reads':reads,'pushes':pushes,'route':[]}
    previous=None
    for v,eid in reversed(route):
        latency+=2
        if previous is None:
            if v!=start:
                return {'error':8,'latency':latency,'reads':reads,'pushes':pushes,'route':[]}
        else:
            latency+=2
            if edges[eid]!=(previous,v):
                return {'error':8,'latency':latency,'reads':reads,'pushes':pushes,'route':[]}
        previous=v
    latency+=2
    return {'error':0,'latency':latency,'reads':reads,'pushes':pushes,'route':list(reversed(route))}

def fixtures(n,m,t):
    rng=random.Random(0xB220E0+31*n+m+t);cases=[]
    def add(start,rows,kind):
        rows=list(rows) or [(0,0,0)]
        tokens=[(a,b,k,int(i==len(rows)-1)) for i,(a,b,k) in enumerate(rows)]
        err=int(start>=n);count=0;edges=[]
        for a,b,k,_ in tokens:
            if k:
                if a>=n or b>=n:err |= 2
                if count==m:err |= 4
                else:
                    count+=1;edges.append((a,b))
        exp={'error':err,'latency':0,'reads':0,'pushes':0,'route':[]}
        if not err:
            theorem=feasible(edges,start,n)
            if len(edges)<=5:assert theorem==enumerate_trail(edges,start)
            exp=schedule(edges,start)
            assert (exp['error']==0)==theorem
            assert exp['latency']<=4*len(edges)**2+10*len(edges)+7
        cases.append({'start':start,'tokens':tokens,'edges':edges,'tag':rng.getrandbits(t),
                      'kind':kind,'expected':exp})
    add(0,[],'empty')
    add(n-1,[(0xffffffff,0xffffffff,0)],'masked_extreme')
    add(0,[(0,0,1)]*m,'full_selfloops')
    if n>1:
        walk=[0]
        for i in range(m):walk.append((i+1)%n)
        add(0,[(a,b,1) for a,b in zip(walk,walk[1:])],'full_walk')
        add(1,[(0,0,1)],'wrong_isolated_start')
        if m>=2:
            add(0,[(0,1,1),(0,1,1)],'parallel_degree_failure')
            add(0,[(0,0,1),(1,1,1)],'disconnected_balanced')
        if n>=3 and m>=3:
            add(0,[(0,1,1),(0,2,1),(2,0,1)],'requires_splice')
            add(1,[(0,1,1),(1,2,1),(2,0,1)],'rotated_circuit')
        if n==2:
            for length in range(4):
                for edges in itertools.product(list(itertools.product(range(n),repeat=2)),repeat=length):
                    for start in range(n):add(start,[(a,b,1) for a,b in edges],'exhaustive_ordered_multigraph')
        if n==3:
            for length in range(4):
                for edges in itertools.product(list(itertools.product(range(n),repeat=2)),repeat=length):
                    for start in range(n):add(start,[(a,b,1) for a,b in edges],'exhaustive_ordered_multigraph')
        for j in range(16 if m<=12 else 4):
            length=rng.randrange(m+1)
            edges=[(rng.randrange(n),rng.randrange(n)) for _ in range(length)]
            start=rng.randrange(n)
            add(start,[(a,b,1) for a,b in edges],'seeded_graph')
            permutation=list(range(n));rng.shuffle(permutation)
            add(permutation[start],[(permutation[a],permutation[b],1) for a,b in edges],'vertex_permutation')
    add(n,[(0xffffffff,0xffffffff,0)],'bad_command')
    add(0,[(n,0,1)],'bad_from')
    add(0,[(0,0xffffffff,1)],'bad_to_unsigned32')
    add(0,[(0,0,1)]*(m+1),'capacity_overflow')
    add(0,[(0,0,1)]*m+[(0,0,1),(n,n,1),(0xffffffff,0xffffffff,0)],'sticky_drain')
    add(0xffffffff,[(n,n,1)]*(m+1),'all_input_error_bits')
    coverage=dict(Counter(c['kind'] for c in cases))
    coverage.update(theorem_checks=sum(not(c['expected']['error']&7) for c in cases),
                    enumeration_checks=sum(not(c['expected']['error']&7) and len(c['edges'])<=5 for c in cases))
    return {'N':n,'M':m,'T':t,'cases':cases,'coverage':coverage}

def plan_data():
    profiles=[];data={}
    for n,m,t in PROFILES:
        f=fixtures(n,m,t);name=f'fixtures/n{n}_m{m}_t{t}.json';raw=encode(f);data[name]=raw
        profiles.append({'N':n,'M':m,'T':t,'fixture':name,'fixture_sha256':sha(raw),
                         'frames':len(f['cases']),'beats':sum(len(c['tokens']) for c in f['cases']),
                         'records':sum(len(c['expected']['route']) or 1 for c in f['cases']),
                         'coverage':f['coverage'],'reset_target_ids':TARGETS,'fresh_frames':len(TARGETS)})
    children=['version','top syntax','example syntax']+[f'N{n}/M{m}/T{t}: {mode}' for n,m,t in PROFILES for mode in ['compile TB','main simulation','reset simulation']]+[f'reject {p}={v}' for p,v in REJECTS]
    return {'schema':1,'baseline_commit':'1fcf2f92dbf763e3251bd2994a7b9fd940c43694',
            'bounded_finite_only':True,'child_timeout_seconds':20,'profiles':profiles,'rejections':REJECTS,
            'children':children,'planned_child_records':len(children),
            'reset_semantics':'observe target at falling edge, assert reset before next active edge; no wait edge; every cancellation followed by full M-edge fresh frame and all M+1 records',
            'algorithm_contract':'ascending retained-edge ordinals; validate complete reverse route before any publication; exact integer unsigned endpoints; no modulo wrapping'},data

def validate_main(f,lines):
    rows=lines.splitlines();position=0;totals=Counter()
    for frame,c in enumerate(f['cases']):
        exp=c['expected'];route=exp['route'];count=len(route) or 1;observed=[]
        for j in range(count):
            parts=rows[position].split();position+=1
            assert len(parts)==13 and parts[0]=='R'
            values=list(map(int,parts[1:]));fr,idx,node,eid,has,last,keep,error,tag,edges,latency,reads=values
            assert (fr,idx,last,keep,error,tag,edges)==(frame,j,int(j==count-1),int(not exp['error']),exp['error'],c['tag'],len(c['edges']) if not exp['error'] else 0),(frame,c['kind'],values)
            if j==0:assert (latency,reads)==(exp['latency'],exp['reads']),(frame,c['kind'],latency,exp)
            if route:
                assert (node,eid,has)==(route[j][0],route[j][1] if j else 0,int(j!=0))
                observed.append((node,eid))
            else:assert (node,eid,has)==(0,0,0)
        if observed:
            assert observed[0][0]==c['start']
            ids=[eid for _,eid in observed[1:]]
            assert sorted(ids)==list(range(len(c['edges'])))
            for j,eid in enumerate(ids):assert c['edges'][eid]==[observed[j][0],observed[j+1][0]]
            assert feasible(c['edges'],c['start'],f['N'])
            totals['edge_witnesses']+=len(ids)
        totals['frames']+=1;totals['records']+=count;totals['scan_reads']+=exp['reads'];totals['latency_checks']+=1
    assert position==len(rows)
    return dict(totals)

def run():
    parser=argparse.ArgumentParser();parser.add_argument('--freeze',action='store_true');parser.add_argument('--run',action='store_true');args=parser.parse_args()
    plan,data=plan_data()
    if args.freeze:
        assert not (ROOT/'TEST_PLAN.json').exists(),'matrix is already frozen'
        for p,raw in data.items():(ROOT/p).write_bytes(raw)
        (ROOT/'TEST_PLAN.json').write_bytes(encode(plan))
        print('FROZEN',sha(encode(plan)),len(plan['children']),'children');return
    assert args.run and not (ROOT/'verification.json').exists(),'no automatic retry'
    assert (ROOT/'TEST_PLAN.json').read_bytes()==encode(plan)
    for p,raw in data.items():assert (ROOT/p).read_bytes()==raw
    freeze=json.loads((ROOT/'SOURCE_FREEZE.json').read_bytes())
    assert freeze['test_plan_sha256']==sha(encode(plan))
    assert set(freeze['source_sha256'])==set(PUBLIC+list(data))-{'SOURCE_FREEZE.json'}
    for p,digest in freeze['source_sha256'].items():assert sha((ROOT/p).read_bytes())==digest,p
    report={'schema':1,'status':'NOT_RUN','hardware_status':'HW_UNVERIFIED','test_plan_sha256':sha(encode(plan)),
            'source_sha256':{p:sha((ROOT/p).read_bytes()) for p in PUBLIC+list(data)},'commands':[],'profiles':[]}
    env=dict(os.environ);suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env['PATH']=str(suite/'bin')+os.pathsep+str(suite/'lib')+os.pathsep+env.get('PATH','')
    compiler=str(suite/'bin/iverilog.exe');vvp=str(suite/'bin/vvp.exe');failed=False;index=0
    def child(command):
        nonlocal failed,index
        name=plan['children'][index];index+=1
        if failed:
            report['commands'].append({'name':name,'status':'NOT_RUN'});return None
        start=time.perf_counter()
        try:
            r=subprocess.run(command,cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=20)
            rec={'name':name,'command':[str(x) for x in command],'returncode':r.returncode,'stdout':r.stdout.decode('utf-8','replace'),'stderr':r.stderr.decode('utf-8','replace'),'elapsed_seconds':round(time.perf_counter()-start,6),'timeout_seconds':20,'status':'PASS' if r.returncode==0 else 'FAIL'}
        except subprocess.TimeoutExpired as e:
            rec={'name':name,'command':[str(x) for x in command],'stdout':(e.stdout or b'').decode('utf-8','replace'),'stderr':(e.stderr or b'').decode('utf-8','replace'),'elapsed_seconds':round(time.perf_counter()-start,6),'timeout_seconds':20,'status':'TIMEOUT_NOT_RUN'}
        report['commands'].append(rec)
        if rec['status']!='PASS':failed=True
        print(name,rec['status'],flush=True)
        return rec
    try:
        child([compiler,'-V'])
        child([compiler,'-g2012','-Wall','-tnull','-s','directed_euler_trail','rtl/directed_euler_trail.sv'])
        child([compiler,'-g2012','-Wall','-tnull','-s','trail8','rtl/directed_euler_trail.sv','example/trail8.sv'])
        with tempfile.TemporaryDirectory(prefix='anscore_b22_euler_') as temp:
            temp=Path(temp)
            for p in plan['profiles']:
                n,m,t=p['N'],p['M'],p['T'];f=json.loads(data[p['fixture']]);commands=[];words=[]
                for c in f['cases']:
                    commands.append(f'{(c["start"]<<t)|c["tag"]:x}')
                    words += [f'{(a<<34)|(b<<2)|(k<<1)|last:x}' for a,b,k,last in c['tokens']]
                cp=temp/f'c{n}.hex';ip=temp/f'i{n}.hex';op=temp/f'o{n}.txt';image=temp/f's{n}.vvp'
                cp.write_text('\n'.join(commands)+'\n',encoding='ascii');ip.write_text('\n'.join(words)+'\n',encoding='ascii')
                child([compiler,'-g2012','-Wall','-s','tb_directed_euler_trail',f'-Ptb_directed_euler_trail.N={n}',f'-Ptb_directed_euler_trail.M={m}',f'-Ptb_directed_euler_trail.T={t}',f'-Ptb_directed_euler_trail.FRAMES={p["frames"]}',f'-Ptb_directed_euler_trail.BEATS={p["beats"]}','-o',str(image),'rtl/directed_euler_trail.sv','sim/tb_directed_euler_trail.sv'])
                rec=child([vvp,str(image),'+MODE=0',f'+COMMANDS={cp.as_posix()}',f'+INPUT={ip.as_posix()}',f'+OUTPUT={op.as_posix()}'])
                totals=None
                if rec and op.exists():rec['output_text']=op.read_text(encoding='ascii')
                if rec and rec['status']=='PASS':
                    try:
                        assert 'PASS main' in rec['stdout'];totals=validate_main(f,op.read_text(encoding='ascii'))
                    except Exception as e:
                        failed=True;rec['status']='ORACLE_FAIL';rec['validation_error']=repr(e)
                    rec['output_text']=op.read_text(encoding='ascii') if op.exists() else ''
                rec2=child([vvp,str(image),'+MODE=1',f'+OUTPUT={op.as_posix()}'])
                if rec2 and rec2['status']=='PASS':
                    try:assert 'PASS resets=21 fresh=21 targets=001fffff' in rec2['stdout']
                    except Exception as e:failed=True;rec2['status']='COVERAGE_FAIL';rec2['validation_error']=repr(e)
                report['profiles'].append({'N':n,'M':m,'T':t,'status':'UNIT_SIM_PASS' if totals is not None and rec2 and rec2['status']=='PASS' else 'PARTIAL_OR_NOT_RUN','totals':totals,'resets':21 if rec2 and rec2['status']=='PASS' else 0})
            for param,value in REJECTS:
                if failed:child([]);continue
                # An invalid public parameter must fail at elaboration.
                start=len(report['commands']);rec=child([compiler,'-g2012','-tnull','-s','directed_euler_trail',f'-Pdirected_euler_trail.{param}={value}','rtl/directed_euler_trail.sv'])
                if rec and rec.get('returncode',0)!=0 and 'directed_euler_trail_invalid_parameters__see_README' in rec['stderr']:
                    rec['status']='EXPECTED_REJECT';failed=False
                else:failed=True
    except Exception as e:
        failed=True;report['exception']=repr(e)
    while index<len(plan['children']):
        report['commands'].append({'name':plan['children'][index],'status':'NOT_RUN'});index+=1
    report['status']='UNIT_SIM_PASS' if not failed else 'FAIL_OR_NOT_RUN'
    report['totals']={k:sum((p.get('totals') or {}).get(k,0) for p in report['profiles']) for k in ['frames','records','scan_reads','latency_checks','edge_witnesses']}
    report['totals']['immediate_resets']=sum(p['resets'] for p in report['profiles']);report['totals']['fresh_frames']=report['totals']['immediate_resets']
    (ROOT/'verification.json').write_bytes(encode(report))
    if failed:raise SystemExit(1)
    print('UNIT_SIM_PASS',json.dumps(report['totals'],sort_keys=True))

if __name__=='__main__':run()
