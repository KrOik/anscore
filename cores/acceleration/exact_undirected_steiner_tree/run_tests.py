"""Separate approval gates for one preparation and fixed29 qualification children."""
# SPDX-License-Identifier: Apache-2.0
from pathlib import Path
import argparse,hashlib,importlib.util,json,os,re,shutil,sys
if sys.flags.optimize:raise RuntimeError('optimized Python forbidden')
sys.dont_write_bytecode=True
P=Path(__file__).resolve().parent;R=P.parents[2]
MARKER=b'exact_undirected_steiner_tree_invalid_'

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def read(path):return json.loads(path.read_bytes())
def write(path,value):path.write_text(json.dumps(value,indent=2)+'\n',encoding='utf-8',newline='\n')
def local(base,name):
    assert name and not any(c in name for c in ('\\',':','\0','\n','\r'))
    path=(base/name).resolve();assert path.is_relative_to(base.resolve()) and not path.is_symlink()
    return path
def exact(folder,hashes):
    assert {p.relative_to(folder).as_posix():sha(p) for p in folder.rglob('*') if p.is_file()}==hashes
def module(folder,name):
    spec=importlib.util.spec_from_file_location('b30_steiner_'+name,folder/(name+'.py'))
    assert spec and spec.loader
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
def tool_guard():
    tools=read(P/'TOOL_INVENTORY.json');module(P,'tool_runtime').verify(tools);return tools
def author_guard(digest):
    assert sha(P/'AUTHOR_SEAL.json')==digest
    seal=read(P/'AUTHOR_SEAL.json')
    actual={p.relative_to(P).as_posix():sha(p) for p in P.rglob('*') if p.is_file()
            and p.relative_to(P).parts[0] not in ('preparation','evidence')
            and p.name not in ('AUTHOR_SEAL.json','SOURCE_SEAL.json')}
    assert actual==seal['sources'],'exact frozen source inventory changed'
    assert str(R)==seal['repository_root'] and seal['package']==P.relative_to(R).as_posix()
    assert sha(R/'.git/anscore-b30-start.json')==seal['baseline_start_sha256']
    assert sha(R/'docs/snapshots/source_20261105_b29.json')==seal['baseline_manifest_sha256']
    tool_guard();return seal
def approval(path,stage,digest):
    path=path.resolve();assert path.is_relative_to((R/'.git').resolve()) and not path.is_symlink()
    value=read(path);field='approved_author_sha256' if stage=='prepare' else 'approved_seal_sha256'
    assert value['stage']==stage and value['approved_by']=='root' and value[field]==digest
    assert value['max_invocations']==1 and value['hard_seconds_per_tree']==20 and value['automatic_retry'] is False
    assert len(value['independent_reviews'])>=2
    for name,review_hash in value['independent_reviews'].items():assert sha(local(R,name))==review_hash
    return sha(path)
def environment(tools):
    env=os.environ.copy();env['PATH']=os.pathsep.join(tools['path_prefix'])
    env['PYTHONDONTWRITEBYTECODE']='1';env['PYTHONIOENCODING']='utf-8'
    env.pop('PYTHONPATH',None);env.pop('PYTHONHOME',None);return env
def copies(folder,hashes):
    assert not folder.exists();folder.mkdir(parents=True)
    for name,digest in hashes.items():
        source=local(P,name);assert sha(source)==digest
        destination=local(folder,name);destination.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(source,destination)
    exact(folder,hashes)
def observe(tree,attempt,record,env,cwd):
    metadata,out,err=tree.run_child(dict(argv=record['argv'],cwd=str(cwd)),env)
    raw=attempt/'raw';raw.mkdir(exist_ok=True)
    for suffix,value in [('stdout',out),('stderr',err)]:
        path=raw/(record['name']+'.'+suffix);assert not path.exists();path.write_bytes(value)
        record[suffix]=path.relative_to(P).as_posix();record[suffix+'_sha256']=sha(path);record[suffix+'_bytes']=len(value)
    record.update(metadata);record['status']='OBSERVED';return out,err
def process_pass(record):
    assert not record['timed_out'] and record['launch_error'] is None
    assert record['elapsed_seconds']<20,'hard process-tree limit reached'
    assert record['supervision']['contained_before_resume'] is True and record['supervision']['job_closed'] is True
def failure(attempt,receipt,generated=None):
    receipt['status']='FAILED_STOPPED_NO_RETRY';write(attempt/'receipt.json',receipt)
    files={p.relative_to(P).as_posix():sha(p) for p in attempt.rglob('*') if p.is_file()}
    if generated and generated.exists():files.update({p.relative_to(P).as_posix():sha(p) for p in generated.rglob('*') if p.is_file()})
    write(attempt/'FAILURE_ARCHIVE.json',dict(status='PERMANENT_PRESERVED_IN_PLACE',files_sha256=files,automatic_retry=False))

