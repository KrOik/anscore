#!/usr/bin/env python3
"""One immutable finite matrix; every compiler/simulator child has20 seconds."""
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

ROOT=Path(__file__).resolve().parents[1]
REPO=ROOT.parents[2]
PROFILES=[(1,1,1),(3,2,3),(7,8,8),(32,8,8),(64,16,32)]
REJECTS=[(p,v) for p,lo,hi in [('MAX_SYMBOLS',0,65),('SYMBOL_W',0,17),('TAG_W',0,33)] for v in (lo,hi)]
PUBLIC=['.gitattributes','README.md','SOURCES.md','files.f','rtl/suffix_array_lcp.sv',
        'example/suffix32.sv','sim/run.py','sim/tb_suffix_array_lcp.sv','TEST_PLAN.json','SOURCE_FREEZE.json']

def encoded(x):return (json.dumps(x,sort_keys=True,indent=2)+'\n').encode('utf-8')
def sha(x):return hashlib.sha256(x).hexdigest()

def primary(seq):
    """Materialized tuple keys; no insertion, shifting, RAM or timing model."""
    order=sorted(range(len(seq)),key=lambda i:tuple(seq[i:]))
    common=[0]
    for a,b in zip(order,order[1:]):
        pairs=list(zip(seq[a:],seq[b:]))
        common.append(next((i for i,(x,y) in enumerate(pairs) if x!=y),len(pairs)))
    return order,common[:len(order)]

def rank_certificate(seq,order):
    for rank,start in enumerate(order):
        assert rank==sum(tuple(seq[j:])<tuple(seq[start:]) for j in range(len(seq)))
    assert sorted(order)==list(range(len(seq)))

def schedule(seq,order):
    """Secondary operation/latency certificate; cannot supply expected order."""
    comparisons=pairs=ends=shifts=0;built=[0] if seq else []
    for i in range(1,len(seq)):
        hole=i
        while hole:
            prev=built[hole-1];offset=0;comparisons+=1
            while i+offset<len(seq) and prev+offset<len(seq):
                pairs+=1
                if seq[i+offset]!=seq[prev+offset]:break
                offset+=1
            else:ends+=1
            less=(i+offset==len(seq) or (prev+offset<len(seq) and seq[i+offset]<seq[prev+offset]))
            if not less:break
            hole-=1;shifts+=1
        built.insert(hole,i)
    assert built==order
    lpairs=lends=0
    for a,b in zip(order,order[1:]):
        offset=0
        while a+offset<len(seq) and b+offset<len(seq):
            lpairs+=1
            if seq[a+offset]!=seq[b+offset]:break
            offset+=1
        else:lends+=1
    latency=4+2*comparisons+4*pairs+ends+shifts+5*(len(seq)-1)+4*lpairs+lends
    assert latency<=bound(len(seq))
    return {'latency':latency,'comparisons':comparisons,'sort_pairs':pairs,'sort_ends':ends,
            'shifts':shifts,'lcp_pairs':lpairs,'lcp_ends':lends}

def bound(n):return 4+4*n*(n-1)+2*n*(n*n-1)//3+6*(n-1) if n else 1

def reset_ids(m):return [i for i in range(24) if m>1 or i not in list(range(3,15))+[21,22,23]]

