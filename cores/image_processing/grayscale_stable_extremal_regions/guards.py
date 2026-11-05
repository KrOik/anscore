"""Pure source, runtime, approval and retained preparation evidence guards."""
from pathlib import Path
import hashlib
import json
import os
import sys
from runtime import verify as verify_runtime

ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
PACKAGE='cores/image_processing/grayscale_stable_extremal_regions'
PREPARATION_SCHEMA='anscore-b30-c-prepare-once-v2'

def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def read(path):return json.loads(Path(path).read_bytes())
def local(base,name):
    base=Path(base).resolve();path=(base/name).resolve()
    if not path.is_relative_to(base):raise RuntimeError('path outside fixed root')
    return path
def file_map(base):return {p.relative_to(base).as_posix():sha(p) for p in Path(base).rglob('*') if p.is_file()}
def inventory(base):return set(file_map(base))
def verify_map(base,mapping):
    for name,wanted in mapping.items():
        if sha(local(base,name))!=wanted:raise RuntimeError('byte guard '+name)
def exact_map(base,mapping):
    if file_map(base)!=mapping:raise RuntimeError('exact inventory/hash '+str(base))
def dump(path,value,exclusive=False):
    with Path(path).open('x' if exclusive else 'w',encoding='utf-8',newline='\n') as f:json.dump(value,f,indent=2);f.write('\n')
def save_raw(base,name,data):
    p=base/name
    with p.open('xb') as f:f.write(data)
    return dict(file=p.relative_to(ROOT).as_posix(),bytes=len(data),sha256=sha(p))
def archive_failure(destination,paths,receipt):
    destination.mkdir(parents=True,exist_ok=False);mapping={}
    for base in paths:
        for source in ([base] if base.is_file() else sorted(base.rglob('*')) if base.exists() else []):
            if not source.is_file():continue
            name=source.relative_to(ROOT).as_posix();wanted=sha(source);target=local(destination,name)
            target.parent.mkdir(parents=True,exist_ok=True)
            with target.open('xb') as f:f.write(source.read_bytes())
            if sha(source)!=wanted or sha(target)!=wanted:raise RuntimeError('failure archive byte mismatch')
            mapping[name]=wanted
    dump(destination/'ARCHIVE.json',dict(schema=2,status='FAILED_STOPPED_NO_RETRY',files=mapping,receipt=receipt),exclusive=True)
    return sha(destination/'ARCHIVE.json')
def verify_reviews(approval,repo=REPO):
    reviews=approval.get('static_reviews',{})
    if len(reviews)<2:raise RuntimeError('two independent frozen static reviews required')
    verify_map(repo,reviews)
def environment(record,temporary):
    system=next(Path(p).parent for p in record['path_prefix'] if Path(p).name.lower()=='system32')
    return dict(SystemRoot=str(system),WINDIR=str(system),PATH=os.pathsep.join(record['path_prefix']),
        TEMP=str(temporary),TMP=str(temporary),PYTHONDONTWRITEBYTECODE='1',PYTHONNOUSERSITE='1',
        PYTHONPATH='',PYTHONIOENCODING='utf-8',LANG='C',LC_ALL='C')
def verify_author(expected=None):
    if sys.flags.optimize or os.name!='nt':raise RuntimeError('unoptimized Windows Python required')
    before=sha(ROOT/'AUTHOR_SEAL.json')
    if expected is not None and before!=expected:raise RuntimeError('author seal changed')
    author=read(ROOT/'AUTHOR_SEAL.json')
    excluded={'preparation','fixtures','evidence','failure_archive'}
    actual={p.relative_to(ROOT).as_posix():sha(p) for p in ROOT.rglob('*') if p.is_file()
        and p.relative_to(ROOT).parts[0] not in excluded and p.name not in ('AUTHOR_SEAL.json','SOURCE_SEAL.json')}
    if actual!=author['sources']:raise RuntimeError('exact author sources changed')
    verify_map(ROOT,author['sources']);verify_map(REPO,author['external_sources'])
    for anchor in author['anchors'].values():
        if sha(local(REPO,anchor['path']))!=anchor['sha256']:raise RuntimeError('external anchor changed')
    if author['tool_inventory_sha256']!=sha(ROOT/'TOOL_INVENTORY.json'):raise RuntimeError('tool inventory binding')
    tools=read(ROOT/'TOOL_INVENTORY.json');verify_runtime(tools)
    if author['tools']!=tools['tools']:raise RuntimeError('tool identity mismatch')
    if sha(ROOT/'AUTHOR_SEAL.json')!=before:raise RuntimeError('author seal changed during guard')
    return author