def prepare(digest,approval_path):
    seal=author_guard(digest);approved=approval(approval_path,'prepare',digest);tools=tool_guard()
    attempt=P/'preparation/attempt01';generated=P/'preparation/generated'
    assert not attempt.exists() and not generated.exists(),'one preparation only, no automatic retry'
    attempt.mkdir(parents=True);source_map={**seal['sources'],'AUTHOR_SEAL.json':digest}
    receipt=dict(status='STARTED',kind='SINGLE_PREPARATION',approved_author_sha256=digest,
                 approval_sha256=approved,approval_path=str(approval_path.resolve()),source_copies_sha256=source_map,hard_seconds=20,
                 automatic_retry=False,hardware='HW_UNVERIFIED')
    write(attempt/'receipt.json',receipt)
    try:
        copies(attempt/'tested_source',source_map);shutil.copyfile(approval_path,attempt/'approval.json')
        tree=module(attempt/'tested_source','tree_process');raw=module(attempt/'tested_source','audit_raw')
        record=dict(name='prepare01',kind='preparation',status='RUNNING',argv=[tools['tools']['PYTHON']['path'],
                    '-B',str(attempt/'tested_source/prepare.py'),'--once',str(generated),
                    '--approved-author',digest,'--approval',str(approval_path.resolve()),'--approved-approval',approved])
        receipt['record']=record;write(attempt/'receipt.json',receipt)
        out,err=observe(tree,attempt,record,environment(tools),attempt/'tested_source')
        write(attempt/'receipt.json',receipt);process_pass(record)
        assert record['exit_code']==0 and not err
        assert json.loads(out)==dict(status='FIXED23_PREPARED_ONCE',cases=23,jobs=12,files=14,
                                     model_calls=23,materialize_calls=23,witness_checks=14)
        raw.verify_prepared(generated,read(P/'CASE_TABLE.json'),read(P/'PREPARATION_PLAN.json'))
        author_guard(digest);exact(attempt/'tested_source',source_map);assert sha(approval_path)==approved
        record['status']='PASS';receipt.update(status='PREPARATION_PASS',prepared_manifest_sha256=sha(generated/'MANIFEST.json'))
        write(attempt/'receipt.json',receipt);print('PASS PREPARATION_ONCE');return 0
    except Exception as error:
        receipt['failure']=dict(type=type(error).__name__,message=str(error))
        if 'record' in receipt:receipt['record']['status']='FAIL'
        failure(attempt,receipt,generated);print('FAILED_STOPPED PREPARATION');return 1

def preparation_guard(seal):
    receipt_path=P/'preparation/attempt01/receipt.json'
    assert sha(receipt_path)==seal['preparation_receipt_sha256']
    receipt=read(receipt_path);assert receipt['status']=='PREPARATION_PASS'
    assert receipt['approved_author_sha256']==seal['author_sha256']
    expected_sources={**read(P/'AUTHOR_SEAL.json')['sources'],'AUTHOR_SEAL.json':seal['author_sha256']}
    assert receipt['source_copies_sha256']==expected_sources
    exact(P/'preparation/attempt01/tested_source',expected_sources)
    approval_path=Path(receipt['approval_path']).resolve()
    assert approval(approval_path,'prepare',seal['author_sha256'])==receipt['approval_sha256']
    assert sha(P/'preparation/attempt01/approval.json')==receipt['approval_sha256']
    assert receipt['prepared_manifest_sha256']==sha(P/'preparation/generated/MANIFEST.json')
    record=receipt['record'];assert record['status']=='PASS' and record['exit_code']==0
    process_pass(record)
    for suffix in ('stdout','stderr'):
        path=local(P,record[suffix]);assert sha(path)==record[suffix+'_sha256'] and path.stat().st_size==record[suffix+'_bytes']
    assert not record['stderr_bytes']
    # All gate/raw/prepared bytes are included in the separately reviewed HDL seal.
    required={'preparation/attempt01/receipt.json','preparation/attempt01/approval.json',record['stdout'],record['stderr']}
    required|={p.relative_to(P).as_posix() for p in (P/'preparation/generated').rglob('*') if p.is_file()}
    assert required<=set(seal['input_files_sha256'])

def checkpoint(seal,digest,approval_path,approved,attempt,sources,artifacts):
    assert sha(P/'SOURCE_SEAL.json')==digest and sha(approval_path)==approved
    author_guard(seal['author_sha256'])
    preparation_guard(seal)
    for name,value in seal['input_files_sha256'].items():assert sha(local(P,name))==value
    exact(attempt/'tested_source',sources)
    assert {p.relative_to(P).as_posix():sha(p) for p in (attempt/'artifacts').rglob('*') if p.is_file()}==artifacts

