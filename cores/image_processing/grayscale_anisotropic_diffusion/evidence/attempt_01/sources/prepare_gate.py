"""One root-approved preparation; every post-creation failure is terminal."""
from pathlib import Path
import argparse
import os
from guards import ROOT,sha,read,verify_author,verify_reviews,inventory,file_map,verify_map,dump,save_raw,archive_failure
from process_tree import execute

def main() -> None:
    parser=argparse.ArgumentParser();parser.add_argument('--approval',type=Path,required=True)
    args=parser.parse_args();approval_path=args.approval.resolve()
    if approval_path.is_relative_to(ROOT): raise SystemExit('root approval must be external')
    author_digest=sha(ROOT/'AUTHOR_SEAL.json');author=verify_author(author_digest)
    plan_digest=sha(ROOT/'PREPARATION_PLAN.json');plan=read(ROOT/'PREPARATION_PLAN.json')
    approval_digest=sha(approval_path);approval=read(approval_path)
    if inventory(ROOT)!=set(author['sources'])|{'AUTHOR_SEAL.json'}: raise SystemExit('exclusive unprepared author inventory required')
    if (approval.get('approved_by')!='root' or approval.get('author_seal_sha256')!=author_digest or
        approval.get('preparation_plan_sha256')!=plan_digest or approval.get('max_invocations')!=1 or
        approval.get('hard_seconds')!=20 or approval.get('automatic_retry') is not False or approval.get('child_argv')!=plan['child_argv']):
        raise SystemExit('exact root preparation approval required')
    verify_reviews(approval);retained={}
    def guard() -> None:
        verify_author(author_digest)
        if sha(ROOT/'PREPARATION_PLAN.json')!=plan_digest or sha(approval_path)!=approval_digest:
            raise RuntimeError('approved preparation context changed')
        verify_reviews(approval)
        verify_map(ROOT,retained)
    guard()
    output=ROOT/'preparation';output.mkdir(exist_ok=False)
    receipt=dict(schema=1,status='STARTED',author_seal_sha256=author_digest,
        preparation_plan_sha256=plan_digest,approval_sha256=approval_digest,static_reviews=dict(approval['static_reviews']),
        invocations=1,automatic_retry=False,hard_seconds=20,child=None,fixture_sha256={},retained_process_evidence_sha256=retained,
        failure_archive_directory='failure_archive/preparation_01',hardware='HW_UNVERIFIED')
    raw={};stage='initial_receipt'
    try:
        dump(output/'receipt.json',receipt,exclusive=True)
        dump(output/'LOCK.json',dict(status='SINGLE_PREPARATION_STARTED',author_seal_sha256=author_digest,
             approval_sha256=approval_digest),exclusive=True)
        retained['preparation/LOCK.json']=sha(output/'LOCK.json')
        stage='pre_child_guard';guard()
        stage='child';result=execute(plan['child_argv'],ROOT,dict(os.environ),20)
        raw={stream:result.pop(stream) for stream in ['stdout','stderr']};receipt['child']=result
        stage='raw_persistence'
        for stream,data in raw.items():
            for key,value in save_raw(output,stream+'.raw',data).items(): result[stream+'_'+key]=value
            retained[result[stream+'_file']]=result[stream+'_sha256']
        stage='post_child_guard';guard()
        stage='child_validation'
        if (result['returncode']!=0 or result['timed_out'] or result['failure'] is not None or
            not 0<=result['elapsed_seconds']<20 or raw['stdout']!=(plan['expected_stdout']+'\r\n').encode('ascii') or raw['stderr']):
            raise RuntimeError('preparation process/raw validation failed')
        fixtures=file_map(ROOT/'fixtures')
        if set(fixtures)!=set(plan['fixture_files']): raise RuntimeError('fixture inventory mismatch')
        receipt['fixture_sha256']={'fixtures/'+name:digest for name,digest in fixtures.items()}
        stage='final_author_approval_guard';guard()
        verify_map(ROOT,receipt['fixture_sha256'])
        receipt['status']='PASS';dump(output/'receipt.json',receipt)
        if inventory(output)!={'LOCK.json','receipt.json','stdout.raw','stderr.raw'}:
            raise RuntimeError('preparation evidence inventory mismatch')
        prepared={**receipt['fixture_sha256'],**{'preparation/'+name:digest for name,digest in file_map(output).items()}}
        files={**author['sources'],'AUTHOR_SEAL.json':author_digest,**prepared}
        stage='source_seal'
        document=dict(schema=1,status='PREPARED_HDL_NOT_RUN',author_seal_sha256=author_digest,
            files=files,prepared_files=prepared,preparation_receipt_sha256=sha(output/'receipt.json'),
            test_plan_sha256=sha(ROOT/'TEST_PLAN.json'),hardware='HW_UNVERIFIED')
        dump(ROOT/'SOURCE_SEAL.json',document,exclusive=True)
        stage='post_seal_guard';guard();verify_map(ROOT,prepared)
        if read(ROOT/'SOURCE_SEAL.json')!=document: raise RuntimeError('source seal write mismatch')
    except Exception as exc:
        receipt.update(status='FAILED_STOPPED',failure_stage=stage,failure=str(exc))
        # Preserve any still-unwritten captured stream without replacing partial bytes.
        for stream,data in raw.items():
            path=output/(stream+'.raw')
            if not path.exists():
                try:
                    for key,value in save_raw(output,stream+'.raw',data).items(): receipt['child'][stream+'_'+key]=value
                except Exception as error: receipt.setdefault('raw_preservation_errors',{})[stream]=str(error)
        try:
            receipt['observed_fixture_sha256']={'fixtures/'+name:digest for name,digest in file_map(ROOT/'fixtures').items()}
            receipt['observed_preparation_sha256']={'preparation/'+name:digest for name,digest in file_map(output).items() if name!='receipt.json'}
        except Exception as error: receipt['observation_error']=str(error)
        try: dump(output/'receipt.json',receipt)
        except Exception as error: receipt['terminal_receipt_write_failure']=str(error)
        try: archive_failure(ROOT/'failure_archive/preparation_01',[output,ROOT/'fixtures',ROOT/'SOURCE_SEAL.json'],receipt)
        except Exception as error:
            receipt['archive_failure']=str(error)
            try: dump(output/'receipt.json',receipt)
            except Exception: pass
        raise SystemExit('PREPARATION FAILED_STOPPED: original partial bytes retained; no retry')
    print('PREPARATION_PASS HDL_NOT_RUN')

if __name__=='__main__': main()
