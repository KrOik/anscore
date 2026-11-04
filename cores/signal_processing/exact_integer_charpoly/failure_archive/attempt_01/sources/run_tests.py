#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Seal once before any HDL; run precisely the immutable 369 children once."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT=Path(__file__).resolve().parent
PLAN_SHA='9a2cd0dd9a32b77524ef8234a90a9ea072ced9f9a94d40da15cee240c15013bd'
MARKER='exact_integer_charpoly_invalid_parameters__see_README'
FIELDS={'mode','N','W','T','frames','outputs','queued','resets','fresh','prefix','next',
        'reset_offers','latency','bank','dot','mul','source_holds','output_holds','states','cycles'}
PROBE_FIELDS={'target','state','m','r','i','j','step','vb','qb','power','count','errors',
              'prefix','next','acc','owned0','accepted'}


def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def encoded(x):return (json.dumps(x,indent=2,sort_keys=True)+'\n').encode('utf-8')
def write(path,x):path.write_bytes(encoded(x))


def sources():
    return {p.relative_to(ROOT).as_posix():sha(p) for p in sorted(ROOT.rglob('*'))
            if p.is_file() and p.name not in ('SOURCE_FREEZE.json','verification.json')
            and 'failure_archive' not in p.relative_to(ROOT).parts}


def owned(stage):
    repo=ROOT.parents[2]
    files={p.relative_to(repo).as_posix():sha(p) for p in sorted(ROOT.rglob('*')) if p.is_file()}
    write(repo/'.git/anscore-b25-b-owned.json',dict(owner='B',stage=stage,files_sha256=files))


def plan():
    assert sha(ROOT/'TEST_PLAN.json')==PLAN_SHA
    p=json.loads((ROOT/'TEST_PLAN.json').read_bytes())
    assert p['frozen_before_rtl'] and p['timeout_seconds']==20 and p['timeout_terminal']
    assert sha(ROOT/'prepare.py')==p['preparation_sha256']
    assert sha(ROOT/'oracle.py')==p['oracle_sha256']
    paths=set()
    for q in p['profiles']:
        for group in q['main']+q['resets']:
            for k in ('json','text'):
                assert sha(ROOT/group[k])==group[k+'_sha256'];paths.add(group[k])
    assert paths=={f.relative_to(ROOT).as_posix() for f in (ROOT/'fixtures').iterdir() if f.is_file()}
    assert len(paths)==706 and len(p['children'])==369
    assert all(c['timeout_seconds']==20 for c in p['children'])
    assert sha(ROOT/'LICENSE.SYMPY')==p['upstream']['license_sha256']
    return p


def seal():
    p=plan()
    assert not (ROOT/'SOURCE_FREEZE.json').exists() and not (ROOT/'verification.json').exists()
    s=sources()
    for name in s:
        b=(ROOT/name).read_bytes();b.decode('utf-8')
        assert b'\r' not in b and not b.startswith(b'\xef\xbb\xbf'),name
    freeze=dict(stage='BEFORE_FIRST_HDL_TOOL_CHILD',baseline=p['baseline'],plan_sha256=PLAN_SHA,
        source_sha256=s,children=p['children'],timeout_seconds=20,timeout_terminal=True,
        no_adaptive_splits=True,first_hdl_requires_root_read_only_preflight=True)
    write(ROOT/'SOURCE_FREEZE.json',freeze);owned('SEALED_BEFORE_FIRST_HDL_AWAIT_ROOT_PREFLIGHT')
    print('SOURCE_FROZEN sha256='+sha(ROOT/'SOURCE_FREEZE.json')+' files='+str(len(s))+' children=369')