def preparation_copies(author,author_digest,reviews):
    mapping={PACKAGE+'/'+n:h for n,h in {**author['sources'],'AUTHOR_SEAL.json':author_digest}.items()}
    mapping.update(author['external_sources'])
    mapping.update({v['path']:v['sha256'] for v in author['anchors'].values()})
    mapping.update(reviews)
    return mapping
def preparation_fields(author_digest,plan_digest,plan):
    return dict(schema=PREPARATION_SCHEMA,approved_by='root',author_seal_sha256=author_digest,
        preparation_plan_sha256=plan_digest,child_argv=plan['child_argv'],max_invocations=1,
        hard_seconds=20,automatic_retry=False)
def render_child(plan,context_path,context_digest,lock_digest,copy_root,output_root):
    values={'{TESTED_PACKAGE}':str(copy_root/PACKAGE),'{OUTPUT_ROOT}':str(output_root),
        '{CONTEXT_PATH}':str(context_path),'{CONTEXT_SHA256}':context_digest,'{LOCK_SHA256}':lock_digest}
    result=[]
    for arg in plan['child_argv']:
        for old,new in values.items():arg=arg.replace(old,new)
        result.append(arg)
    return result
def verify_process(result,argv,cwd,env,require_zero=True):
    if result['argv']!=argv or result['working_directory']!=str(cwd.resolve()) or result['environment']!=env:raise RuntimeError('child argv/cwd/environment binding')
    if result['failure'] is not None or result['timed_out'] or not 0<=result['elapsed_seconds']<20:raise RuntimeError('hard20 process failure')
    if require_zero and result['returncode']!=0:raise RuntimeError('nonzero child')
    if not isinstance(result['pid'],int) or result['pid']<=0:raise RuntimeError('missing child pid')
    if result['windows_containment']!=dict(created_suspended=True,assigned_to_job=True,resumed=True,contained_before_resume=True):raise RuntimeError('Windows containment proof required')
    if result['process_tree_cleanup']!={'windows_kill_on_close_job_closed':True}:raise RuntimeError('successful Job closure required')
def fixture_names(plan,table):
    names={'CERTIFICATES.json'}
    for group in table['groups']:
        names.update(group['id']+'/'+n for n in ('input.txt','expected.txt','expected.json'))
        if group['reset_ids']:names.add(group['id']+'/probe.txt')
    if len(names)!=34 or names!=set(plan['fixture_files']) or plan['fixture_count']!=34:raise RuntimeError('fixed34 fixture plan')
    return names
def verify_context(context_path,context_digest,lock_digest):
    # Used by both the live gate and copied payload before reference import.
    context_path=Path(context_path).resolve()
    if sha(context_path)!=context_digest:raise RuntimeError('captured context bytes changed')
    context=read(context_path);output=Path(context['output_root']).resolve();original=Path(context['original_repo']).resolve()
    if context['schema']!=2 or output!=original/PACKAGE:raise RuntimeError('fixed original/output relationship')
    if context_path!=output/'preparation/CONTEXT.json':raise RuntimeError('context path mismatch')
    author=verify_author(context['author_seal_sha256']);plan=read(ROOT/'PREPARATION_PLAN.json')
    if sha(ROOT/'PREPARATION_PLAN.json')!=context['preparation_plan_sha256']:raise RuntimeError('approved plan changed')
    approval_path=Path(context['approval_path']).resolve()
    if approval_path.is_relative_to(output) or sha(approval_path)!=context['approval_sha256']:raise RuntimeError('original external approval changed')
    copied_approval=output/'preparation/approval.json'
    if sha(copied_approval)!=context['approval_sha256']:raise RuntimeError('retained approval copy changed')
    approval=read(approval_path)
    if any(approval.get(k)!=v for k,v in preparation_fields(context['author_seal_sha256'],context['preparation_plan_sha256'],plan).items()):raise RuntimeError('exact preparation approval mismatch')
    if approval['static_reviews']!=context['static_reviews']:raise RuntimeError('review identity mismatch')
    verify_reviews(approval,original)
    copies=preparation_copies(author,context['author_seal_sha256'],context['static_reviews']);copy_root=output/'preparation/tested_source'
    if context['tested_source_sha256']!=copies or context['tested_source_root']!=str(copy_root):raise RuntimeError('tested-source binding')
    exact_map(copy_root,copies)
    if context['child_argv']!=plan['child_argv'] or context['environment']!=environment(read(ROOT/'TOOL_INVENTORY.json'),output/'preparation/tmp'):raise RuntimeError('fixed child policy changed')
    lock_path=output/'preparation/LOCK.json'
    if sha(lock_path)!=lock_digest:raise RuntimeError('captured LOCK bytes changed')
    want=dict(schema=2,status='SINGLE_PREPARATION_STARTED',context_sha256=context_digest,
        author_seal_sha256=context['author_seal_sha256'],preparation_plan_sha256=context['preparation_plan_sha256'],
        approval_sha256=context['approval_sha256'],max_invocations=1,hard_seconds=20,automatic_retry=False)
    if read(lock_path)!=want:raise RuntimeError('exact LOCK identity')
    if sha(context_path)!=context_digest or sha(approval_path)!=context['approval_sha256']:raise RuntimeError('context changed during guard')
    return context,author,plan
