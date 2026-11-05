"""Frozen, one-attempt finite runner. Never synthesize, route or retry a child."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import time

ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
ARTIFACTS=REPO/'.git/b26-b-artifacts'
LOGS=ROOT/'reports'
SEAL=ROOT/'SOURCE_FREEZE.json'
REPORT=ROOT/'verification.json'

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_bytes())
def write(p,d):p.write_text(json.dumps(d,indent=2,sort_keys=True)+'\n',encoding='utf-8',newline='\n')
def source_map():
    return {p.relative_to(ROOT).as_posix():sha(p) for p in sorted(ROOT.rglob('*'))
       if p.is_file() and p not in [SEAL,REPORT] and p.relative_to(ROOT).parts[0] not in ['failure_archive','reports']}
def freeze():
    assert not SEAL.exists() and not REPORT.exists(),'never replace a seal/receipt'
    plan=read(ROOT/'TEST_PLAN.json')
    assert len(plan['children'])==37 and plan['totals']['main_commands']==462
    tools={c['argv'][0]:sha(Path(c['argv'][0])) for c in plan['children']}
    write(SEAL,dict(schema=1,baseline=plan['baseline'],plan_sha256=sha(ROOT/'TEST_PLAN.json'),
                    frozen_before_any_hdl=True,files_sha256=source_map(),timeout_seconds=20,
                    tools_sha256=tools))
    print('SEALED',sha(SEAL),'sources',len(read(SEAL)['files_sha256']))
def check():
    seal=read(SEAL)
    assert source_map()==seal['files_sha256'],'source inventory changed after seal'
    assert sha(ROOT/'TEST_PLAN.json')==seal['plan_sha256']
    assert all(sha(Path(p))==h for p,h in seal['tools_sha256'].items())
    if REPORT.exists():
        r=read(REPORT)
        assert r['status']=='UNIT_SIM_PASS' and not r['terminal_timeout']
        assert len(r['records'])==37 and all(x['status']=='PASS' for x in r['records'])
        assert r['source_freeze_sha256']==sha(SEAL)
        assert r['source_sha256']==dict(seal['files_sha256'],**{'SOURCE_FREEZE.json':sha(SEAL)})
        for x in r['records']:
            for stream in ['stdout','stderr']:
                assert sha(ROOT/x[stream+'_file'])==x[stream+'_sha256']
        assert {p.relative_to(ROOT).as_posix() for p in LOGS.iterdir() if p.is_file()}=={
            x[stream+'_file'] for x in r['records'] for stream in ['stdout','stderr']}
    print('PASS read-only seal/receipt integrity; no HDL or oracle invocation')

REC=re.compile(r'^REC id=(\d+) poly=([0-9a-f]+) tag=([0-9a-f]+) irred=(\d+) kind=(\d+) index=(\d+) delta=([0-9a-f]+) gcd=([0-9a-f]+) latency=(\d+)$',re.M)
PROBE=re.compile(r'^PROBE id=(\d+) state=(\d+) k=(\d+) left=(\d+) u=([0-9a-f]+) v=([0-9a-f]+) next=(\d+)$',re.M)
def validate_output(command,output,profiles):
    if command['kind']!='simulation':return None
    p=profiles[command['profile']];fixture=read(ROOT/p['certificate']);mode=command['mode']
    lines=[line for line in output.splitlines() if line.startswith('PASS mode=')]
    assert len(lines)==1,'missing/duplicate final completion'
    values={k:int(v) for k,v in re.findall(r'(\w+)=(\d+)',lines[0])}
    assert values['mode']==mode and values['D']==p['degree']
    expected=[(i,c) for i,c in enumerate(fixture['cases'])] if mode!=2 else [(x['id'],x['fresh']) for x in fixture['probes']]
    rows=REC.findall(output)
    assert len(rows)==len(expected),'missing retirement evidence'
    for row,(index,c) in zip(rows,expected):
        actual=[int(row[0]),int(row[1],16),int(row[2],16),int(row[3]),int(row[4]),int(row[5]),int(row[6],16),int(row[7],16),int(row[8])]
        wanted=[index,c['poly'],c['tag'],int(c['irreducible']),c['kind'],c['index'],c['delta'],c['witness_gcd'],c['cycles']]
        assert actual==wanted,('raw retirement differs from independent certificate',actual,wanted)
    if mode!=2:
        n=p['main_count']
        assert values['accepts']==values['outputs']==values['latency_checks']==n
        assert values['canceled']==values['resets']==values['next']==values['reset_offers']==0
        rounds=[r for c in fixture['cases'] for r in c['rounds']]
        assert values['squares']==p['degree']*len(rounds)
        assert values['gcd_done']==sum(r['checkpoint'] for r in rounds)
        assert values['gcd_cancel']==sum(q.bit_count() for r in rounds for q in r.get('quotients',[]))
        assert values['gcd_swap']==sum(len(r.get('quotients',[])) for r in rounds)
        assert values['source_holds']>0
        assert values['output_holds']==(0 if mode==0 else 3*n)
    else:
        n=p['reset_count']
        assert values['accepts']==2*n and values['outputs']==values['canceled']==values['resets']==n
        assert values['next']==1 and values['reset_offers']==3*n
        assert values['latency_checks']==n+2 and values['output_holds']>=3*n+6
        traces=PROBE.findall(output);assert len(traces)==n
        for row,probe in zip(traces,fixture['probes']):
            actual=[int(x,16) if i in [4,5] else int(x) for i,x in enumerate(row)]
            x=probe['predicate']
            assert actual[0:3]==[probe['id'],x['state'],x['k']]
            if x['mask']&2:assert actual[3]==x['left']
            if x['mask']&4:assert actual[4:6]==[x['u'],x['v']]
            assert actual[6]==int(probe['actual_next_offer'])
    return dict(profile=command['profile'],mode=mode,observed=values)

def archive_failure(report):
    archive=ROOT/'failure_archive/attempt_01'
    assert not archive.exists(),'failure archive already exists; manual root review required'
    for relative in [*report['source_sha256'],'verification.json']:
        destination=archive/'sources'/relative
        destination.parent.mkdir(parents=True,exist_ok=True)
        destination.write_bytes((ROOT/relative).read_bytes())
    if ARTIFACTS.exists():
        for file in ARTIFACTS.rglob('*'):
            if file.is_file():
                dest=archive/'artifacts'/file.relative_to(ARTIFACTS)
                dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(file.read_bytes())
    if LOGS.exists():
        for file in LOGS.iterdir():
            if file.is_file():
                dest=archive/'logs'/file.name
                dest.parent.mkdir(parents=True,exist_ok=True);dest.write_bytes(file.read_bytes())
    files={p.relative_to(archive).as_posix():sha(p) for p in sorted(archive.rglob('*')) if p.is_file()}
    write(archive/'ARCHIVE.json',dict(status=report['status'],files_sha256=files,
            original_receipt_sha256=sha(REPORT),no_retry=True))

def execute(approved):
    check()
    assert approved==sha(SEAL),'explicit root-approved exact seal required'
    assert not REPORT.exists() and not ARTIFACTS.exists() and not LOGS.exists(),'one attempt only; never overwrite history'
    plan=read(ROOT/'TEST_PLAN.json');profiles={p['name']:p for p in plan['profiles']}
    ARTIFACTS.mkdir()
    LOGS.mkdir()
    env=os.environ.copy();suite=REPO/'tools/oss-cad-suite/oss-cad-suite'
    env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    records=[];results=[];stopped=False;terminal_timeout=False
    for index,command in enumerate(plan['children']):
        record=dict(name=command['name'],argv=command['argv'],expected=command['expected'],timeout_seconds=20)
        if stopped:
            records.append(dict(record,status='NOT_RUN',exit_code=None,elapsed_seconds=0,stdout='',stderr=''))
            continue
        start=time.monotonic()
        raw_out=b'';raw_err=b''
        try:
            kwargs=dict(cwd=command['cwd'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
            if os.name=='nt':kwargs['creationflags']=subprocess.CREATE_NEW_PROCESS_GROUP|subprocess.CREATE_NO_WINDOW
            child=subprocess.Popen(command['argv'],**kwargs)
            try:
                raw_out,raw_err=child.communicate(timeout=20)
            except subprocess.TimeoutExpired as timeout:
                raw_out=timeout.stdout or b'';raw_err=timeout.stderr or b''
                try:
                    if os.name=='nt':subprocess.run(['taskkill','/PID',str(child.pid),'/T','/F'],capture_output=True,timeout=5)
                    else:child.kill()
                except Exception as cleanup:
                    record['cleanup_error']=str(cleanup)
                    child.kill()
                try:raw_out,raw_err=child.communicate(timeout=5)
                except subprocess.TimeoutExpired as drain:
                    raw_out=drain.stdout or raw_out;raw_err=drain.stderr or raw_err
                timeout.stdout=raw_out;timeout.stderr=raw_err
                raise timeout
            record.update(exit_code=child.returncode,stdout=raw_out.decode('utf-8',errors='replace'),stderr=raw_err.decode('utf-8',errors='replace'))
            combined=record['stdout']+record['stderr']
            if command['expected']=='EXPECTED_REJECT':
                assert child.returncode>0 and command['marker'] in combined,'missing named parameter rejection'
            else:assert child.returncode==0,'unexpected child failure'
            result=validate_output(command,record['stdout'],profiles)
            if result:results.append(result)
            record['status']='PASS'
        except subprocess.TimeoutExpired as error:
            terminal_timeout=True;stopped=True
            raw_out=error.stdout or b'';raw_err=error.stderr or b''
            conv=lambda x:x.decode('utf-8',errors='replace') if isinstance(x,bytes) else x or ''
            record.update(status='TIMEOUT',exit_code=None,stdout=conv(error.stdout),stderr=conv(error.stderr),error='terminal child timeout; no retry')
        except Exception as error:
            stopped=True;record['status']='OBSERVED';record['error']=str(error)
            record.setdefault('exit_code',None);record.setdefault('stdout','');record.setdefault('stderr','')
        record['elapsed_seconds']=round(time.monotonic()-start,6)
        for stream,raw_bytes in [('stdout',raw_out),('stderr',raw_err)]:
            path=LOGS/f"{index:03d}_{command['name']}.{stream}"
            path.write_bytes(raw_bytes)
            record[stream+'_file']=path.relative_to(ROOT).as_posix()
            record[stream+'_sha256']=sha(path)
        records.append(record)
        print(command['name'],record['status'],record['elapsed_seconds'],flush=True)
    assert source_map()==read(SEAL)['files_sha256'],'sealed input changed during attempt'
    report=dict(status='TIMEOUT_TERMINAL' if terminal_timeout else 'FAIL_STOPPED' if stopped else 'UNIT_SIM_PASS',
       hardware='HW_UNVERIFIED',baseline=plan['baseline'],plan_sha256=sha(ROOT/'TEST_PLAN.json'),
       source_freeze_sha256=sha(SEAL),source_sha256=dict(read(SEAL)['files_sha256'],**{'SOURCE_FREEZE.json':sha(SEAL)}),
       terminal_timeout=terminal_timeout,timeout_seconds=20,attempt=1,totals=plan['totals'],records=records,results=results,
       max_child_seconds=max(x['elapsed_seconds'] for x in records),not_run=[x['name'] for x in records if x['status']=='NOT_RUN'])
    write(REPORT,report)
    if stopped:archive_failure(report)
    print(report['status'],sha(REPORT),flush=True)
    if stopped:raise SystemExit(1)

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    action=parser.add_mutually_exclusive_group(required=True)
    action.add_argument('--seal',action='store_true');action.add_argument('--check',action='store_true')
    action.add_argument('--execute',action='store_true');parser.add_argument('--approved-seal')
    args=parser.parse_args()
    if args.seal:freeze()
    elif args.check:check()
    else:execute(args.approved_seal)