def probe_check(p,g,o):
    target=g['target'];assert o['target']==target
    n,w,c=p['N'],p['DATA_W'],p['COEFF_W']
    states={19:1,20:1,21:1,22:1,23:11,24:11,25:11,26:15,27:15,28:15,
      29:12,30:12,31:12,32:9,33:16,34:5,35:16,36:16,37:18,38:18,39:18,
      40:2,41:2,42:2,43:2,44:2,45:3,46:18,47:18,48:16,49:4,50:11,
      51:9,52:15,53:16,54:16}
    assert o['state']==(target if target<=18 else states[target])
    if target in (19,20,21,22):
        assert o['count']=={19:0,20:1,21:n*n,22:n*n+1}[target]
        if target==19:assert o['accepted']>0
        if target==22:assert o['errors']&2
    if target in (23,24,25):assert o['step']=={23:0,24:w//2,25:w-1}[target]
    if target in (26,27,28):assert o['step']=={26:0,27:c//2,28:c-1}[target]
    if target in (29,30,31,32,34,50):assert o['m']==3
    if target in (29,31,50):assert o['power']==1
    if target in (30,32,51):assert o['power']==0
    if target==29:assert (o['i'],o['j'])==(0,1)
    if target==30:assert (o['r'],o['j'])==(2,1)
    if target==31:assert (o['r'],o['i'],o['j'],o['vb'])==(2,1,1,0)
    if target==32:assert (o['r'],o['j'],o['vb'])==(3,0,1)
    if target==33:assert (o['m'],o['i'],o['j'],o['qb'])==(2,2,1,0)
    if target==34:assert o['qb']==1
    if target in (35,36):assert (o['m'],o['i'],o['j'])==(2,1,1)
    if target==36:assert o['acc']!=0
    if target in (37,38,39,47):assert o['i']=={37:0,38:n//2,39:n,47:1}[target]
    if 40<=target<=44:assert o['errors']=={40:1,41:2,42:4,43:5,44:6}[target]
    if target in (45,46):assert o['next']==1
    if target in (48,52,54):assert (o['m'],o['i'],o['j'])==(n,n,n-1)
    if target==49:assert o['owned0']==1
    if target==50:assert o['step']==w//2
    if target==51:assert (o['m'],o['r'],o['j'])==(n,n,0)
    if target==52:assert o['step']==c-1
    if target==53:assert (o['m'],o['i'],o['j'])==(2,0,0)
    assert o['prefix']==g['owner_prefix_outputs'] and o['next']==g['actual_next_offer']


def parse(stdout):
    passes=[x for x in stdout.splitlines() if x.startswith('PASS mode=')]
    assert len(passes)==1,'one fixed PASS summary required'
    values=dict(re.findall(r'(\w+)=(-?[0-9a-f]+)',passes[0]));assert set(values)==FIELDS
    result={k:int(v,16 if k=='states' else 10) for k,v in values.items()}
    probes=[]
    for line in stdout.splitlines():
        if line.startswith('OBS '):
            row=dict(re.findall(r'(\w+)=(-?\d+)',line));assert set(row)==PROBE_FIELDS
            probes.append({k:int(v) for k,v in row.items()})
        elif line!=passes[0]:assert re.fullmatch(r'.*\$finish called at \d+ \(1ps\)',line),line
    return result,probes


def result_check(p,g,kind,stdout):
    r,obs=parse(stdout)
    assert (r['N'],r['W'],r['T'])==(p['N'],p['DATA_W'],p['TAG_W'])
    assert r['frames']==g['frames'] and r['outputs']==g['outputs']
    assert r['cycles']<=p['cycle_limit'] and r['bank']>0 and r['latency']>0
    if kind=='main':
        assert (r['mode'],r['queued'],r['resets'],r['fresh'],r['prefix'],r['next'],r['reset_offers'])==(0,g['queued'],0,0,0,0,0)
        assert r['latency']==g['frames'] and not obs
    else:
        assert (r['mode'],r['queued'],r['resets'],r['fresh'],r['prefix'],r['next'],r['reset_offers'])==(1,0,1,1,g['owner_prefix_outputs'],g['actual_next_offer'],3)
        assert len(obs)==1;probe_check(p,g,obs[0])
    return dict(profile=p['name'],group=g['name'],kind=kind,summary=r,observations=obs)


def execute(argv,env):
    start=time.monotonic()
    kw=dict(cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    if os.name=='nt':kw['creationflags']=subprocess.CREATE_NEW_PROCESS_GROUP|subprocess.CREATE_NO_WINDOW
    else:kw['start_new_session']=True
    process=subprocess.Popen(argv,**kw)
    timed_out=False
    try:out,err=process.communicate(timeout=20)
    except subprocess.TimeoutExpired:
        timed_out=True
        if os.name=='nt':subprocess.run(['taskkill','/PID',str(process.pid),'/T','/F'],stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=20)
        else:os.killpg(process.pid,signal.SIGKILL)
        out,err=process.communicate(timeout=20)
    return dict(argv=argv,timeout_seconds=20,exit_code=process.returncode,
        elapsed_seconds=time.monotonic()-start,stdout=out.decode('utf-8','replace'),
        stderr=err.decode('utf-8','replace'),status='TIMEOUT' if timed_out else 'OBSERVED')


def archive(receipt,tmp):
    idx=1
    while (ROOT/'failure_archive'/f'attempt_{idx:02d}').exists():idx+=1
    dest=ROOT/'failure_archive'/f'attempt_{idx:02d}';dest.mkdir(parents=True)
    receipt['failure_archive']=dest.relative_to(ROOT).as_posix();write(ROOT/'verification.json',receipt)
    for name in list(receipt['source_sha256'])+['SOURCE_FREEZE.json','verification.json']:
        src=ROOT/name;out=dest/'sources'/name;out.parent.mkdir(parents=True,exist_ok=True);out.write_bytes(src.read_bytes())
    for src in tmp.rglob('*'):
        if src.is_file():
            out=dest/'artifacts'/src.relative_to(tmp);out.parent.mkdir(parents=True,exist_ok=True);out.write_bytes(src.read_bytes())
    write(dest/'ARCHIVE.json',dict(status=receipt['status'],files_sha256={f.relative_to(dest).as_posix():sha(f) for f in sorted(dest.rglob('*')) if f.is_file()},ordinary_failure_requires_specific_root_fix_authorization=True,timeout_terminal=receipt['terminal_timeout']))
    owned('FAILED_ATTEMPT_ARCHIVED_STOPPED_NO_RETRY')


def run():
    p=plan();freeze=json.loads((ROOT/'SOURCE_FREEZE.json').read_bytes())
    assert freeze['plan_sha256']==PLAN_SHA and freeze['source_sha256']==sources() and freeze['children']==p['children']
    assert not (ROOT/'verification.json').exists(),'never overwrite or rerun a qualification receipt'
    toolbin=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite/bin'
    replacements={'iverilog':str(toolbin/'iverilog.exe'),'vvp':str(toolbin/'vvp.exe'),'python':sys.executable}
    assert all(Path(replacements[k]).is_file() for k in replacements)
    env=dict(os.environ);env['PATH']=str(toolbin)+os.pathsep+str(toolbin.parent/'lib')+os.pathsep+env.get('PATH','');env['PYTHONDONTWRITEBYTECODE']='1'
    temp_root=Path(tempfile.gettempdir()).resolve();tmp=Path(tempfile.mkdtemp(prefix='anscore_b25_charpoly_',dir=temp_root)).resolve()
    assert tmp.parent==temp_root and tmp.name.startswith('anscore_b25_charpoly_')
    receipt=dict(status='IN_PROGRESS',hardware='HW_UNVERIFIED',baseline=p['baseline'],plan_sha256=PLAN_SHA,
        source_freeze_sha256=sha(ROOT/'SOURCE_FREEZE.json'),source_sha256=sources(),timeout_seconds=20,
        path_expansion={**replacements,'{TMP}':tmp.as_posix()},terminal_timeout=False,
        records=[dict(name=c['name'],status='NOT_RUN') for c in p['children']],results=[])
    lookup={g['name']:(q,g,kind) for q in p['profiles'] for kind in ('main','resets') for g in q[kind]}
    write(ROOT/'verification.json',receipt);owned('QUALIFICATION_RUNNING_FIXED_SEALED_CHILDREN')
    try:
        for idx,child in enumerate(p['children']):
            argv=[replacements.get(a,a).replace('{TMP}',tmp.as_posix()) for a in child['argv']]
            observed=execute(argv,env);observed['name']=child['name'];receipt['records'][idx]=observed
            write(ROOT/'verification.json',receipt)
            if observed['status']=='TIMEOUT':
                receipt['terminal_timeout']=True;raise RuntimeError('TERMINAL TIMEOUT '+child['name'])
            if child['expected'].startswith('REJECT'):
                assert observed['exit_code']!=0 and MARKER in observed['stdout']+observed['stderr'],child['name']
            else:assert observed['exit_code']==0,child['name']
            if child['name'] in lookup:
                q,g,kind=lookup[child['name']]
                receipt['results'].append(result_check(q,g,'main' if kind=='main' else 'reset',observed['stdout']))
            elif child['name']=='fixture_oracles':assert observed['stdout'].startswith('PASS fixture_oracles ')
            observed['status']='PASS';write(ROOT/'verification.json',receipt)
            if idx%10==0 or idx+1==len(p['children']):print('PASS child '+str(idx+1)+'/369 '+child['name'],flush=True)
        assert sources()==freeze['source_sha256']
        assert len(receipt['results'])==353 and all(r['status']=='PASS' for r in receipt['records'])
        receipt['status']='UNIT_SIM_PASS';receipt['totals']=p['totals'];receipt['max_child_seconds']=max(r['elapsed_seconds'] for r in receipt['records'])
        receipt['observed_totals']={k:sum(x['summary'][k] for x in receipt['results']) for k in ('frames','outputs','queued','resets','fresh','prefix','next','reset_offers','latency','bank','dot','mul','source_holds','output_holds')}
        write(ROOT/'verification.json',receipt);owned('UNIT_SIM_PASS_HW_UNVERIFIED')
        assert tmp.parent==temp_root and tmp.name.startswith('anscore_b25_charpoly_')
        shutil.rmtree(tmp)
        print('UNIT_SIM_PASS children=369 simulations=353 HW_UNVERIFIED',flush=True)
    except BaseException as e:
        receipt['status']='TIMEOUT_TERMINAL' if receipt['terminal_timeout'] else 'FAIL_STOPPED'
        receipt['error']=repr(e);archive(receipt,tmp)
        print(receipt['status']+' '+str(e)+' archived; stop for root',flush=True)
        raise


def check():
    p=plan();f=json.loads((ROOT/'SOURCE_FREEZE.json').read_bytes());r=json.loads((ROOT/'verification.json').read_bytes())
    assert f['source_sha256']==sources() and f['children']==p['children']
    assert r['status']=='UNIT_SIM_PASS' and not r['terminal_timeout']
    assert r['source_sha256']==sources() and r['source_freeze_sha256']==sha(ROOT/'SOURCE_FREEZE.json')
    assert [c['name'] for c in r['records']]==[c['name'] for c in p['children']]
    assert all(c['status']=='PASS' and c['timeout_seconds']==20 for c in r['records'])
    assert r['totals']==p['totals'] and len(r['results'])==353
    lookup={g['name']:(q,g,kind) for q in p['profiles'] for kind in ('main','resets') for g in q[kind]}
    results={x['group']:x for x in r['results']}
    for record in r['records']:
        if record['name'] in lookup:
            q,g,kind=lookup[record['name']]
            assert result_check(q,g,'main' if kind=='main' else 'reset',record['stdout'])==results[g['name']]
    print('PASS read-only receipt verification children=369 HW_UNVERIFIED')


if __name__=='__main__':
    parser=argparse.ArgumentParser();g=parser.add_mutually_exclusive_group(required=True)
    g.add_argument('--seal',action='store_true');g.add_argument('--run',action='store_true');g.add_argument('--check',action='store_true')
    args=parser.parse_args()
    if args.seal:seal()
    elif args.run:run()
    else:check()