def fixture(m,w,t):
    rng=random.Random(0xB2305A+31*m+w+t);full=(1<<w)-1;groups={};cases=[]
    def add(seq,kind,group='all',tokens=None):
        if tokens is None:tokens=[(x,1,int(i==len(seq)-1),0,rng.getrandbits(t)) for i,x in enumerate(seq)]
        if not tokens:tokens=[(full,0,1,0,rng.getrandbits(t))]
        retained=[x for x,k,*_ in tokens if k];err=int(len(retained)>m)|(2 if any(r[3] for r in tokens) else 0);retained=retained[:m]
        order,common=primary(retained) if not err else ([],[])
        if not err:rank_certificate(retained,order)
        cert=schedule(retained,order) if retained and not err else dict(latency=1,comparisons=0,sort_pairs=0,sort_ends=0,shifts=0,lcp_pairs=0,lcp_ends=0)
        record={'kind':kind,'tokens':tokens,'sequence':retained,'error':err,'tag':tokens[0][4],
                'order':order,'lcp':common,'certificate':cert}
        groups.setdefault(group,[]).append(record)
    if m==64:
        add([],'empty','g0');add([0]*m,'all_zero_maximum_work','g0');add([full]*m,'all_ones_maximum_work','g0')
        add(list(range(m)),'ascending','g1');add(list(reversed(range(m))),'descending','g1')
        add([full if i%2 else 0 for i in range(m)],'alternating','g2')
        add([i%7 for i in range(m)],'period_seven','g2')
        add([rng.getrandbits(w) for _ in range(m)],'full_seeded','g3')
        add([full]+[0]*(m-2)+[full],'late_difference','g3')
    else:
        add([],'empty');add([0]*m,'all_zero_maximum_work');add([full]*m,'all_ones_maximum_work')
        add([i & full for i in range(m)],'ascending');add([(m-1-i)&full for i in range(m)],'descending')
        add([full if i%2 else 0 for i in range(m)],'alternating')
        if m<=7:
            alphabet=range(1<<w) if m<=3 else range(2)
            for length in range(m+1):
                for seq in itertools.product(alphabet,repeat=length):add(list(seq),'exhaustive_tiny')
        else:
            for i in range(6):add([rng.getrandbits(w) for _ in range(rng.randrange(m+1))],'seeded')
    ctrl='g3' if m==64 else 'all'
    add([],'masked_only',ctrl,[(full,0,0,0,rng.getrandbits(t)),(0,0,1,0,0)])
    seq=[0]*m
    masked=[(full,0,0,0,(1<<t)-1)]+[(x,1,0,0,rng.getrandbits(t)) for x in seq]+[(full,0,1,0,0)]
    add(seq,'masked_first_tail_and_ignored_tags',ctrl,masked)
    add([0]*(m+1),'overflow_drain',ctrl)
    add([],'masked_upstream',ctrl,[(full,0,1,1,1 & ((1<<t)-1))])
    add([],'combined_errors',ctrl,[(0,1,0,0,0)]*(m+1)+[(full,0,1,1,(1<<t)-1)])
    return groups

def plan_data():
    profiles=[];files={};children=['version','top syntax','example syntax']
    for m,w,t in PROFILES:
        name=f'm{m}_w{w}_t{t}';groups=fixture(m,w,t);main=[]
        children.append(name+' compile TB')
        for group,cases in groups.items():
            path=f'fixtures/{name}_{group}.json';raw=encoded({'M':m,'W':w,'T':t,'cases':cases});files[path]=raw
            main.append({'fixture':path,'sha256':sha(raw),'frames':len(cases),'beats':sum(len(c['tokens']) for c in cases),
                         'outputs':sum(len(c['order']) or 1 for c in cases),'coverage':dict(Counter(c['kind'] for c in cases))})
            children.append(name+' main '+group)
        ids=reset_ids(m);reset=[ids[i:i+2] for i in range(0,len(ids),2)]
        for i,targets in enumerate(reset):children.append(name+' reset '+str(i))
        profiles.append({'M':m,'W':w,'T':t,'name':name,'main':main,'reset_groups':reset,
                         'reset_ids':ids,'full_capacity_fresh_frames':len(ids),'latency_bound':bound(m),
                         'ram_bits':m*(w+2*max(1,(m-1).bit_length())),
                         'scalar_bits':9+t+m.bit_length()+11*max(1,(m-1).bit_length())+2*w})
    children += [f'reject {p}={v}' for p,v in REJECTS]
    return {'schema':1,'baseline_commit':'20e2db4aded8858ff63e132c2399fb416aa48ed0','frozen_before_rtl':True,
            'child_timeout_seconds':20,'profiles':profiles,'rejections':REJECTS,'children':children,
            'reset_targets':{'0..17':'all FSM states; min M1 explicitly excludes3..14',
                             '18':'kept capture before LAST','19':'overflow before LAST','20':'held upstream error',
                             '21':'sort comparator after equal character','22':'later LCP write','23':'held final after prior retirement'},
            'reset_semantics':'immediate cancellation after falling-edge observation; each followed by full M-symbol fresh and every M output retired; groups of at most2 fixed before RTL',
            'planned_child_records':len(children),'bounded_finite_only':True},files