def verify_preparation(context_digest,lock_digest,receipt_digest):
    out=ROOT/'preparation';context,author,plan=verify_context(out/'CONTEXT.json',context_digest,lock_digest)
    if Path(context['output_root'])!=ROOT:raise RuntimeError('preparation output identity')
    if sha(out/'receipt.json')!=receipt_digest:raise RuntimeError('captured PASS receipt changed')
    receipt=read(out/'receipt.json')
    if receipt['schema']!=2 or receipt['status']!='PASS' or receipt['context_sha256']!=context_digest or receipt['lock_sha256']!=lock_digest:raise RuntimeError('PASS receipt identity')
    if receipt['invocations']!=1 or receipt['hard_seconds']!=20 or receipt['automatic_retry'] is not False:raise RuntimeError('once-only receipt policy')
    argv=render_child(plan,out/'CONTEXT.json',context_digest,lock_digest,out/'tested_source',ROOT)
    verify_process(receipt['child'],argv,out/'tested_source'/PACKAGE,context['environment'])
    for stream,want in [('stdout',(plan['expected_stdout']+'\r\n').encode('ascii')),('stderr',b'')]:
        path=out/(stream+'.raw');raw=receipt['child'][stream]
        if raw!=dict(file='preparation/'+stream+'.raw',bytes=path.stat().st_size,sha256=sha(path)) or path.read_bytes()!=want:raise RuntimeError('exact preparation raw evidence')
    payload=read(out/'payload.json')
    if receipt['payload_sha256']!=sha(out/'payload.json'):raise RuntimeError('payload manifest bytes')
    names=fixture_names(plan,read(ROOT/'CASE_TABLE.json'));fixtures={'fixtures/'+n:sha(ROOT/'fixtures'/n) for n in names}
    if payload!=dict(schema=2,status='FIXED_NUMERICAL_PREPARATION_COMPLETE',context_sha256=context_digest,lock_sha256=lock_digest,
        tested_source_sha256=context['tested_source_sha256'],fixture_sha256=fixtures,numerical_reference_calls=40,
        probe_numerical_reference_calls=0,main_frames=30,fresh_frames=10,probe_frames=10,groups=10,automatic_retry=False):raise RuntimeError('exact payload manifest')
    exact_map(ROOT/'fixtures',{n[len('fixtures/'):]:h for n,h in fixtures.items()})
    if receipt['fixture_sha256']!=fixtures:raise RuntimeError('receipt fixture binding')
    evidence={'CONTEXT.json','LOCK.json','approval.json','payload.json','receipt.json','stdout.raw','stderr.raw'}
    evidence.update('tested_source/'+n for n in context['tested_source_sha256'])
    if inventory(out)!=evidence:raise RuntimeError('exact preparation evidence inventory')
    return author,{**fixtures,**{'preparation/'+n:h for n,h in file_map(out).items()}}
def verify_source(expected=None,expected_author=None):
    before=sha(ROOT/'SOURCE_SEAL.json')
    if expected is not None and before!=expected:raise RuntimeError('source seal changed')
    author=verify_author(expected_author);seal=read(ROOT/'SOURCE_SEAL.json')
    if seal['schema']!=2 or seal['author_seal_sha256']!=sha(ROOT/'AUTHOR_SEAL.json'):raise RuntimeError('author binding')
    _,prepared=verify_preparation(seal['preparation_context_sha256'],seal['preparation_lock_sha256'],seal['preparation_receipt_sha256'])
    expected_files={**author['sources'],'AUTHOR_SEAL.json':seal['author_seal_sha256'],**prepared}
    if seal['files']!=expected_files or seal['prepared_files']!=prepared:raise RuntimeError('complete source/evidence inventory binding')
    verify_map(ROOT,seal['files'])
    if seal['test_plan_sha256']!=sha(ROOT/'TEST_PLAN.json') or sha(ROOT/'SOURCE_SEAL.json')!=before:raise RuntimeError('plan/source changed')
    return seal
