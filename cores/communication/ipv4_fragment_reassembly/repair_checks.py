"""SPDX-License-Identifier: Apache-2.0. Explicit two-child example repair only."""
from pathlib import Path
import datetime,hashlib,json,os,re,shutil,sys,traceback
import run_checks as original
ROOT=original.ROOT
OLD=ROOT/'reports/20261106T054308266995Z'
PLAN=ROOT/'EXAMPLE_REPAIR_PLAN.json'
SOURCES=original.SOURCES+['repair_checks.py']
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def commands(stamp):
    return original.commands(stamp)[-2:]
def prepare():
    assert not PLAN.exists()
    receipt=json.loads((OLD/'results.json').read_bytes())
    assert receipt['status']=='FAIL'and len(receipt['checks'])==11
    assert all(x['status']=='PASS'for x in receipt['checks'][:-1])
    assert receipt['checks'][-1]['name']=='sim_n80_t8_e1'
    raw=(OLD/'n80_t8_e1.txt').read_text();lines=raw.splitlines(keepends=True);changed=0
    for i,line in enumerate(lines):
        words=line.split()
        if len(words)==18 and words[0]=='0'and words[1]=='0'and words[8]=='0':
            assert words[11]=='2';words[11]='8';lines[i]=' '.join(words)+'\n';changed+=1
    assert changed==1
    data=''.join(lines).encode()
    counts=json.loads((OLD/'plan.json').read_bytes())['profiles'][-1]['counts']
    counts['status2']-=1;counts['status8']+=1;counts['header_rejects']+=1
    plan=dict(schema='anscore-b39-ipv4-example-repair-plan-v1',source_review='PENDING_A',
      baseline_commit='1e9e9130cef71127d2c8d2762affe815b067b9f5',
      original_receipt='reports/20261106T054308266995Z/results.json',original_receipt_sha256=sha(OLD/'results.json'),
      original_failed_image='.work/20261106T054308266995Z/n80_t8_e1.vvp',
      original_failed_image_sha256='011c366e784204b79e76718e4980959b9db67e4a2314b2d2bbb332d0db56c12c',
      cause='Reference-vector precedence: fixed20-byte total_length20 is BAD_HEADER8, not decoded RANGE2.',
      changes='Only vector_plan valid_header includes length>=1; RTL, TB and original runner byte-identical.',
      expected_vector_sha256=hashlib.sha256(data).hexdigest(),expected_vector_bytes=len(data),counts=counts,
      executable_sources={n:sha(ROOT/n)for n in SOURCES},tools={str(original.BIN/n):sha(original.BIN/n)for n in ['iverilog.exe','vvp.exe']},
      checks=commands('<stamp>'),expected_checks=[x['name']for x in commands('<stamp>')],
      expected_children=2,successful_simulations_if_pass=1,automatic_retry=False,fail_stop=True,
      preparation_calls_before_archive=0,preparation_calls_after_archive=1,
      scope='One explicit example compile/sim only; no successful original profile rerun.')
    PLAN.write_bytes((json.dumps(plan,indent=2)+'\n').encode());print('repair plan',sha(PLAN))