def validate(cases,text):
    rows=text.splitlines();position=0;totals=Counter()
    for frame,c in enumerate(cases):
        cert=c['certificate'];length=len(c['order']);count=length or 1
        for rank in range(count):
            fields=rows[position].split();position+=1;assert len(fields)==16 and fields[0]=='R'
            actual=list(map(int,fields[1:]))
            expected=[frame,rank,c['order'][rank] if length else 0,c['lcp'][rank] if length else 0,
                      length,int(bool(length)),c['error'],c['tag'],cert['latency']]+[cert[k] for k in ['comparisons','sort_pairs','sort_ends','shifts','lcp_pairs','lcp_ends']]
            assert actual==expected,(frame,c['kind'],actual,expected)
        for k,v in cert.items():totals[k]+=v
        totals['frames']+=1;totals['latency_checks']+=1;totals['outputs']+=count;totals['permutation_entries']+=length
    assert position==len(rows);return dict(totals)

def run():
    parser=argparse.ArgumentParser();parser.add_argument('--freeze',action='store_true');parser.add_argument('--run',action='store_true');args=parser.parse_args();plan,files=plan_data()
    if args.freeze:
        assert not (ROOT/'TEST_PLAN.json').exists()
        for p,raw in files.items():(ROOT/p).write_bytes(raw)
        (ROOT/'TEST_PLAN.json').write_bytes(encoded(plan));print('FROZEN',sha(encoded(plan)),len(plan['children']));return
    assert args.run and not (ROOT/'verification.json').exists(),'no automatic retries'
    assert (ROOT/'TEST_PLAN.json').read_bytes()==encoded(plan)
    for p,raw in files.items():assert (ROOT/p).read_bytes()==raw
    freeze=json.loads((ROOT/'SOURCE_FREEZE.json').read_bytes());assert set(freeze['source_sha256'])==set(PUBLIC+list(files))-{'SOURCE_FREEZE.json'}
    for p,h in freeze['source_sha256'].items():assert sha((ROOT/p).read_bytes())==h,p
    report={'schema':1,'status':'NOT_RUN','hardware':'HW_UNVERIFIED','plan_sha256':sha(encoded(plan)),
            'source_sha256':{p:sha((ROOT/p).read_bytes()) for p in PUBLIC+list(files)},'commands':[],'profiles':[]}
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite';env=dict(os.environ);env['PATH']=str(suite/'bin')+os.pathsep+str(suite/'lib')+os.pathsep+env.get('PATH','')
    iv=str(suite/'bin/iverilog.exe');vvp=str(suite/'bin/vvp.exe');failed=False;index=0
    def child(command,reject=False):
        nonlocal failed,index
        name=plan['children'][index];index+=1
        if failed:report['commands'].append({'name':name,'status':'NOT_RUN'});return None
        start=time.perf_counter()
        try:
            r=subprocess.run(command,cwd=ROOT,env=env,capture_output=True,timeout=20)
            out=r.stdout.decode('utf-8','replace');err=r.stderr.decode('utf-8','replace')
            ok=(r.returncode>0 and 'suffix_array_lcp_invalid_parameters__see_README' in out+err) if reject else r.returncode==0
            rec={'name':name,'command':list(map(str,command)),'returncode':r.returncode,'stdout':out,'stderr':err,'timeout_seconds':20,'status':'PASS' if ok else 'FAIL'}
        except subprocess.TimeoutExpired as e:
            rec={'name':name,'command':list(map(str,command)),'stdout':(e.stdout or b'').decode('utf-8','replace'),'stderr':(e.stderr or b'').decode('utf-8','replace'),'timeout_seconds':20,'status':'TIMEOUT_NOT_RUN'}
        rec['elapsed_seconds']=round(time.perf_counter()-start,6);report['commands'].append(rec)
        if rec['status']!='PASS':failed=True
        print(name,rec['status'],flush=True);return rec
    try:
        child([iv,'-V']);child([iv,'-g2012','-Wall','-tnull','-s','suffix_array_lcp','rtl/suffix_array_lcp.sv']);child([iv,'-g2012','-Wall','-tnull','-s','suffix32','rtl/suffix_array_lcp.sv','example/suffix32.sv'])
        with tempfile.TemporaryDirectory(prefix='anscore_b23_suffix_') as temp:
            tmp=Path(temp)
            for p in plan['profiles']:
                m,w,t=p['M'],p['W'],p['T'];image=tmp/(p['name']+'.vvp')
                maxframes=max(x['frames'] for x in p['main']);maxbeats=max(x['beats'] for x in p['main'])
                child([iv,'-g2012','-Wall','-s','tb_suffix_array_lcp',f'-Ptb_suffix_array_lcp.M={m}',f'-Ptb_suffix_array_lcp.W={w}',f'-Ptb_suffix_array_lcp.T={t}',f'-Ptb_suffix_array_lcp.FRAMES={maxframes}',f'-Ptb_suffix_array_lcp.BEATS={maxbeats}','-o',str(image),'rtl/suffix_array_lcp.sv','sim/tb_suffix_array_lcp.sv'])
                profile={'M':m,'W':w,'T':t,'main':[],'reset_groups':[],'status':'NOT_RUN'}
                for f in p['main']:
                    cases=json.loads(files[f['fixture']])['cases'];ip=tmp/'input.hex';op=tmp/'output.txt'
                    words=[f'{(x<<(t+3))|(k<<(t+2))|(last<<(t+1))|(err<<t)|tag:x}' for c in cases for x,k,last,err,tag in c['tokens']]
                    ip.write_text('\n'.join(words)+'\n',encoding='ascii')
                    rec=child([vvp,str(image),'+MODE=0',f'+ACTUAL_FRAMES={f["frames"]}',f'+ACTUAL_BEATS={f["beats"]}',f'+INPUT={ip.as_posix()}',f'+OUTPUT={op.as_posix()}'])
                    totals=None
                    if rec and op.exists():rec['output_text']=op.read_text(encoding='ascii')
                    if rec and rec['status']=='PASS':
                        try:assert 'PASS main ' in rec['stdout'];totals=validate(cases,rec['output_text'])
                        except Exception as e:failed=True;rec['status']='ORACLE_FAIL';rec['validation_error']=repr(e)
                    profile['main'].append({'fixture':f['fixture'],'totals':totals})
                for group in p['reset_groups']:
                    mask=sum(1<<x for x in group);op=tmp/'reset.txt'
                    rec=child([vvp,str(image),'+MODE=1',f'+TARGET_MASK={mask:x}',f'+OUTPUT={op.as_posix()}'])
                    if rec and rec['status']=='PASS':
                        try:
                            expected=f'PASS resets={len(group)} fresh={len(group)} targets={mask:08x}'
                            assert expected in rec['stdout']
                        except Exception as e:failed=True;rec['status']='COVERAGE_FAIL';rec['validation_error']=repr(e)
                    profile['reset_groups'].append({'targets':group,'status':rec['status'] if rec else 'NOT_RUN'})
                if not failed:profile['status']='UNIT_SIM_PASS'
                report['profiles'].append(profile)
            for param,value in REJECTS:child([iv,'-g2012','-tnull','-s','suffix_array_lcp',f'-Psuffix_array_lcp.{param}={value}','rtl/suffix_array_lcp.sv'],True)
    except Exception as e:failed=True;report['exception']=repr(e)
    while index<len(plan['children']):report['commands'].append({'name':plan['children'][index],'status':'NOT_RUN'});index+=1
    report['status']='UNIT_SIM_PASS' if not failed else 'FAIL_OR_NOT_RUN'
    totals=Counter()
    for p in report['profiles']:
        for f in p['main']:totals.update(f['totals'] or {})
        totals['resets']+=sum(len(g['targets']) for g in p['reset_groups'] if g['status']=='PASS')
    totals['fresh']=totals['resets'];report['totals']=dict(totals);(ROOT/'verification.json').write_bytes(encoded(report))
    if failed:raise SystemExit(1)
    print('UNIT_SIM_PASS',json.dumps(report['totals'],sort_keys=True))

if __name__=='__main__':run()
