"""Future single exact approved finite26 attempt; stored tuples only, no model."""
import argparse
import copy
from pathlib import Path
import re
from guards import ROOT,REPO,sha,read,file_map,inventory,exact_map,verify_map,verify_source,verify_reviews,dump,save_raw,archive_failure,environment,verify_process
from process_tree import execute
from validate import simulation


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--approval',type=Path,required=True);args=parser.parse_args()
    approval_path=args.approval.resolve()
    if approval_path.is_relative_to(ROOT):raise SystemExit('external root HDL approval required')
    source_digest=sha(ROOT/'SOURCE_SEAL.json');author_digest=sha(ROOT/'AUTHOR_SEAL.json')
    seal=verify_source(source_digest,author_digest);author=read(ROOT/'AUTHOR_SEAL.json')
    plan_digest=sha(ROOT/'TEST_PLAN.json');plan=read(ROOT/'TEST_PLAN.json');approval_digest=sha(approval_path);approval=read(approval_path)
    fields={'approved_by':'root','source_seal_sha256':source_digest,'author_seal_sha256':author_digest,
        'test_plan_sha256':plan_digest,'children':plan['children'],'max_invocations':1,'hard_seconds':20,'automatic_retry':False}
    if any(approval.get(k)!=v for k,v in fields.items()):raise SystemExit('exact source/author/plan/children approval required')
    verify_reviews(approval)
    if inventory(ROOT)!=set(seal['files'])|{'SOURCE_SEAL.json'}:raise SystemExit('exclusive pre-HDL inventory; existing attempt blocks retry')
    retained={};generated={}
    def context_guard():
        verify_source(source_digest,author_digest);verify_reviews(approval);verify_map(ROOT,retained)
        if sha(approval_path)!=approval_digest or sha(ROOT/'TEST_PLAN.json')!=plan_digest:raise RuntimeError('approved HDL context changed')
    context_guard();out=ROOT/'evidence/attempt_01';out.mkdir(parents=True,exist_ok=False)
    source_root=out/'sources';cwd=source_root/ROOT.name;artifacts=out/'artifacts'
    own={**seal['files'],'SOURCE_SEAL.json':source_digest}
    copies={ROOT.name+'/'+k:v for k,v in own.items()}
    dependency=read(ROOT/'DEPENDENCIES.json')['external_production'][0]
    dep_relative='grayscale_max_tree/rtl/grayscale_max_tree.sv'
    copies[dep_relative]=dependency['sha256']
    records=[]
    for item in plan['children']:
        row=copy.deepcopy(item);row['plan_argv']=row.pop('argv');row.update(status='NOT_RUN',launched=False);records.append(row)
    env=environment(read(ROOT/'TOOL_INVENTORY.json'),out/'tmp')
    receipt=dict(schema=1,status='STARTED',author_seal_sha256=author_digest,source_seal_sha256=source_digest,
        test_plan_sha256=plan_digest,approval_sha256=approval_digest,static_reviews=approval['static_reviews'],children=records,
        completed_children=0,hard_seconds=20,automatic_retry=False,stop_on_first_failure=True,
        tested_copies_sha256=copies,artifacts_sha256=generated,retained_process_evidence_sha256=retained,
        preparation_rerun=False,reference_rerun=False,inherited_regression='NOT_RUN',
        stored_policy='HASH_SHAPE_STORED_TUPLES_CERTIFICATES_ONLY',source_list_base='package_root',hardware='HW_UNVERIFIED',
        environment=env,environment_policy='FIXED_NO_INHERITED_PATH_OR_PYTHONHOME')
    current=None;raw={};stage='initial_receipt'
    def guard():context_guard();exact_map(source_root,copies);exact_map(artifacts,generated)
    try:
        dump(out/'receipt.json',receipt,exclusive=True)
        dump(out/'LOCK.json',dict(status='SINGLE_HDL_ATTEMPT_STARTED',source_seal_sha256=source_digest,approval_sha256=approval_digest),exclusive=True)
        retained['evidence/attempt_01/LOCK.json']=sha(out/'LOCK.json')
        stage='copy_setup';source_root.mkdir();artifacts.mkdir();(out/'tmp').mkdir()
        for name,wanted in copies.items():
            target=source_root/name;target.parent.mkdir(parents=True,exist_ok=True)
            origin=REPO/dependency['repo_path'] if name==dep_relative else ROOT/Path(name).relative_to(ROOT.name)
            with target.open('xb') as f:f.write(origin.read_bytes())
            if sha(target)!=wanted or sha(origin)!=wanted:raise RuntimeError('exact tested copy '+name)
        guard()
        expected_artifacts={p['id']+'.vvp' for p in read(ROOT/'CASE_TABLE.json')['profiles']}
        for current in records:
            raw={};stage='pre_child_guard';guard()
            if current['kind']=='compile' and (artifacts/(current['profile']+'.vvp')).exists():raise RuntimeError('compile artifact exists')
            if current['kind']=='simulation' and set(generated)!=expected_artifacts:raise RuntimeError('five fixed compiled images required')
            argv=[arg.replace('{ARTIFACT}',str(artifacts)) for arg in current['plan_argv']]
            stage='child';current.update(status='RUNNING',launched=True)
            result=execute(argv,cwd,env,20);raw={s:result.pop(s) for s in ('stdout','stderr')};current.update(result)
            current['working_directory']=str(cwd);stage='raw_persistence'
            for stream,data in raw.items():
                entry=save_raw(out,current['name']+'.'+stream+'.raw',data);current[stream]=entry;retained[entry['file']]=entry['sha256']
            stage='post_child_guard';context_guard();exact_map(source_root,copies)
            candidate=dict(generated)
            if current['kind']=='compile':
                artifact=artifacts/(current['profile']+'.vvp')
                if artifact.is_file():candidate[artifact.name]=sha(artifact)
            exact_map(artifacts,candidate)
            stage='validation'
            verify_process(result,argv,cwd,env,require_zero=False)
            if current['kind']=='reject':
                if result['returncode']!=1 or raw['stdout'] or raw['stderr'].decode('ascii').splitlines()!=plan['reject_stderr_lines']:raise ValueError('exact named static rejection')
                status='EXPECTED_REJECT'
            else:
                if result['returncode']!=0 or raw['stderr']:raise ValueError('nonzero child or unexpected stderr')
                if current['kind']=='stored':
                    if raw['stdout']!=b'STORED profiles=5 main=30 fresh=10 reset=10 groups=10 NO_MODEL\r\n':raise ValueError('stored-only exact result')
                elif current['kind']=='syntax':
                    if raw['stdout']!=b'AST_ONLY_PASS\r\n':raise ValueError('syntax result')
                elif current['kind']=='simulation':current['validation']=simulation(current,raw['stdout'],cwd)
                elif raw['stdout']:raise ValueError('unexpected compiler stdout')
                if current['kind']=='compile':
                    artifact=artifacts/(current['profile']+'.vvp')
                    if not artifact.is_file() or artifact.stat().st_size==0:raise ValueError('missing compile image')
                    embedded={Path(p).resolve().relative_to(REPO).as_posix() for p in re.findall(r'^:vpi_module "([^"]+)";',artifact.read_text(encoding='utf-8'),re.MULTILINE)}
                    if embedded!=set(author['runtime_modules']):raise ValueError('unexpected embedded VPI set')
                status='PASS'
            generated.clear();generated.update(candidate);stage='post_validation_guard';guard()
            current['status']=status;receipt['completed_children']=sum(r['launched'] for r in records);dump(out/'receipt.json',receipt)
        stage='final_guard';guard();receipt['status']='PASS_FIXED_26';dump(out/'receipt.json',receipt)
    except Exception as exc:
        if current is not None and current['launched']:
            current['status']='TIMEOUT' if current.get('timed_out') else 'FAIL';current['validation_failure']=str(exc)
        receipt.update(status='FAILED_STOPPED',failure_stage=stage,failure=str(exc),
            current_child=None if current is None else current['name'],completed_children=sum(r['launched'] for r in records),
            not_run_children=[r['name'] for r in records if r['status']=='NOT_RUN'])
        for stream,data in raw.items():
            if current is not None and not (out/(current['name']+'.'+stream+'.raw')).exists():
                try:current[stream]=save_raw(out,current['name']+'.'+stream+'.raw',data)
                except Exception as error:receipt.setdefault('raw_preservation_errors',{})[stream]=str(error)
        try:receipt['observed_sources']=file_map(source_root);receipt['observed_artifacts']=file_map(artifacts);receipt['observed_raw']={p.name:sha(p) for p in out.glob('*.raw')}
        except Exception as error:receipt['observation_error']=str(error)
        try:dump(out/'receipt.json',receipt)
        except Exception as error:receipt['terminal_receipt_write_failure']=str(error)
        try:archive_failure(ROOT/'failure_archive/attempt_01',[out],receipt)
        except Exception as error:
            receipt['archive_error']=str(error)
            try:dump(out/'receipt.json',receipt)
            except Exception:pass
        raise SystemExit('HDL_FAILED_STOPPED_NO_RETRY')
    print('PASS_FIXED_26 hardware=HW_UNVERIFIED')

if __name__=='__main__':main()
