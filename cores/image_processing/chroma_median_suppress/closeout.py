"""SPDX-License-Identifier: Apache-2.0. Evidence-only audit; imports no oracle/runner."""
from pathlib import Path
import hashlib,json,subprocess

ROOT=Path(__file__).resolve().parent;REPO=ROOT.parents[2]
BASE='a68ca46815777c15c638c42a03899c83385bf052'
STAMP='20261106T063409208470Z';REPORT=ROOT/'reports'/STAMP
PLAN_SHA='3c869b669e5d1f8fa3bad614c8cef79830ae4e4625a28d5b336157749f23bf10'
RECEIPT_SHA='c297a2bf2d2dabdc88f90fc9a3bdf2d79b885a266b889a9136414aad407326b7'

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def rel(path):return path.resolve().relative_to(REPO).as_posix()
def git(*args):
    result=subprocess.run(['git',*args],cwd=REPO,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=10,check=True)
    return result.stdout
def write(path,value):path.write_text(json.dumps(value,indent=2)+'\n',encoding='utf8',newline='\n')

def main():
    assert not (ROOT/'B40_DELIVERY.json').exists() and not (ROOT/'QUALIFICATION.json').exists()
    plan_path=ROOT/'PRECHECK_PLAN.json';receipt_path=REPORT/'results.json'
    assert sha(plan_path)==PLAN_SHA and sha(receipt_path)==RECEIPT_SHA
    plan=json.loads(plan_path.read_text());receipt=json.loads(receipt_path.read_text())
    assert receipt['status']=='PASS' and receipt['preparation_complete'] and receipt['suite_complete']
    assert receipt['preparation_attempts']==receipt['oracle_import_attempts']==receipt['planning_python_calls']==1
    assert all(receipt[key] for key in ['sources_unchanged','archives_unchanged','vectors_unchanged','tools_unchanged'])
    assert set(receipt['source_sha256'])==set(plan['source_sha256'])|{'PRECHECK_PLAN.json'}
    assert len(receipt['source_sha256'])==14 and len(plan['source_sha256'])==13
    current={};archives={};vectors={};raw={};tools={};dependencies={}
    for name,digest in receipt['source_sha256'].items():
        path=(ROOT/name).resolve();archive=REPORT/receipt['exact_checked_copies'][name]
        assert sha(path)==sha(archive)==digest
        assert path.read_bytes()==archive.read_bytes()
        if name!='PRECHECK_PLAN.json':assert plan['source_sha256'][name]==digest
        current[rel(path)]=digest;archives[rel(archive)]=digest
        if name.startswith('../../'):
            dep=rel(path);baseline_oid=git('rev-parse',BASE+':'+dep).decode().strip()
            baseline_bytes=git('cat-file','blob',baseline_oid)
            raw_oid=git('hash-object','--no-filters','--',str(path)).decode().strip()
            clean_oid=git('hash-object','--path='+dep,str(path)).decode().strip()
            assert clean_oid==baseline_oid
            normalized=path.read_bytes().replace(b'\r\n',b'\n')
            assert normalized==baseline_bytes
            dependencies[dep]=dict(current_raw_sha256=digest,current_raw_blob_oid=raw_oid,
                baseline_blob_oid=baseline_oid,baseline_blob_sha256=hashlib.sha256(baseline_bytes).hexdigest(),
                git_hash_object_path_clean_oid=clean_oid,baseline_clean_oid_matches=True,
                raw_bytes_equal_baseline=path.read_bytes()==baseline_bytes,
                exact_checked_archive=rel(archive),exact_checked_archive_sha256=digest,
                normalization='CRLF to LF only' if path.read_bytes()!=baseline_bytes else 'none')
    assert len(dependencies)==5
    coefficient=dependencies['cores/signal_processing/dsp_isp_library/isp/csc_coeffs.vh']
    assert not coefficient['raw_bytes_equal_baseline']
    assert coefficient['baseline_blob_oid']=='daefd533e25eba8fb846600993fe39c2ad400b05'
    assert sum(d['raw_bytes_equal_baseline'] for d in dependencies.values())==4
    assert receipt['tools']==plan['tool_sha256']
    for name,digest in receipt['tools'].items():assert sha(Path(name))==digest;tools[name]=digest
    records=receipt['records'];assert len(records)==len(plan['checks'])==11
    assert [r['name'] for r in records]==receipt['expected_checks']==plan['expected_checks']
    simulations=[]
    for record,check in zip(records,plan['checks']):
        assert record['status']=='PASS' and record['returncode']==0 and not record['cleanup']
        assert 0<=record['seconds']<=20
        assert record['argv']==[arg.replace('<stamp>',STAMP) for arg in check['argv']]
        assert record['cwd']==check['cwd'].replace('<stamp>',STAMP) and record['marker']==check['marker']
        assert record['execution_deadline_seconds']==check['execution_deadline_seconds']==20
        assert record['cleanup_budget_seconds']==check['cleanup_budget_seconds']==7
        for suffix in ['stdout','stderr']:
            path=REPORT/(record['name']+'.'+suffix+'.txt')
            assert sha(path)==record[suffix+'_sha256'];raw[rel(path)]=sha(path)
        if record['name'].startswith('sim_'):
            out=(REPORT/(record['name']+'.stdout.txt')).read_text()
            matching=[line for line in out.splitlines() if line.startswith(record['marker'])]
            assert len(matching)==1 and '$finish' in out
            assert (REPORT/(record['name']+'.stderr.txt')).read_bytes()==b''
            counters={word.split('=')[0]:int(word.split('=')[1]) for word in matching[0].split() if '=' in word}
            assert counters==record['counters'] and counters['holds']>0
            simulations.append(record)
    assert len(raw)==22 and len(simulations)==4
    profiles=receipt['profiles']+[receipt['example']]
    assert [{k:p[k] for k in ['name','w','h','d','t']} for p in profiles]==plan['profiles']+[plan['example_profile']]
    for profile,simulation in zip(profiles,simulations):
        dest=REPORT/profile['name'];counters=simulation['counters'];n=profile['w']*profile['h'];bits=profile['d']
        for name,digest in profile['vectors_sha256'].items():
            path=dest/name;assert sha(path)==digest;vectors[rel(path)]=digest
        values={name:[int(line,16) for line in (dest/name).read_text().splitlines()]
                for name in profile['vectors_sha256']}
        assert len(values['config.hex'])==len(values['done.hex'])==16
        assert len(values['input.hex'])==len(values['golden.hex'])==16*n
        assert values['counts.hex'][:2]==[16,n]
        done=values['done.hex'];applied=sum((v>>3)&131071 for v in done);changed=sum((v>>20)&131071 for v in done)
        assert values['counts.hex'][2:]==[applied,changed]
        assert [v&7 for v in done]==[int(i==14) for i in range(16)]
        assert all((v>>37)==(values['config.hex'][i]>>(bits+1)) for i,v in enumerate(done))
        assert profile['expected_applied']==counters['applied']==2*applied
        assert profile['expected_changed']==counters['changed']==2*changed
        assert counters['commands']==profile['commands']==34 and counters['done']==32 and counters['resets']==4
        assert counters['checked']==profile['checked_output_records']==32*n
        assert counters['W']==profile['w'] and counters['H']==profile['h'] and counters['D']==bits
        if not profile['integration']:
            assert counters['T']==profile['t']
            assert 2*sum((v>>(3*bits))&1 for v in values['golden.hex'])==counters['applied']
            assert 2*sum((v>>(3*bits+1))&1 for v in values['golden.hex'])==counters['changed']
    assert len(vectors)==20
    coverage=dict(accepted_commands=sum(r['counters']['commands'] for r in simulations),checked_done_records=128,
        done_handshakes_source_derived=124,core_output_pixel_flag_checks=9120,actual_rgb_pixel_checks=6144,
        total_output_records=sum(r['counters']['checked'] for r in simulations),complete_actual_output_rasters=32,
        actual_width=16,actual_height=12,actual_intentional_marker_error_rasters=2,
        successful_profiles=4,complete_output_rasters_all_profiles=128,intentional_marker_error_rasters_all_profiles=8,
        reset_events=16,initial_resets=4,live_resets=12,commands_reset_before_complete_output=8,
        checked_done_responses_reset_while_held_before_retirement=4,
        applied_output_pixels=sum(r['counters']['applied'] for r in simulations),
        changed_output_pixels=sum(r['counters']['changed'] for r in simulations),
        core_applied_pixels=4856,core_changed_pixels=1748,actual_applied_pixels=3080,actual_changed_pixels=636,
        core_held_output_cycles=2711,actual_held_output_cycles=1581,
        total_held_output_cycles=sum(r['counters']['holds'] for r in simulations),
        maximum_profile='512x128/BITS10/TAG32 syntax only; no maximum traversal or height512 functionality')
    assert coverage['accepted_commands']==136 and coverage['total_output_records']==15264
    assert coverage['applied_output_pixels']==7936 and coverage['changed_output_pixels']==2384
    assert coverage['total_held_output_cycles']==4292
    temporary={rel(path):sha(path) for path in sorted((ROOT/'.build'/STAMP).glob('*.vvp'))}
    assert len(temporary)==4 and len(list((ROOT/'.build').rglob('*.vvp')))==4
    assert not (ROOT/'__pycache__').exists()
    summary=dict(schema='anscore-b40-chroma-independent-qualification-v1',status='PASS',
        receipt=rel(receipt_path),receipt_sha256=RECEIPT_SHA,plan=rel(plan_path),plan_sha256=PLAN_SHA,
        baseline=BASE,effective_finite_checks=11,successful_simulations=4,
        planning_python_calls=1,oracle_import_attempts=1,preparation_attempts=1,closeout_python_calls=1,
        historical_hdl_failures=0,automatic_retry=False,timeout_count=0,cleanup_count=0,
        current_inputs=current,source_archive=archives,numerical_vectors=vectors,raw_streams=raw,tools=tools,
        all_hashes_independently_verified=True,exact_argv_cwd_markers_order_verified=True,
        legacy_dependencies=dependencies,csc_coeffs_alias_evidence=coefficient,
        coverage=coverage,maximum_child_seconds=max(r['seconds'] for r in records),
        finite_markers=[r['marker'] for r in simulations],
        compile_diagnostics='Only missing explicit time unit/precision in unchanged legacy dependencies',
        simulation_stderr='empty in all four simulations',synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',
        board='NOT_RUN',old_regression='NOT_RUN',hardware='HW_UNVERIFIED')
    qualification=ROOT/'QUALIFICATION.json';write(qualification,summary)
    metadata=['README.md','ARCHITECTURE.md','SOURCES.md','STATUS.md','manifest.json','references.json',
              'LICENSE','.gitattributes','closeout.py','QUALIFICATION.json']
    delivery=dict(schema='anscore-b40-worker-c-delivery-v1',package_root=rel(ROOT),baseline=BASE,
        name='chroma_median_suppress',new_capability='Y-preserving same-resolution local luma-range-gated independent Cb/Cr medians plus actual unchanged forward/inverse RGB CSC chain',
        status=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'],
        receipt=rel(receipt_path),receipt_sha256=RECEIPT_SHA,plan=rel(plan_path),plan_sha256=PLAN_SHA,
        qualification=rel(qualification),qualification_sha256=sha(qualification),effective_finite_checks=11,
        successful_simulations=4,current_qualification_pass_children=11,current_qualification_successful_simulations=4,
        historical_hdl_failures=0,total_hdl_child_executions=11,total_simulation_executions=4,
        preparation_attempts=1,oracle_import_attempts=1,planning_python_calls=1,closeout_python_calls=1,
        source_archive=archives,current_source_sha256=current,numerical_vectors=vectors,raw_streams=raw,tools=tools,
        legacy_dependencies=dependencies,csc_coeffs_alias_evidence=coefficient,coverage=coverage,
        delivery_metadata_sha256={rel(ROOT/name):sha(ROOT/name) for name in metadata},
        successful_vvps_for_root_cleanup=temporary,failed_vvps_to_retain={},
        absolute_cleanup_inventory={str(REPO/name):digest for name,digest in temporary.items()},
        cleanup_performed_by_worker=False,staging_or_commit_performed_by_worker=False,
        architecture_risk=dict(default='MEDIUM',maximum='HIGH',row_storage_style='explicit registers; no BRAM claim',
            default_row_array_bits=6288,maximum_row_array_bits=61620,default_median_payload_bits=2560,
            maximum_median_payload_bits=3200,default_bypass_gate_bits=250,maximum_bypass_gate_bits=310,
            additional_window_history_and_control=True,actual_two_csc_declared_bits_default=2396,
            actual_two_csc_declared_bits_bits10=2408,new_multipliers=0,new_dividers=0,fmax='UNMEASURED',device_fit='UNMEASURED'),
        limitations=['finite sizes only; maximum geometry syntax only','fabric-register windows and maximum resource risk HIGH',
            'Y-domain gate does not prove chroma-edge absence or perceptual improvement',
            'RGB CSC round trip can change RGB codes even when filter disabled; inverse clipping can change reconstructed luma',
            'II1 output bursts; row capture/replay reduces sustained service; hardware video rate unmeasured',
            'no synthesis/PnR/STA/board/old regression'])
    write(ROOT/'B40_DELIVERY.json',delivery)
    # Final exact evidence check after metadata writes. No executed input changed.
    for name,digest in current.items():assert sha(REPO/name)==digest
    for mapping in [archives,vectors,raw,temporary,delivery['delivery_metadata_sha256']]:
        for name,digest in mapping.items():assert sha(REPO/name)==digest
    assert sha(receipt_path)==RECEIPT_SHA and sha(plan_path)==PLAN_SHA
    print(json.dumps(dict(delivery_sha256=sha(ROOT/'B40_DELIVERY.json'),qualification_sha256=sha(qualification),
        receipt_sha256=RECEIPT_SHA,inputs=len(current),archives=len(archives),vectors=len(vectors),raw=len(raw),
        tools=len(tools),temporary=len(temporary),oracle_imports_by_closeout=0,hdl_children_by_closeout=0)))

if __name__=='__main__':main()
