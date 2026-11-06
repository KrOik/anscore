"""SPDX-License-Identifier: Apache-2.0. Evidence-only bridge; no model/runner imports."""
from pathlib import Path
import hashlib,json,subprocess,sys

ROOT=Path(__file__).resolve().parent;REPO=ROOT.parents[2]
BASE='2e7a6fb51f32e525c1026c28d1f2f45e36545ebc'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def rel(p):return p.resolve().relative_to(REPO).as_posix()
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n',encoding='utf8',newline='\n')
def git(*args):return subprocess.run(['git',*args],cwd=REPO,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=10,check=True).stdout

def main(stamp,plan_sha,receipt_sha):
    report=ROOT/'reports'/stamp;rp=report/'results.json';pp=ROOT/'PRECHECK_PLAN.json'
    assert not (ROOT/'B42_DELIVERY.json').exists() and not (ROOT/'QUALIFICATION.json').exists()
    assert sha(rp)==receipt_sha and sha(pp)==plan_sha
    plan=json.loads(pp.read_text());receipt=json.loads(rp.read_text())
    assert plan['baseline']==BASE and receipt['status']=='PASS' and receipt['suite_complete']
    assert receipt['preparation_complete'] and receipt['oracle_import_attempts']==receipt['preparation_attempts']==receipt['planning_python_calls']==1
    assert receipt['exception'] is None and receipt['automatic_retry'] is False and receipt['fail_stop'] is True
    assert all(receipt[k] for k in ['sources_unchanged','archives_unchanged','vectors_unchanged','tools_unchanged'])
    assert set(receipt['source_sha256'])==set(plan['source_sha256'])|{'PRECHECK_PLAN.json'}
    current={};archives={};mapping=[];vectors={};raw={};dependencies={}
    for n,digest in receipt['source_sha256'].items():
        p=(ROOT/n).resolve();a=report/receipt['exact_checked_copies'][n]
        assert sha(p)==sha(a)==digest and p.read_bytes()==a.read_bytes()
        assert a.name.endswith('.executed.txt')
        if n!='PRECHECK_PLAN.json':assert plan['source_sha256'][n]==digest
        current[rel(p)]=digest;archives[rel(a)]=digest
        mapping.append(dict(current=rel(p),checked_archive=rel(a),sha256=digest,raw_bytes_equal=True))
        if n.startswith('../'):
            dep=rel(p);oid=git('rev-parse',BASE+':'+dep).decode().strip();baseline=git('cat-file','blob',oid)
            clean=git('hash-object','--path='+dep,str(p)).decode().strip();raw_oid=git('hash-object','--no-filters','--',str(p)).decode().strip()
            assert clean==oid and p.read_bytes().replace(b'\r\n',b'\n')==baseline.replace(b'\r\n',b'\n')
            dependencies[dep]=dict(current_raw_sha256=digest,current_raw_blob_oid=raw_oid,baseline_blob_oid=oid,
                baseline_blob_sha256=hashlib.sha256(baseline).hexdigest(),git_hash_object_path_clean_oid=clean,
                baseline_clean_oid_matches=True,raw_bytes_equal_baseline=p.read_bytes()==baseline,
                exact_checked_archive=rel(a),exact_checked_archive_sha256=digest,
                normalization='none' if p.read_bytes()==baseline else 'CRLF to LF only')
    assert len(current)==len(archives)==15 and len(dependencies)==1
    assert (ROOT/'.gitattributes').read_bytes()==b'* -text\n'
    assert receipt['tools']==plan['tool_sha256'] and len(receipt['tools'])==2
    for n,digest in receipt['tools'].items():assert sha(Path(n))==digest
    records=receipt['records'];assert len(records)==len(plan['checks'])==11
    assert [r['name'] for r in records]==plan['expected_checks']==receipt['expected_checks']
    simulations=[];diagnostics=[]
    for r,c in zip(records,plan['checks']):
        assert r['status']=='PASS' and r['returncode']==0 and not r['cleanup'] and 0<=r['seconds']<=20
        assert r['argv']==[a.replace('<stamp>',stamp) for a in c['argv']] and r['cwd']==c['cwd'].replace('<stamp>',stamp)
        for key in ['execution_deadline_seconds','tree_kill_seconds','drain_seconds']:assert r[key]==c[key]
        for suffix in ['stdout','stderr']:
            p=report/(r['name']+'.'+suffix+'.txt');assert sha(p)==r[suffix+'_sha256'];raw[rel(p)]=sha(p)
        stderr=(report/(r['name']+'.stderr.txt')).read_text()
        if stderr:diagnostics.append(dict(child=r['name'],text=stderr))
        if c['marker']:
            out=(report/(r['name']+'.stdout.txt')).read_text();lines=[l for l in out.splitlines() if l.startswith(c['marker'])]
            assert len(lines)==1 and '$finish' in out and stderr==''
            counters={k:int(v) for word in lines[0].split() if '=' in word for k,v in [word.split('=',1)]}
            assert counters==r['counters'] and all(counters[k]==v for k,v in c['expected_counters'].items())
            assert counters['holds']>0 and counters['gaps']>0 and counters['rows']>0;simulations.append(r)
    assert len(raw)==22 and len(simulations)==4
    for profile,sim,declared in zip(receipt['profiles'],simulations,plan['profiles']):
        assert all(profile[k]==v for k,v in declared.items()) and len(profile['per_case'])==16
        for n,digest in profile['vectors_sha256'].items():
            p=report/profile['name']/n;assert sha(p)==digest;vectors[rel(p)]=digest
        values={n:(report/profile['name']/n).read_text().splitlines() for n in profile['vectors_sha256']}
        w,h,l,r=map(profile.get,['w','h','l','r']);an=w*h;sn=(l+w+r)*h
        assert len(values['config.hex'])==len(values['done.hex'])==16 and len(values['sensor.hex'])==16*sn
        assert len(values['golden.hex'])==16*an and len(values['rows.hex'])==16*h
        assert [int(v,16) for v in values['counts.hex']]==[16,sn,an,profile['checked']]
        assert profile['checked']==2*sum(c['pixels'] for c in profile['per_case'])+4*an
        assert all(sim['counters'][k]==v for k,v in profile['expected_counters'].items())
    assert len(vectors)==24 and receipt['arithmetic_audit']==plan['declared_arithmetic_audit']==dict(mean_pairs=2837040,max_sum=131040,max_rounded_numerator=131056)
    images={rel(p):sha(p) for p in sorted((ROOT/'.build'/stamp).glob('*.vvp'))}
    assert len(images)==4 and len(list((ROOT/'.build').rglob('*.vvp')))==4 and not (ROOT/'__pycache__').exists()
    coverage=dict(total_output_records=sum(s['counters']['checked'] for s in simulations),
        core_output_records=sum(s['counters']['checked'] for s in simulations if s['counters']['WRAP']==0),
        actual_composed_output_records=sum(s['counters']['checked'] for s in simulations if s['counters']['WRAP']==1),
        commands=sum(s['counters']['commands'] for s in simulations),done_responses=sum(s['counters']['done'] for s in simulations),
        reset_events=sum(s['counters']['resets'] for s in simulations),initial_resets=4,live_resets=16,
        cancelled_commands=sum(s['counters']['cancelled'] for s in simulations),
        row_configuration_checks=sum(s['counters']['rows'] for s in simulations),
        total_held_output_cycles=sum(s['counters']['holds'] for s in simulations),source_gap_cycles=sum(s['counters']['gaps'] for s in simulations),
        arithmetic_preparation=receipt['arithmetic_audit'],successful_profiles=4,
        maximum_profile='WIDTH512 HEIGHT128 RAW12 LEFT32 RIGHT32 TAG32 core and actual composition syntax only')
    assert coverage['total_output_records']==9898 and coverage['core_output_records']==4202 and coverage['actual_composed_output_records']==5696
    assert coverage['commands']==160 and coverage['done_responses']==144 and coverage['reset_events']==20 and coverage['cancelled_commands']==16
    maturity=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED']
    manifest=json.loads((ROOT/'manifest.json').read_text());manifest['maturity']=maturity;manifest['receipt']=rel(rp)
    manifest['validation']='Frozen11/11 children and4/4 simulations PASS;9898 exact output records. One2837040-pair arithmetic audit and24-vector preparation. Maximum geometry syntax only';write(ROOT/'manifest.json',manifest)
    (ROOT/'STATUS.md').write_text('# B42 status\n\nLINT_PASS, UNIT_SIM_PASS, INTEGRATION_CANDIDATE, HW_UNVERIFIED. Independent B/root review and explicit root first-run gate preceded the unique frozen run. All11 children and4 simulations PASS,9898 exact output records (4202 core,5696 actual unchanged-BLC composition),160 commands,144 retired DONEs,20 resets including16 live cuts,16 cancelled commands and508 row-config checks. One planning Python,one oracle import/preparation (2837040 mean pairs,24 vectors),one evidence-only closeout Python. No failure,timeout,automatic retry or cleanup. All four images retained. Maximum512x128 RAW12+32/32 margins syntax only. No synthesis/PnR/STA/board/image-quality/old/combined regression. Caller guarantees physical optical shielding; entire frame remains provisional until successful DONE. See QUALIFICATION.json and B42_DELIVERY.json.\n',encoding='utf8',newline='\n')
    qualification=dict(schema='anscore-b42-optical-black-independent-qualification-v1',status='PASS',baseline=BASE,
        receipt=rel(rp),receipt_sha256=receipt_sha,plan=rel(pp),plan_sha256=plan_sha,effective_finite_checks=11,successful_simulations=4,
        planning_python_calls=1,oracle_import_attempts=1,preparation_attempts=1,closeout_python_calls=1,
        historical_hdl_failures=0,total_hdl_child_executions=11,total_pass_children=11,total_fail_children=0,total_simulation_executions=4,
        automatic_retry=False,timeout_count=0,cleanup_count=0,current_inputs=current,source_archive=archives,source_mapping=mapping,
        numerical_vectors=vectors,raw_streams=raw,tools=receipt['tools'],legacy_dependencies=dependencies,
        all_hashes_independently_verified=True,exact_argv_cwd_markers_order_verified=True,coverage=coverage,
        maximum_child_seconds=max(r['seconds'] for r in records),simulation_stderr='empty all four simulations',compiler_diagnostics=diagnostics,
        images_sha256=images,image_hash_capture='Evidence-only closeout after the frozen suite; no further image execution',
        synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',old_regression='NOT_RUN',hardware='HW_UNVERIFIED')
    qp=ROOT/'QUALIFICATION.json';write(qp,qualification)
    metadata=['README.md','ARCHITECTURE.md','SOURCES.md','STATUS.md','manifest.json','references.json','LICENSE','.gitattributes','closeout.py','QUALIFICATION.json']
    delivery=dict(schema='anscore-b42-worker-c-delivery-v1',name='raw_optical_black_rows',package_root=rel(ROOT),baseline=BASE,
        new_capability='Same-row qualified physical-parity optical-black measurement plus active crop and fully drained actual unchanged manual-BLC correction',
        status=maturity,receipt=rel(rp),receipt_sha256=receipt_sha,plan=rel(pp),plan_sha256=plan_sha,qualification=rel(qp),qualification_sha256=sha(qp),
        effective_finite_checks=11,successful_simulations=4,current_qualification_pass_children=11,current_qualification_successful_simulations=4,
        historical_hdl_failures=0,total_hdl_child_executions=11,total_simulation_executions=4,total_pass_children=11,total_fail_children=0,
        prior_evidence=dict(receipts=[],failed_images={},historical_hdl_failures=0),prior_failures=[],repairs=[],
        planning_python_calls=1,oracle_import_attempts=1,preparation_attempts=1,closeout_python_calls=1,
        source_mapping=mapping,current_source_sha256=current,source_archive=archives,numerical_vectors=vectors,raw_streams=raw,tools=receipt['tools'],
        legacy_dependencies=dependencies,coverage=coverage,delivery_metadata_sha256={rel(ROOT/n):sha(ROOT/n) for n in metadata},
        successful_vvps_for_root_cleanup=images,prior_successful_vvp_images={},failed_vvps_to_retain={},
        absolute_cleanup_inventory={str(REPO/n):h for n,h in images.items()},cleanup_performed_by_worker=False,staging_or_commit_performed_by_worker=False,
        review='NO_BLOCKER_B plus independent root read-only gate; explicit external root first-run authorization of exact frozen plan',
        architecture_risk=dict(default_storage='LOW',control_service='MEDIUM',default_row_ram_bits=1280,maximum_row_ram_bits=6144,
            shared_divider_bits=17,iterations_per_mean=17,physical_DSPs='UNMEASURED',fmax='UNMEASURED',device_fit='UNMEASURED'),
        limitations=['Caller guarantees physically shielded margins; qualified dark pixels alone do not prove optical shielding',
            'All rows provisional until successful DONE; any error/reset discards the whole frame; no rollback/frame buffer',
            'Input capture pauses for means and replay; II1 output bursts only; unbounded backpressure; hardware throughput unmeasured',
            'Public synchronous-high reset adapts unchanged BLC internal asynchronous-low reset',
            'Maximum geometry syntax only; no synthesis/PnR/STA/board/image-quality/old/combined regression'])
    dp=ROOT/'B42_DELIVERY.json';write(dp,delivery)
    for group in [current,archives,vectors,raw,images,delivery['delivery_metadata_sha256']]:
        for n,h in group.items():assert sha(REPO/n)==h
    assert sha(pp)==plan_sha and sha(rp)==receipt_sha
    print(json.dumps(dict(delivery_sha256=sha(dp),qualification_sha256=sha(qp),receipt_sha256=receipt_sha,
        inputs=len(current),archives=len(archives),vectors=len(vectors),raw=len(raw),tools=len(receipt['tools']),images=len(images),oracle_imports_by_closeout=0,hdl_children_by_closeout=0)))

if __name__=='__main__':
    if len(sys.argv)!=4:raise SystemExit('closeout.py STAMP EXECUTED_PLAN_SHA RECEIPT_SHA')
    main(*sys.argv[1:])