def hdl(digest,approval_path):
    assert sha(P/'SOURCE_SEAL.json')==digest
    seal=read(P/'SOURCE_SEAL.json');author_guard(seal['author_sha256'])
    approved=approval(approval_path,'hdl',digest);tools=tool_guard();plan=read(P/'TEST_PLAN.json')
    assert seal['test_plan_sha256']==sha(P/'TEST_PLAN.json') and seal['children']==plan['children']
    preparation_guard(seal)
    for name,value in seal['input_files_sha256'].items():assert sha(local(P,name))==value
    attempt=P/'evidence/attempt01';assert not attempt.exists();attempt.mkdir(parents=True)
    source_map={**seal['input_files_sha256'],'SOURCE_SEAL.json':digest}
    receipt=dict(status='STARTED',source_seal_sha256=digest,approval_sha256=approved,source_copies_sha256=source_map,
                 records=[dict(name=c['name'],status='NOT_RUN') for c in plan['children']],results=[],
                 generated_artifacts_sha256={},hard_seconds=20,automatic_retry=False,hardware='HW_UNVERIFIED')
    write(attempt/'receipt.json',receipt);current=None;phase='setup'
    try:
        copies(attempt/'tested_source',source_map);shutil.copyfile(approval_path,attempt/'approval.json')
        tree=module(attempt/'tested_source','tree_process');raw=module(attempt/'tested_source','audit_raw')
        generated=attempt/'tested_source/preparation/generated'
        data=raw.verify_prepared(generated,read(P/'CASE_TABLE.json'),read(P/'PREPARATION_PLAN.json'))
        artifacts=attempt/'artifacts';artifacts.mkdir();env=environment(tools)
        expansion={k:v['path'] for k,v in tools['tools'].items()};expansion['ARTIFACTS']=str(artifacts)
        for i,child in enumerate(plan['children']):
            current=None;phase='pre_checkpoint:'+child['name']
            checkpoint(seal,digest,approval_path,approved,attempt,source_map,receipt['generated_artifacts_sha256'])
            current=dict(name=child['name'],kind=child['kind'],argv=[arg.format(**expansion) for arg in child['argv']],status='RUNNING')
            receipt['records'][i]=current;phase='child:'+child['name'];write(attempt/'receipt.json',receipt)
            out,err=observe(tree,attempt,current,env,attempt/'tested_source');write(attempt/'receipt.json',receipt)
            process_pass(current)
            if child['kind']=='reject':
                assert current['exit_code'] is not None and 0<current['exit_code']<128
                assert MARKER in out+err and child['marker'].encode('ascii') in out+err
                current['status']='EXPECTED_REJECT'
            else:
                assert current['exit_code']==0 and not err
                if child['kind']=='simulation':
                    job=next(j for j in data['jobs'] if j['name']==child['name'])
                    receipt['results'].append(raw.audit(raw.normalized_output(out),data,job))
                elif child['kind']=='stored':assert out==b'PASS STORED_ONLY_CERTIFICATES_23\r\n' or out==b'PASS STORED_ONLY_CERTIFICATES_23\n'
                else:assert not out
                if child['kind']=='compile':
                    artifact=artifacts/('p'+str(child['profile'])+'.vvp')
                    embedded={str(Path(name).resolve()).casefold() for name in re.findall(r'^:vpi_module "([^"]+)";',artifact.read_text('utf-8'),re.MULTILINE)}
                    assert embedded=={str(Path(name).resolve()).casefold() for name in tools['runtime_modules_sha256']}
                    receipt['generated_artifacts_sha256'][artifact.relative_to(P).as_posix()]=sha(artifact)
                current['status']='PASS'
            phase='post_checkpoint:'+child['name']
            checkpoint(seal,digest,approval_path,approved,attempt,source_map,receipt['generated_artifacts_sha256'])
            write(attempt/'receipt.json',receipt)
        current=None;phase='final_checkpoint'
        checkpoint(seal,digest,approval_path,approved,attempt,source_map,receipt['generated_artifacts_sha256'])
        assert len(receipt['records'])==29 and len(receipt['results'])==12 and len(receipt['generated_artifacts_sha256'])==5
        receipt.update(status='UNIT_SIM_PASS_FIXED29',max_child_seconds=max(r['elapsed_seconds'] for r in receipt['records']),
                       successful_artifacts_retained_for_independent_review=True)
        write(attempt/'receipt.json',receipt);print('PASS FIXED29_HDL');return 0
    except Exception as error:
        receipt['failure']=dict(type=type(error).__name__,message=str(error),phase=phase)
        if current:current['status']='FAIL'
        failure(attempt,receipt);print('FAILED_STOPPED HDL');return 1

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('stage',choices=['prepare','hdl'])
    parser.add_argument('--approved',required=True);parser.add_argument('--approval',type=Path,required=True)
    args=parser.parse_args();raise SystemExit(prepare(args.approved,args.approval) if args.stage=='prepare' else hdl(args.approved,args.approval))
