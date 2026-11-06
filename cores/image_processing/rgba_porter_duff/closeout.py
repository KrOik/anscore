"""SPDX-License-Identifier: Apache-2.0. Evidence-only bridge; imports no model/runner."""
from pathlib import Path
import hashlib,json,subprocess,sys

ROOT=Path(__file__).resolve().parent;REPO=ROOT.parents[2]
BASE='31a83135a22f845d85840524986895217567625c'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def rel(p):return p.resolve().relative_to(REPO).as_posix()
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n',encoding='utf8',newline='\n')
def git(*args):return subprocess.run(['git',*args],cwd=REPO,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=10,check=True).stdout

def main(stamp,plan_sha,receipt_sha):
    report=ROOT/'reports'/stamp;rp=report/'results.json';pp=ROOT/'REPAIR01_PLAN.json'
    assert not (ROOT/'B41_DELIVERY.json').exists() and not (ROOT/'QUALIFICATION.json').exists()
    assert sha(rp)==receipt_sha and sha(pp)==plan_sha
    plan=json.loads(pp.read_text());receipt=json.loads(rp.read_text())
    prior_path=Path(receipt['original_receipt']);prior=json.loads(prior_path.read_text());old_report=prior_path.parent
    old_plan=ROOT/'PRECHECK_PLAN.json';old_plan_sha=receipt['original_plan_sha256']
    assert sha(prior_path)==receipt['original_receipt_sha256']=='13d2e76588797d43a0d100ed108d761ca3169ef9aec7a922be8aefe7cf34f323'
    assert sha(old_plan)==old_plan_sha=='2e922b88e0ee903b4301027a420bdfcb503492d1a565474d6b5d889ba4dfe3fd'
    assert prior['status']=='FAIL' and len(prior['records'])==5 and [r['status'] for r in prior['records']]==['PASS']*4+['FAIL']
    assert prior['preparation_complete'] and prior['preparation_attempts']==prior['oracle_import_attempts']==prior['planning_python_calls']==1
    assert receipt['status']=='PASS' and receipt['vector_copy_complete'] and receipt['suite_complete']
    assert receipt['oracle_import_attempts']==receipt['preparation_attempts']==0
    assert receipt['repair_planning_python_calls']==1
    assert all(receipt[k] for k in ['sources_unchanged','archives_unchanged','vectors_unchanged','tools_unchanged','original_evidence_unchanged'])
    assert set(receipt['source_sha256'])==set(plan['source_sha256'])|{'REPAIR01_PLAN.json'}
    current={};archives={};mapping=[];vectors={};raw={};tools={};dependencies={}
    for n,digest in receipt['source_sha256'].items():
        p=(ROOT/n).resolve();a=report/receipt['exact_checked_copies'][n]
        assert sha(p)==sha(a)==digest and p.read_bytes()==a.read_bytes()
        if n!='REPAIR01_PLAN.json':assert plan['source_sha256'][n]==digest
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
    assert len(current)==len(archives)==19 and len(dependencies)==1
    historical_archives={};current_exceptions=[]
    for n,digest in prior['source_sha256'].items():
        a=old_report/prior['exact_checked_copies'][n];assert sha(a)==digest;historical_archives[rel(a)]=digest
        p=(ROOT/n).resolve()
        if sha(p)!=digest:
            current_exceptions.append(n)
            assert n=='rtl/rgba_porter_duff.sv'
            assert p.read_bytes()==a.read_bytes().replace(b'always @* begin',b'always_comb begin',1)
    assert current_exceptions==['rtl/rgba_porter_duff.sv'] and len(historical_archives)==17
    assert receipt['tools']==plan['tool_sha256']
    for n,digest in receipt['tools'].items():assert sha(Path(n))==digest;tools[n]=digest
    records=receipt['records'];assert len(records)==len(plan['checks'])==9
    assert [r['name'] for r in records]==plan['expected_checks']==receipt['expected_checks']
    simulations=[]
    for r,c in zip(records,plan['checks']):
        assert r['status']=='PASS' and r['returncode']==0 and not r['cleanup'] and 0<=r['seconds']<=20
        assert r['argv']==[a.replace('<stamp>',stamp) for a in c['argv']] and r['cwd']==c['cwd'].replace('<stamp>',stamp)
        for key in ['execution_deadline_seconds','tree_kill_seconds','drain_seconds']:assert r[key]==c[key]
        for suffix in ['stdout','stderr']:
            p=report/(r['name']+'.'+suffix+'.txt');assert sha(p)==r[suffix+'_sha256'];raw[rel(p)]=sha(p)
        if c['marker']:
            out=(report/(r['name']+'.stdout.txt')).read_text();lines=[l for l in out.splitlines() if l.startswith(c['marker'])]
            assert len(lines)==1 and '$finish' in out and (report/(r['name']+'.stderr.txt')).read_bytes()==b''
            counters={k:int(v) for word in lines[0].split() if '=' in word for k,v in [word.split('=',1)]}
            assert counters==r['counters'] and all(counters[k]==v for k,v in c['expected_counters'].items())
            assert counters['holds']>0 and counters['gaps']>0;simulations.append(r)
    assert len(raw)==18 and len(simulations)==4
    for r in prior['records']:
        for suffix in ['stdout','stderr']:
            p=old_report/(r['name']+'.'+suffix+'.txt');assert sha(p)==r[suffix+'_sha256'];raw[rel(p)]=sha(p)
    assert len(raw)==28
    for profile,sim,declared in zip(receipt['profiles'],simulations,plan['profiles']):
        assert all(profile[k]==v for k,v in declared.items())
        for n,digest in profile['vectors_sha256'].items():
            p=report/profile['name']/n;assert sha(p)==digest;vectors[rel(p)]=digest
        values={n:[int(l,16) for l in (report/profile['name']/n).read_text().splitlines()] for n in profile['vectors_sha256']}
        if profile['kind']=='core':
            assert len(values['input.hex'])==len(values['golden.hex'])==2048 and values['counts.hex']==[2048]
            assert sum(profile['modes'])==sum(profile['errors'])==2048 and all(profile['modes']) and all(profile['errors'])
            assert sum(1 for v in values['golden.hex'] if (v>>32)&3)==sum(profile['errors'][1:])
        else:
            p=profile['w']*profile['h'];assert len(values['query.hex'])==len(values['golden.hex'])==512
            assert len(values['tex0.hex'])==len(values['tex1.hex'])==2*p
            assert len(values['pal0.hex'])==len(values['pal1.hex'])==512 and values['counts.hex']==[256,p]
        assert all(sim['counters'][k]==v for k,v in profile['expected_counters'].items())
    assert len(vectors)==20 and receipt['arithmetic_audit']==dict(quantizer_totals=130051,alpha_mode_pairs=851968,extrema_checks=3407872,premultiply_pairs=65536)
    original_vectors={}
    for profile in prior['profiles']:
        for n,digest in profile['vectors_sha256'].items():
            p=old_report/profile['name']/n;assert sha(p)==digest;original_vectors[rel(p)]=digest
            assert (report/profile['name']/n).read_bytes()==p.read_bytes()
    assert len(original_vectors)==20 and prior['arithmetic_audit']==receipt['arithmetic_audit']
    images={rel(p):sha(p) for p in sorted((ROOT/'.build'/stamp).glob('*.vvp'))}
    failed_image=Path(receipt['failed_image']);assert sha(failed_image)==receipt['failed_image_sha256']=='6cca25e54e804626620567151e37f6fb9c98b8df51550aa77d53035dfdcebbc3'
    failed_images={rel(failed_image):sha(failed_image)}
    assert len(images)==4 and len(list((ROOT/'.build').rglob('*.vvp')))==5 and not (ROOT/'__pycache__').exists()
    coverage=dict(total_output_records=sum(s['counters']['checked'] for s in simulations),core_output_records=8192,
        actual_composed_output_records=1032,reset_events=14,initial_resets=4,live_resets=10,
        quantizer_hdl_checks=260102,arithmetic_preparation=receipt['arithmetic_audit'],successful_profiles=4,
        total_held_output_cycles=sum(s['counters']['holds'] for s in simulations),source_gap_cycles=sum(s['counters']['gaps'] for s in simulations),
        management_commands=18,management_responses_retired=16,management_responses_reset_while_held=2,
        pending_management_drains=2,maximum_profile='Two 256x256 palettes/index banks, TAG28, syntax only')
    assert coverage['total_output_records']==9224
    status=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED']
    manifest=json.loads((ROOT/'manifest.json').read_text());manifest['maturity']=status;manifest['receipt']=rel(rp)
    manifest['validation']='Explicit repair01 9/9 children and4/4 simulations PASS;9224 exact outputs. Original4PASS/1FAIL retained;one-line coefficient startup repair. Maximum storage syntax only';write(ROOT/'manifest.json',manifest)
    (ROOT/'STATUS.md').write_text('# B41 status\n\nLINT_PASS, UNIT_SIM_PASS, INTEGRATION_CANDIDATE, HW_UNVERIFIED. Original authorized run stopped at4PASS/1FAIL: first clear token had unknown RGBA because always @* did not guarantee initial coefficient evaluation. Independently reviewed one-line always_comb repair01 passed9/9 children and4/4 simulations with9224 exact output records. Original oracle import1/preparation1 and20 vectors reused without further numerical execution. Original planning Python1, repair planning Python1, evidence-only closeout Python1. Total14 HDL children:13PASS/1FAIL;5 simulations:4PASS/1FAIL. No timeout or automatic retry/cleanup. Four successful images and the original failed image retained. Maximum storage syntax only. No synthesis/PnR/STA/board/inherited/combined regression. See QUALIFICATION.json and B41_DELIVERY.json.\n',encoding='utf8',newline='\n')
    qualification=dict(schema='anscore-b41-rgba-independent-qualification-v1',status='PASS',baseline=BASE,
        receipt=rel(rp),receipt_sha256=receipt_sha,plan=rel(pp),plan_sha256=plan_sha,
        effective_finite_checks=9,successful_simulations=4,planning_python_calls=1,repair_planning_python_calls=1,oracle_import_attempts=1,
        preparation_attempts=1,repair_oracle_import_attempts=0,repair_preparation_attempts=0,closeout_python_calls=1,historical_hdl_failures=1,
        total_hdl_child_executions=14,total_pass_children=13,total_fail_children=1,total_simulation_executions=5,automatic_retry=False,timeout_count=0,cleanup_count=0,
        current_inputs=current,source_archive=archives,source_mapping=mapping,numerical_vectors=vectors,raw_streams=raw,tools=tools,
        original_receipt=rel(prior_path),original_receipt_sha256=sha(prior_path),original_plan=rel(old_plan),original_plan_sha256=old_plan_sha,
        original_source_archive=historical_archives,original_numerical_vectors=original_vectors,prior_current_source_exceptions=current_exceptions,
        failed_vvps_to_retain=failed_images,prior_successful_vvp_images={},
        all_hashes_independently_verified=True,exact_argv_cwd_markers_order_verified=True,legacy_dependencies=dependencies,
        coverage=coverage,maximum_child_seconds=max(r['seconds'] for r in records),simulation_stderr='empty all four simulations',
        synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',old_regression='NOT_RUN',hardware='HW_UNVERIFIED')
    qp=ROOT/'QUALIFICATION.json';write(qp,qualification)
    metadata=['README.md','ARCHITECTURE.md','SOURCES.md','STATUS.md','manifest.json','references.json','LICENSE','.gitattributes','closeout.py','QUALIFICATION.json']
    delivery=dict(schema='anscore-b41-worker-c-delivery-v1',name='rgba_porter_duff',package_root=rel(ROOT),baseline=BASE,
        new_capability='13-mode premultiplied RGBA Porter-Duff with retained transparent destination coverage plus actual owned dual indexed-texture composition',
        status=status,receipt=rel(rp),receipt_sha256=receipt_sha,plan=rel(pp),plan_sha256=plan_sha,qualification=rel(qp),qualification_sha256=sha(qp),
        effective_finite_checks=9,successful_simulations=4,current_qualification_pass_children=9,current_qualification_successful_simulations=4,
        historical_hdl_failures=1,total_hdl_child_executions=14,total_simulation_executions=5,total_pass_children=13,total_fail_children=1,
        prior_failures=[dict(receipt=rel(prior_path),receipt_sha256=sha(prior_path),pass_children=4,fail_children=1,
            failed_child='sim_core_t1',reason='first all-zero clear token RGBA X; coefficient always @* lacked guaranteed startup evaluation',
            failed_image=rel(failed_image),failed_image_sha256=sha(failed_image))],
        repairs=[dict(plan=rel(pp),plan_sha256=plan_sha,receipt=rel(rp),receipt_sha256=receipt_sha,pass_children=9,successful_simulations=4,
            change='Only coefficient always @* -> always_comb; original model/TBs/vectors unchanged',oracle_imports=0,numerical_preparations=0,
            review='NO_BLOCKER_B + NO_BLOCKER_ROOT; explicit external root first-execution authorization of exact plan')],
        planning_python_calls=1,repair_planning_python_calls=1,oracle_import_attempts=1,preparation_attempts=1,repair_oracle_import_attempts=0,repair_preparation_attempts=0,closeout_python_calls=1,
        source_mapping=mapping,current_source_sha256=current,source_archive=archives,numerical_vectors=vectors,raw_streams=raw,tools=tools,
        original_receipt=rel(prior_path),original_receipt_sha256=sha(prior_path),original_plan=rel(old_plan),original_plan_sha256=old_plan_sha,
        original_source_archive=historical_archives,original_numerical_vectors=original_vectors,prior_current_source_exceptions=current_exceptions,
        legacy_dependencies=dependencies,coverage=coverage,delivery_metadata_sha256={rel(ROOT/n):sha(ROOT/n) for n in metadata},
        successful_vvps_for_root_cleanup=images,prior_successful_vvp_images={},failed_vvps_to_retain=failed_images,absolute_cleanup_inventory={str(REPO/n):h for n,h in images.items()},
        cleanup_performed_by_worker=False,staging_or_commit_performed_by_worker=False,
        architecture_risk=dict(default='MEDIUM',maximum='HIGH',new_arithmetic_ram_bits=0,default_two_sampler_ram_bits=17408,
            maximum_two_sampler_ram_bits=1064960,core_byte_multipliers=8,adapter_byte_multipliers=6,conceptual_total_byte_multipliers=14,
            physical_DSPs='UNMEASURED',fmax='UNMEASURED',device_fit='UNMEASURED'),
        limitations=['Exact integer code-space arithmetic;no gamma/color-management or straight-alpha output division',
            'Additional straight-to-premult conversion quantization;not bit-exact floating Skia',
            'II1 burst structure only;backpressure unbounded;hardware throughput unmeasured',
            'Maximum two256x256 storage HIGH risk;syntax only','No synthesis/PnR/STA/board/inherited regression'])
    dp=ROOT/'B41_DELIVERY.json';write(dp,delivery)
    for group in [current,archives,historical_archives,vectors,original_vectors,raw,images,failed_images,delivery['delivery_metadata_sha256']]:
        for n,h in group.items():assert sha(REPO/n)==h
    assert sha(pp)==plan_sha and sha(rp)==receipt_sha
    print(json.dumps(dict(delivery_sha256=sha(dp),qualification_sha256=sha(qp),receipt_sha256=receipt_sha,
        inputs=len(current),archives=len(archives),vectors=len(vectors),raw=len(raw),tools=len(tools),images=len(images),oracle_imports_by_closeout=0,hdl_children_by_closeout=0)))

if __name__=='__main__':
    if len(sys.argv)!=4:raise SystemExit('closeout.py STAMP EXECUTED_PLAN_SHA RECEIPT_SHA')
    main(*sys.argv[1:])
