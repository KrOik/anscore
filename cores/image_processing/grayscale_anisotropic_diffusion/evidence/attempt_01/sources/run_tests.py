"""Exact root-approved fixed26; immutable guards surround every child."""
from pathlib import Path
import argparse
import copy
import hashlib
import os
import re
from guards import ROOT,REPO,sha,read,verify_source,verify_reviews,inventory,file_map,exact_map,verify_map,dump,save_raw,archive_failure
from process_tree import execute
from validate import simulation

def main() -> None:
    parser=argparse.ArgumentParser();parser.add_argument('--approval',type=Path,required=True)
    args=parser.parse_args();approval_path=args.approval.resolve()
    if approval_path.is_relative_to(ROOT): raise SystemExit('root approval must be external')
    source_digest=sha(ROOT/'SOURCE_SEAL.json');author_digest=sha(ROOT/'AUTHOR_SEAL.json')
    seal=verify_source(source_digest,author_digest);author=read(ROOT/'AUTHOR_SEAL.json')
    plan_digest=sha(ROOT/'TEST_PLAN.json');plan=read(ROOT/'TEST_PLAN.json')
    approval_digest=sha(approval_path);approval=read(approval_path)
    if (approval.get('approved_by')!='root' or approval.get('source_seal_sha256')!=source_digest or
        approval.get('test_plan_sha256')!=plan_digest or approval.get('max_invocations')!=1 or
        approval.get('hard_seconds')!=20 or approval.get('automatic_retry') is not False or approval.get('children')!=plan['children']):
        raise SystemExit('exact root HDL approval required')
    verify_reviews(approval)
    if inventory(ROOT)!=set(seal['files'])|{'SOURCE_SEAL.json'}: raise SystemExit('exclusive pre-HDL inventory required')
    copies={**seal['files'],'SOURCE_SEAL.json':source_digest};generated={};retained={}
    def context_guard() -> None:
        verify_source(source_digest,author_digest)
        if sha(ROOT/'TEST_PLAN.json')!=plan_digest or sha(approval_path)!=approval_digest:
            raise RuntimeError('approved HDL context changed')
        verify_reviews(approval)
        verify_map(ROOT,retained)
    context_guard()
    output=ROOT/'evidence/attempt_01';sources=output/'sources';artifacts=output/'artifacts'
    records=[]
    for item in plan['children']:
        child=copy.deepcopy(item);child['plan_argv']=child.pop('argv');child['status']='NOT_RUN';child['launched']=False
        records.append(child)
    environment=dict(os.environ);inherited_path=environment.get('PATH','')
    environment['PATH']=os.pathsep.join(author['path_prefix']+([inherited_path] if inherited_path else []))
    environment['PYTHONDONTWRITEBYTECODE']='1';environment['PYTHONIOENCODING']='utf-8'
    receipt=dict(schema=1,status='STARTED',attempt='attempt_01',source_seal_sha256=source_digest,
        author_seal_sha256=author_digest,test_plan_sha256=plan_digest,approval_sha256=approval_digest,
        static_reviews=dict(approval['static_reviews']),children=records,completed_children=0,
        tested_copies_sha256=copies,generated_artifacts_sha256=generated,retained_process_evidence_sha256=retained,hard_seconds=20,automatic_retry=False,
        stop_on_first_failure=True,numerical_preparation_rerun=False,oracle_rerun=False,
        stored_check='HASH_SHAPE_STORED_TUPLES_CERTIFICATES_ONLY_NO_MODEL',inherited_matrix='NOT_RUN',
        path_prefix=author['path_prefix'],runtime_dlls=author['runtime_dlls'],runtime_modules=author['runtime_modules'],
        tools=author['tools'],compiler_install_files_sha256=author['compiler_install_files_sha256'],
        inherited_PATH_sha256=hashlib.sha256(inherited_path.encode()).hexdigest(),
        effective_PATH_sha256=hashlib.sha256(environment['PATH'].encode()).hexdigest(),
        external_sources=author['external_sources'],failure_archive_directory='failure_archive/attempt_01',hardware='HW_UNVERIFIED')
    output.mkdir(parents=True,exist_ok=False);current=None;raw={};stage='initial_receipt'
    def guard() -> None:
        context_guard();exact_map(sources,copies);exact_map(artifacts,generated)
    try:
        dump(output/'receipt.json',receipt,exclusive=True)
        dump(output/'LOCK.json',dict(status='ONE_FIXED_ATTEMPT_STARTED',source_seal_sha256=source_digest,
             approval_sha256=approval_digest),exclusive=True)
        retained['evidence/attempt_01/LOCK.json']=sha(output/'LOCK.json')
        stage='copy_setup';sources.mkdir();artifacts.mkdir();context_guard()
        for relative,wanted in copies.items():
            dest=sources/relative;dest.parent.mkdir(parents=True,exist_ok=True)
            with dest.open('xb') as stream: stream.write((ROOT/relative).read_bytes())
            if sha(dest)!=wanted: raise RuntimeError('copy mismatch: '+relative)
        guard()
        expected_vvps={item['profile']+'.vvp' for item in plan['children'] if item['kind']=='compile'}
        for current in records:
            raw={};stage='pre_child_guard';guard()
            if current['kind']=='compile' and (artifacts/(current['profile']+'.vvp')).exists():
                raise RuntimeError('compile target already exists')
            if current['kind']=='simulation' and set(generated)!=expected_vvps:
                raise RuntimeError('fixed five compiled VVPs required before simulation')
            argv=[arg.replace('{ARTIFACT}',str(artifacts)) for arg in current['plan_argv']]
            stage='child';current['launched']=True;current['status']='RUNNING'
            result=execute(argv,sources,environment,20)
            raw={stream:result.pop(stream) for stream in ['stdout','stderr']};current.update(result)
            current['working_directory']=str(sources);stage='raw_persistence'
            for stream,data in raw.items():
                for key,value in save_raw(output,current['name']+'.'+stream+'.raw',data).items(): current[stream+'_'+key]=value
                retained[current[stream+'_file']]=current[stream+'_sha256']
            stage='post_child_guard';context_guard();exact_map(sources,copies)
            candidate=dict(generated)
            if current['kind']=='compile':
                path=artifacts/(current['profile']+'.vvp')
                if path.exists(): current['produced_artifact']=dict(name=path.name,sha256=sha(path),bytes=path.stat().st_size)
                if path.is_file(): candidate[path.name]=sha(path)
            exact_map(artifacts,candidate)
            stage='child_validation'
            if result['failure'] or result['timed_out'] or not 0<=result['elapsed_seconds']<20:
                raise ValueError(result['failure'] or 'hard20s process-tree deadline')
            if current['kind']=='reject':
                rtl_lines=(sources/'rtl/grayscale_anisotropic_diffusion.sv').read_text().splitlines()
                reject_line=next(i+1 for i,line in enumerate(rtl_lines) if 'grayscale_anisotropic_diffusion_invalid_parameters__see_README invalid_configuration();' in line)
                expected_error=[f'rtl/grayscale_anisotropic_diffusion.sv:{reject_line}: error: Unknown module type: grayscale_anisotropic_diffusion_invalid_parameters__see_README',
                    '1 error(s) during elaboration.','*** These modules were missing:',
                    '        grayscale_anisotropic_diffusion_invalid_parameters__see_README referenced 1 times.','***']
                if result['returncode']!=1 or raw['stdout'] or raw['stderr'].decode('ascii').splitlines()!=expected_error:
                    raise ValueError('exact named reject mismatch')
                status='EXPECTED_REJECT'
            else:
                if result['returncode']!=0: raise ValueError('nonzero return')
                if current['kind']=='version':
                    if b'Icarus Verilog version' not in raw['stdout']: raise ValueError('version absent')
                elif current['kind']=='stored':
                    if raw['stdout']!=b'STORED_HASH_SHAPE_TUPLES profiles=5 cases=16 reset_cases=2 NO_MODEL_REEXECUTION\r\n' or raw['stderr']:
                        raise ValueError('stored-only result')
                elif raw['stderr']: raise ValueError('unexpected stderr')
                elif current['kind']=='simulation': current['validation']=simulation(current,raw['stdout'],sources)
                elif raw['stdout']: raise ValueError('unexpected compile stdout')
                if current['kind']=='compile':
                    produced=current['produced_artifact']
                    if produced['bytes']<=0: raise ValueError('empty VVP')
                    text=(artifacts/produced['name']).read_text('utf-8')
                    modules={Path(name).resolve().relative_to(REPO).as_posix() for name in re.findall(r'^:vpi_module "([^"]+)";',text,re.MULTILINE)}
                    if modules!=set(author['runtime_modules']): raise ValueError('embedded VPI paths differ from sealed six-module set')
                status='PASS'
            generated.clear();generated.update(candidate)
            stage='post_validation_guard';guard()
            current['status']=status;receipt['completed_children']=sum(child['launched'] for child in records)
            dump(output/'receipt.json',receipt)
        stage='final_guard';guard();receipt['status']='PASS_FIXED_26';dump(output/'receipt.json',receipt)
    except Exception as exc:
        if current is not None and current['launched']:
            current['status']='TIMEOUT' if current.get('timed_out') else 'FAIL';current['validation_failure']=str(exc)
        receipt.update(status='FAILED_STOPPED',failure_stage=stage,failure=str(exc),
            current_child=None if current is None else current['name'],completed_children=sum(child['launched'] for child in records),
            not_run_children=[child['name'] for child in records if child['status']=='NOT_RUN'])
        for stream,data in raw.items():
            path=output/(current['name']+'.'+stream+'.raw')
            if not path.exists():
                try:
                    for key,value in save_raw(output,path.name,data).items(): current[stream+'_'+key]=value
                except Exception as error: receipt.setdefault('raw_preservation_errors',{})[stream]=str(error)
        try:
            receipt['observed_artifacts_sha256']=file_map(artifacts)
            receipt['observed_tested_copies_sha256']=file_map(sources)
            receipt['observed_raw_evidence_sha256']={p.name:sha(p) for p in output.glob('*.raw') if p.is_file()}
            if current is not None and current['launched'] and current['kind']=='compile':
                path=artifacts/(current['profile']+'.vvp')
                if path.is_file(): current['observed_produced_artifact']=dict(name=path.name,sha256=sha(path),bytes=path.stat().st_size)
        except Exception as error: receipt['observation_error']=str(error)
        try: dump(output/'receipt.json',receipt)
        except Exception as error: receipt['terminal_receipt_write_failure']=str(error)
        try: archive_failure(ROOT/'failure_archive/attempt_01',[output],receipt)
        except Exception as error:
            receipt['archive_failure']=str(error)
            try: dump(output/'receipt.json',receipt)
            except Exception: pass
        raise SystemExit('FAILED_STOPPED: original evidence retained and archive attempted; no automatic retry')
    print('PASS_FIXED_26 hardware=HW_UNVERIFIED')

if __name__=='__main__': main()
