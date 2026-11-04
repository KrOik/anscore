#!/usr/bin/env python3
"""One frozen finite qualification; no automatic retry or expanded regression."""
import argparse
from collections import Counter
import hashlib
import itertools
import json
import os
from pathlib import Path
import random
import re
import subprocess
import tempfile
import time

ROOT=Path(__file__).resolve().parents[1]
REPO=ROOT.parents[2]
PROFILES=[(1,1,1,1),(2,3,2,3),(4,4,3,5),(6,9,8,8),(8,16,8,8),(16,32,16,32)]
REJECTS=[(p,v) for p,lo,hi in [('NUM_SETS',0,17),('UNIVERSE_W',0,33),('WEIGHT_W',0,17),('TAG_W',0,33)] for v in (lo,hi)]
PUBLIC=['.gitattributes','README.md','SOURCES.md','files.f','rtl/exact_weighted_set_cover.sv',
        'example/cover8.sv','sim/run.py','sim/tb_exact_weighted_set_cover.sv']

def encoded(value):
    return (json.dumps(value,sort_keys=True,indent=2)+'\n').encode('utf-8')

def sha(data):
    return hashlib.sha256(data).hexdigest()

def coverage_dp(rows,target):
    """Independent iterative reachable-coverage optimization, no DFS/stack/pruning."""
    table={0:(0,0)}
    for i,(members,weight) in enumerate(rows):
        updated=dict(table)
        for cover,(cost,mask) in table.items():
            newcover=cover | (members & target)
            proposal=(cost+weight,mask | (1<<i))
            if newcover not in updated or proposal<updated[newcover]:
                updated[newcover]=proposal
        table=updated
    return table.get(target),len(table)

def subset_oracle(rows,target):
    best=None
    for mask in range(1<<len(rows)):
        chosen=[rows[i] for i in range(len(rows)) if mask>>i & 1]
        cover=0
        for members,_ in chosen:
            cover |= members
        if cover & target==target:
            candidate=(sum(w for _,w in chosen),mask)
            if best is None or candidate<best:
                best=candidate
    return best

def schedule_certificate(rows,target):
    """Secondary operation/latency certificate; never the optimum oracle."""
    best=None
    stack=[(0,0,0,0)]
    branches=evals=max_sp=0
    while stack:
        depth,covered,cost,mask=stack.pop()
        while True:
            evals+=1
            if covered & target==target:
                if best is None or (cost,mask)<best:
                    best=(cost,mask)
                break
            if depth==len(rows) or (best is not None and cost>best[0]):
                break
            stack.append((depth+1,covered,cost,mask))
            max_sp=max(max_sp,len(stack));branches+=1
            members,weight=rows[depth]
            covered |= members;cost+=weight;mask |= 1<<depth;depth+=1
    assert evals==2*branches+1
    return {'branches':branches,'evals':evals,'pops':branches,'max_sp':max_sp,'latency':5*branches+3},best

