"""Future exact root approval and one copied-source Job20 numerical child."""
import argparse
from pathlib import Path
from guards import (ROOT,REPO,PACKAGE,sha,read,file_map,inventory,exact_map,verify_map,
    verify_author,verify_reviews,dump,save_raw,archive_failure,environment,preparation_copies,
    preparation_fields,render_child,verify_context,verify_preparation,verify_source,verify_process)
from process_tree import execute

def main():
    p=argparse.ArgumentParser();p.add_argument('--approval',type=Path,required=True);args=p.parse_args()
    approval_path=args.approval.resolve()
    if approval_path.is_relative_to(ROOT):raise SystemExit('external root approval required')
    author_digest=sha(ROOT/'AUTHOR_SEAL.json');author=verify_author(author_digest)
    plan_digest=sha(ROOT/'PREPARATION_PLAN.json');plan=read(ROOT/'PREPARATION_PLAN.json')
    approval_digest=sha(approval_path);approval=read(approval_path)
    if any(approval.get(k)!=v for k,v in preparation_fields(author_digest,plan_digest,plan).items()):raise SystemExit('exact preparation approval mismatch')
    verify_reviews(approval)
    if inventory(ROOT)!=set(author['sources'])|{'AUTHOR_SEAL.json'}:raise SystemExit('exclusive unprepared inventory; prior invocation blocks retry')
    retained={}
    def author_guard():
        verify_author(author_digest);verify_reviews(approval);verify_map(ROOT,retained)
        if sha(approval_path)!=approval_digest or sha(ROOT/'PREPARATION_PLAN.json')!=plan_digest:raise RuntimeError('approved preparation context changed')
    author_guard();output=ROOT/'preparation';output.mkdir(exist_ok=False)
    copies=preparation_copies(author,author_digest,approval['static_reviews']);copy_root=output/'tested_source';cwd=copy_root/PACKAGE
    env=environment(read(ROOT/'TOOL_INVENTORY.json'),output/'tmp')
    context=dict(schema=2,author_seal_sha256=author_digest,preparation_plan_sha256=plan_digest,
        approval_path=str(approval_path),approval_sha256=approval_digest,static_reviews=approval['static_reviews'],
        output_root=str(ROOT),original_repo=str(REPO),tested_source_root=str(copy_root),
        tested_source_sha256=copies,child_argv=plan['child_argv'],environment=env)
    receipt=dict(schema=2,status='STARTED',invocations=1,hard_seconds=20,automatic_retry=False,
        child=None,fixture_sha256={},hardware='HW_UNVERIFIED')
    raw={};stage='initial_receipt'
    try:
        dump(output/'receipt.json',receipt,exclusive=True)
        stage='tested_source_setup';copy_root.mkdir();(output/'tmp').mkdir()
        for name,wanted in copies.items():
            origin=REPO/name;target=copy_root/name;target.parent.mkdir(parents=True,exist_ok=True)
            with target.open('xb') as f:f.write(origin.read_bytes())
            if sha(target)!=wanted or sha(origin)!=wanted:raise RuntimeError('preparation tested-source copy '+name)
        with (output/'approval.json').open('xb') as f:f.write(approval_path.read_bytes())
        if sha(output/'approval.json')!=approval_digest:raise RuntimeError('original approval copy changed')
        dump(output/'CONTEXT.json',context,exclusive=True);context_digest=sha(output/'CONTEXT.json')
        dump(output/'LOCK.json',dict(schema=2,status='SINGLE_PREPARATION_STARTED',context_sha256=context_digest,
            author_seal_sha256=author_digest,preparation_plan_sha256=plan_digest,approval_sha256=approval_digest,
            max_invocations=1,hard_seconds=20,automatic_retry=False),exclusive=True)
        lock_digest=sha(output/'LOCK.json');receipt.update(context_sha256=context_digest,lock_sha256=lock_digest)
        for name in ('LOCK.json','CONTEXT.json','approval.json'):retained['preparation/'+name]=sha(output/name)
        def guard():
            author_guard();verify_context(output/'CONTEXT.json',context_digest,lock_digest);exact_map(copy_root,copies)
        stage='pre_child_guard';guard()
        argv=render_child(plan,output/'CONTEXT.json',context_digest,lock_digest,copy_root,ROOT)
        stage='child';result=execute(argv,cwd,env,20)
        raw={s:result.pop(s) for s in ('stdout','stderr')};receipt['child']=result
        stage='raw_persistence'
        for stream,data in raw.items():
            entry=save_raw(output,stream+'.raw',data);result[stream]=entry;retained[entry['file']]=entry['sha256']
        stage='post_child_guard';guard();verify_process(result,argv,cwd,env)
        if raw['stdout']!=(plan['expected_stdout']+'\r\n').encode('ascii') or raw['stderr']:raise RuntimeError('exact preparation raw mismatch')
        stage='payload_manifest';receipt.update(status='PASS',payload_sha256=sha(output/'payload.json'),
            fixture_sha256={'fixtures/'+n:h for n,h in file_map(ROOT/'fixtures').items()})
        dump(output/'receipt.json',receipt);receipt_digest=sha(output/'receipt.json')
        _,prepared=verify_preparation(context_digest,lock_digest,receipt_digest)
        document=dict(schema=2,status='PREPARED_HDL_NOT_RUN',author_seal_sha256=author_digest,
            files={**author['sources'],'AUTHOR_SEAL.json':author_digest,**prepared},prepared_files=prepared,
            test_plan_sha256=sha(ROOT/'TEST_PLAN.json'),preparation_context_sha256=context_digest,
            preparation_lock_sha256=lock_digest,preparation_receipt_sha256=receipt_digest,hardware='HW_UNVERIFIED')
        stage='source_seal';dump(ROOT/'SOURCE_SEAL.json',document,exclusive=True);guard()
        verify_source(sha(ROOT/'SOURCE_SEAL.json'),author_digest)
        if inventory(ROOT)!=set(document['files'])|{'SOURCE_SEAL.json'} or read(ROOT/'SOURCE_SEAL.json')!=document:raise RuntimeError('post-seal exact inventory')
    except Exception as exc:
        receipt.update(status='FAILED_STOPPED',failure_stage=stage,failure=str(exc))
        for stream,data in raw.items():
            if not (output/(stream+'.raw')).exists():
                try:receipt.setdefault('partial_raw',{})[stream]=save_raw(output,stream+'.raw',data)
                except Exception as error:receipt.setdefault('raw_preservation_errors',{})[stream]=str(error)
        try:receipt['observed_fixtures']=file_map(ROOT/'fixtures');receipt['observed_preparation']=file_map(output)
        except Exception as error:receipt['observation_error']=str(error)
        try:dump(output/'receipt.json',receipt)
        except Exception as error:receipt['terminal_receipt_write_failure']=str(error)
        try:archive_failure(ROOT/'failure_archive/preparation_01',[output,ROOT/'fixtures',ROOT/'SOURCE_SEAL.json'],receipt)
        except Exception as error:
            receipt['archive_error']=str(error)
            try:dump(output/'receipt.json',receipt)
            except Exception:pass
        raise SystemExit('PREPARATION_FAILED_STOPPED_NO_RETRY')
    print('PREPARATION_PASS HDL_NOT_RUN')

if __name__=='__main__':main()