def main():
    if sys.argv[1:]==['--prepare-plan']:prepare();return 0
    assert sys.argv[1:]==['--execute-reviewed-repair']
    assert len(list((ROOT/'reports').iterdir()))==1,'Repair already started: no rerun'
    plan=json.loads(PLAN.read_bytes());assert plan['source_review']=='NO_BLOCKER_A'
    assert plan['checks']==commands('<stamp>')
    assert all(sha(ROOT/n)==h for n,h in plan['executable_sources'].items())
    assert sha(OLD/'results.json')==plan['original_receipt_sha256']
    assert sha(ROOT/plan['original_failed_image'])==plan['original_failed_image_sha256']
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    out=ROOT/'reports'/stamp;out.mkdir();(ROOT/'.work'/stamp).mkdir(parents=True)
    report=dict(schema=plan['schema'],status='INCOMPLETE',source_sha256={},archived_sources={},checks=[],profiles=[],
      plan_sha256=sha(PLAN),baseline_commit=plan['baseline_commit'],tools=plan['tools'],automatic_retry=False,
      phase='SOURCE_ARCHIVE',active_child=None,archive_complete=False,preparation_completed_calls=0,
      original_receipt=plan['original_receipt'],original_receipt_sha256=plan['original_receipt_sha256'],
      original_failure_retained=True,original_passed_profiles_not_rerun=True,
      synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',hardware='HW_UNVERIFIED')
    def save():
        p=out/'results.json.tmp'
        with p.open('w',encoding='utf-8',newline='\n')as f:json.dump(report,f,indent=2);f.write('\n');f.flush();os.fsync(f.fileno())
        p.replace(out/'results.json')
    save()
    try:
        shutil.copyfile(PLAN,out/'plan.json')
        for n in SOURCES:
            src=(ROOT/n).resolve();target=out/'executed_inputs'/src.relative_to(original.REPO)
            target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(src,target)
            report['source_sha256'][n]=sha(target);report['archived_sources'][n]=target.relative_to(ROOT).as_posix()
        report['archive_complete']=True;report['phase']='VECTOR_PREPARATION';save()
        from vector_plan import vectors
        data,counts=vectors(80,8,1);v=out/'n80_t8_e1.txt';v.write_bytes(data.encode())
        report['preparation_completed_calls']=1
        assert sha(v)==plan['expected_vector_sha256']and counts==plan['counts']
        report['profiles']=[dict(label='n80_t8_e1',parameters=[80,8,1],vector=v.name,
             vector_sha256=sha(v),vector_bytes=v.stat().st_size,counts=counts)]
        for spec in commands(stamp):
            report.update(phase='HDL_CHILD',active_child=spec['name']);save()
            rec=original.execute(spec,dict(os.environ,PATH=str(original.BIN)+os.pathsep+str(original.BIN.parent/'lib')+os.pathsep+os.environ.get('PATH','')),out)
            if rec['status']=='PASS'and spec['marker']:
                line=next(x for x in(out/(spec['name']+'.stdout.txt')).read_text().splitlines()if x.startswith(spec['marker']))
                rec['observed']={k:int(v)for k,v in re.findall(r'(\w+)=(\d+)',line)}
                expected=dict(N=80,T=8,EX=1,commands=counts['commands']+21,
                  inputs=counts['input_bytes']+20,replays=counts['replay_bytes']+16,
                  resets=counts['resets']+7,future=1)
                if not all(rec['observed'].get(k)==v for k,v in expected.items()):
                    rec.update(status='FAIL_COVERAGE',expected_coverage=expected)
            report['checks'].append(rec);report['active_child']=None;save();print(spec['name'],rec['status'],flush=True)
            if rec['status']!='PASS':report['status']=rec['status'];break
        else:report['status']='PASS'
    except Exception:
        report.update(status='RUNNER_FAILED',exception=traceback.format_exc());raise
    finally:
        unchanged=report['archive_complete']and all(sha(ROOT/n)==h==sha(ROOT/report['archived_sources'][n])for n,h in report['source_sha256'].items())
        stable=sha(PLAN)==report['plan_sha256']==sha(out/'plan.json')
        tools_stable=all(sha(Path(n))==h for n,h in plan['tools'].items())
        vector_stable=all(sha(out/p['vector'])==p['vector_sha256']for p in report['profiles'])
        sequence=[x['name']for x in report['checks']]==plan['expected_checks']
        ok=report['status']=='PASS'and unchanged and stable and tools_stable and vector_stable and sequence
        report.update(sources_unchanged=unchanged,archive_unchanged=unchanged,plan_unchanged=stable,
          tools_unchanged=tools_stable,vectors_unchanged=vector_stable,check_sequence_matches=sequence,
          suite_complete=ok,phase='COMPLETE'if ok else'STOPPED')
        if report['status']=='PASS'and not ok:report['status']='INPUT_CHANGED_OR_INCOMPLETE'
        save();print(out.relative_to(ROOT).as_posix(),flush=True)
    return 0 if report['suite_complete']else 1
if __name__=='__main__':sys.exit(main())