def fixtures(n,u,w,t):
    rng=random.Random(0xB210C0+37*n+u+w+t)
    maximum=(1<<w)-1;full=(1<<u)-1
    cases=[]
    def add(rows,target,kind,error=0):
        assert len(rows)==n
        count=1 if error==1 else n
        last=[int(i==count-1) for i in range(count)] if error!=2 else [0]*count
        cases.append({'rows':rows,'target':target,'tag':rng.getrandbits(t),
                      'tokens':[(a,b,last[i]) for i,(a,b) in enumerate(rows[:count])],
                      'error':error,'kind':kind})
    add([(full,maximum)]*n,0,'empty_target')
    add([(full,0)]*n,full,'zero_weight_tie')
    add([(0,maximum)]*n,full,'infeasible_full_tree')
    add([(full,maximum)]*n,full,'full_width_weights')
    add([(1<<(i%u),maximum) for i in range(n)],(1<<min(n,u))-1,'mandatory_all')
    if n<16:
        add([(full^1,0)]*n,1,'infeasible_zero_weight')
        add([(full if i==0 else 1<<(i%u),0 if i==n-1 else maximum) for i in range(n)],full,'greedy_trap')
        for probability in (0.2,0.6):
            for repeat in range(4):
                rows=[(sum(1<<j for j in range(u) if rng.random()<probability),rng.randrange(maximum+1)) for _ in range(n)]
                target=rng.randrange(full+1)
                add(rows,target,'seeded')
                if n<=8:
                    # Independent transformed target columns preserve coverage feasibility and optimum cost.
                    permutation=list(range(u));rng.shuffle(permutation)
                    def permute(value):
                        return sum(1<<permutation[j] for j in range(u) if value>>j & 1)
                    add([(permute(a),b) for a,b in rows],permute(target),'permuted_columns')
        if n<=2:
            for flat in itertools.product(range(1<<u),range(maximum+1),repeat=n):
                rows=list(zip(flat[::2],flat[1::2]))
                for target in range(1<<u):
                    add(rows,target,'all_small_bitpatterns')
    else:
        # One deliberately unpruned maximum tree plus finite maximum-width cost/coverage cases.
        add([(full if i==0 else 1<<(i%u),0 if i==n-1 else maximum) for i in range(n)],full,'large_greedy_trap')
        rows=[(rng.getrandbits(u),rng.randrange(1,maximum+1)) for _ in range(n)]
        add(rows,full,'large_seeded')
    add([(full,1)]*n,full,'missing_final_last',2)
    if n>1:
        add([(full,1)]*n,full,'early_last',1)
    commands=[];data=[];coverage=Counter()
    for case in cases:
        commands.append(f'{(case["target"]<<t)|case["tag"]:0{(u+t+3)//4}x}')
        for members,weight,last in case['tokens']:
            data.append(f'{((members<<w)|weight)<<1|last:0{(u+w+4)//4}x}')
        expected={'error':case['error'],'tag':case['tag']}
        if case['error']:
            expected.update(feasible=0,weight=0,selection=0,latency=1,branches=0,evals=0,pops=0,max_sp=0)
        else:
            optimum,states=coverage_dp(case['rows'],case['target'])
            schedule,secondary=schedule_certificate(case['rows'],case['target'])
            assert secondary==optimum
            if n<=6:
                assert subset_oracle(case['rows'],case['target'])==optimum
                coverage['subset_crosschecks']+=1
            expected.update(schedule)
            expected.update(feasible=int(optimum is not None),weight=optimum[0] if optimum else 0,
                            selection=optimum[1] if optimum else 0)
            assert expected['latency']<=5*(1<<n)-2
            coverage['coverage_dp_states']+=states
            coverage['feasible_'+str(expected['feasible'])]+=1
        case['expected']=expected;coverage[case['kind']]+=1
        coverage['error_'+str(case['error'])]+=1
    return cases,('\n'.join(commands)+'\n').encode('ascii'),('\n'.join(data)+'\n').encode('ascii'),dict(coverage)

def make_plan():
    profiles=[]
    for n,u,w,t in PROFILES:
        cases,commands,data,coverage=fixtures(n,u,w,t)
        profiles.append({'NUM_SETS':n,'UNIVERSE_W':u,'WEIGHT_W':w,'TAG_W':t,'frames':len(cases),
                         'beats':sum(len(c['tokens']) for c in cases),'command_sha256':sha(commands),
                         'input_sha256':sha(data),'coverage':coverage,'immediate_resets_and_full_fresh_frames':12,
                         'oracle_sha256':sha(encoded([c['expected'] for c in cases]))})
    return {'schema':1,'baseline_commit':'ed4eda4fe213da6f6fec793ef911daaabfeba2cc',
            'bounded_finite_only':True,'child_timeout_seconds':20,'profiles':profiles,
            'rejections':REJECTS,'planned_child_records':29,
            'commands':['version','top syntax','example syntax']+
                       [f'N{n}/U{u}/W{w}/T{t}: {mode}' for n,u,w,t in PROFILES for mode in ['compile TB','main simulation','reset simulation']]+
                       [f'reject {p}={v}' for p,v in REJECTS],
            'source_sha256':{p:sha((ROOT/p).read_bytes()) for p in PUBLIC}}

def verify_outputs(cases,output,trace,n,w):
    lines=output.splitlines();assert len(lines)==len(cases)
    totals=Counter()
    keys=['error','tag','feasible','weight','selection','latency','branches','evals','pops','max_sp']
    for frame,(line,case) in enumerate(zip(lines,cases)):
        fields=line.split();assert fields[:2]==['R',str(frame)]
        actual={key:int(value,16 if key in ['tag','weight','selection'] else 10) for key,value in zip(keys,fields[2:])}
        assert len(fields)==12
        assert actual==case['expected'],(frame,case['kind'],actual,case['expected'])
        totals['latency_checks']+=1
        if not actual['error']:
            if actual['feasible']:
                rows=[r for i,r in enumerate(case['rows']) if actual['selection']>>i & 1]
                cover=0
                for members,_ in rows:cover |= members
                assert cover & case['target']==case['target']
                assert sum(weight for _,weight in rows)==actual['weight']
                totals['witness_rows']+=len(rows)
            for key in ['branches','evals','pops']:totals[key]+=actual[key]
    counts=Counter()
    for line in trace.splitlines():
        kind,frame_s,index_s,value_s=line.split();assert kind=='A'
        frame,index,value=int(frame_s),int(index_s),int(value_s,16)
        case=cases[frame];assert not case['error'];assert index==counts[frame]
        members,weight=case['rows'][index];assert value==(members<<w)|weight
        counts[frame]+=1;totals['complete_row_checks']+=1
    for frame,case in enumerate(cases):assert counts[frame]==(0 if case['error'] else n)
    return dict(totals)

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--freeze',action='store_true');args=parser.parse_args()
    plan=make_plan();plan_path=ROOT/'TEST_PLAN.json';receipt=ROOT/'verification.json'
    if args.freeze:
        assert not plan_path.exists() and not receipt.exists(),'refuse to overwrite qualification'
        plan_path.write_bytes(encoded(plan));print(json.dumps({'frozen_plan_sha256':sha(plan_path.read_bytes()),'children':29}));return
    assert plan_path.read_bytes()==encoded(plan),'frozen source/fixture mismatch'
    assert not receipt.exists(),'never overwrite or automatically retry a receipt'
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite';iv=str(suite/'bin/iverilog.exe');vv=str(suite/'bin/vvp.exe')
    assert Path(iv).is_file() and Path(vv).is_file()
    env=os.environ.copy();env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    report={'schema':1,'bounded_finite_only':True,'status':['RTL_CANDIDATE','HW_UNVERIFIED'],
            'matrix_status':'NOT_RUN','source_sha256':plan['source_sha256'],'test_plan_sha256':sha(plan_path.read_bytes()),
            'timeout_occurred':False,'commands':[],'profiles':[],'prior_failed_attempts':[],'invalid_parameter_rejections':0}
    def child(command,reject=False):
        start=time.monotonic()
        try:
            result=subprocess.run(command,cwd=ROOT,env=env,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=20)
            passed=(result.returncode>0 and 'exact_weighted_set_cover_invalid_parameters__see_README' in result.stderr) if reject else result.returncode==0
            report['commands'].append({'argv':command,'returncode':result.returncode,'stdout':result.stdout,'stderr':result.stderr,
                                       'elapsed_seconds':round(time.monotonic()-start,6),'timeout_seconds':20,
                                       'expected_rejection':reject,'status':'PASS' if passed else 'FAIL'})
            assert passed,result.stdout+result.stderr
            return result.stdout
        except subprocess.TimeoutExpired as error:
            def plain(value):return value.decode('utf-8','replace') if isinstance(value,bytes) else value or ''
            report['commands'].append({'argv':command,'returncode':None,'stdout':plain(error.stdout),'stderr':plain(error.stderr),
                                       'elapsed_seconds':round(time.monotonic()-start,6),'timeout_seconds':20,'status':'TIMEOUT'})
            report['timeout_occurred']=True;raise
    try:
        child([iv,'-V'])
        child([iv,'-g2012','-Wall','-tnull','-s','exact_weighted_set_cover','-f','files.f'])
        child([iv,'-g2012','-Wall','-tnull','-s','cover8','-f','files.f','example/cover8.sv'])
        report['status']=['LINT_PASS','HW_UNVERIFIED']
        for n,u,w,t in PROFILES:
            cases,commands,data,coverage=fixtures(n,u,w,t)
            profile={'NUM_SETS':n,'UNIVERSE_W':u,'WEIGHT_W':w,'TAG_W':t,'coverage':coverage,
                     'command_sha256':sha(commands),'input_sha256':sha(data)}
            with tempfile.TemporaryDirectory(prefix='anscore_b21_set_cover_') as temporary:
                directory=Path(temporary)
                cmd,inp,out,trace,exe=[directory/name for name in ['commands.hex','input.hex','output.txt','trace.txt','unit.vvp']]
                cmd.write_bytes(commands);inp.write_bytes(data)
                child([iv,'-g2012','-Wall','-s','tb_exact_weighted_set_cover',f'-Ptb_exact_weighted_set_cover.N={n}',
                       f'-Ptb_exact_weighted_set_cover.U={u}',f'-Ptb_exact_weighted_set_cover.W={w}',f'-Ptb_exact_weighted_set_cover.T={t}',
                       f'-Ptb_exact_weighted_set_cover.FRAMES={len(cases)}',f'-Ptb_exact_weighted_set_cover.BEATS={sum(len(c["tokens"]) for c in cases)}',
                       '-o',str(exe),'-f','files.f','sim/tb_exact_weighted_set_cover.sv'])
                for mode,label in [(0,'main'),(1,'reset')]:
                    stdout=child([vv,str(exe),f'+MODE={mode}','+COMMAND='+cmd.as_posix(),'+INPUT='+inp.as_posix(),'+OUTPUT='+out.as_posix(),'+TRACE='+trace.as_posix()])
                    markers=re.findall(r'^PASS exact_weighted_set_cover mode='+label+r' (.+)$',stdout,re.M);assert len(markers)==1,stdout
                    observed={k:int(v,16 if k=='states' else 10) for k,v in re.findall(r'(\w+)=([0-9a-f]+)',markers[0])};profile.update(observed)
                    if mode==0:
                        assert observed['frames']==len(cases) and observed['beats']==sum(len(c['tokens']) for c in cases)
                        assert observed['blocked_c']==observed['holds_c']>0 and observed['blocked_s']==observed['holds_s']>0
                        assert observed['queued_c']>0 and observed['queued_s']>0
                        totals=verify_outputs(cases,out.read_text(encoding='utf-8'),trace.read_text(encoding='utf-8'),n,w)
                        assert observed['invariants']==totals['evals'];profile.update(totals)
                        profile.update(actual_sha256=sha(out.read_bytes()),trace_sha256=sha(trace.read_bytes()),
                                       maximum_first_valid_latency=max(c['expected']['latency'] for c in cases))
                    else:assert observed['resets']==observed['fresh']==12 and observed['states']==255
                profile['status']='PASS';report['profiles'].append(profile)
        for parameter,value in REJECTS:
            child([iv,'-g2012','-tnull','-s','exact_weighted_set_cover',f'-Pexact_weighted_set_cover.{parameter}={value}','-f','files.f'],True)
            report['invalid_parameter_rejections']+=1
        keys=['frames','beats','blocked_c','holds_c','blocked_s','holds_s','queued_c','queued_s','held','invariants',
              'resets','fresh','latency_checks','branches','evals','pops','witness_rows','complete_row_checks']
        report['totals']={key:sum(p[key] for p in report['profiles']) for key in keys}
        report['status']=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'];report['matrix_status']='PASS'
        assert len(report['commands'])==29
    except Exception as error:
        report['matrix_status']='TIMEOUT_NOT_RUN' if report['timeout_occurred'] else 'FAILED_OR_NOT_RUN';report['failure']=repr(error);raise
    finally:
        report['remaining_profiles']=plan['profiles'][len(report['profiles']):]
        report['remaining_child_records_not_run']=29-len(report['commands']);receipt.write_bytes(encoded(report))
    print(json.dumps({'status':report['status'],'totals':report['totals'],'children':len(report['commands'])}))

if __name__=='__main__':main()
