"""Separate once-only preparation and fixed25-child HDL gates.

No entrypoint has run during source authoring. Root approves exact reviewed
hashes outside this package. Failed attempts and partial artifacts stay intact.
"""
from pathlib import Path
import argparse,hashlib,importlib.util,json,os,re,shutil,sys
if sys.flags.optimize:raise RuntimeError('optimized Python forbidden')
sys.dont_write_bytecode=True
P=Path(__file__).resolve().parent;R=P.parents[2]
MARKER=b'exact_directed_hamiltonian_cycle_invalid_parameters__see_README'

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_bytes())
def write(p,v):p.write_text(json.dumps(v,indent=2)+'\n',encoding='utf-8',newline='\n')
def local(base,name):
    assert name and not any(c in name for c in ('\\',':','\0','\n','\r'))
    p=(base/name).resolve();assert p.is_relative_to(base.resolve()) and not p.is_symlink();return p
def author_guard(digest):
    assert sha(P/'AUTHOR_INPUTS.json')==digest
    a=read(P/'AUTHOR_INPUTS.json')
    actual={q.relative_to(P).as_posix():sha(q) for q in P.rglob('*') if q.is_file()
            and q.relative_to(P).parts[0] not in ['preparation','evidence','history','failure_archive']
            and q.name not in ['AUTHOR_INPUTS.json','SOURCE_SEAL.json']}
    assert actual==a['files_sha256'], 'exact author inventory/hash changed'
    assert sha(R/'docs/snapshots/source_20261105_b28.json')==a['baseline_manifest_sha256']
    tool_guard();return a
def tool_guard():
    t=read(P/'TOOLCHAIN.json')
    for v in t['tools'].values():assert sha(Path(v['path']))==v['sha256']
    for group in ['runtime_dlls','runtime_modules','ivl_files_sha256']:
        for n,h in t[group].items():assert sha(local(R,n))==h,n
    folder=local(R,t['ivl_directory'])
    actual={p.relative_to(R).as_posix():sha(p) for p in folder.rglob('*') if p.is_file()}
    assert actual==t['ivl_files_sha256']
    return t
def approval(path,stage,digest):
    path=path.resolve();assert path.is_relative_to((R/'.git').resolve()) and not path.is_relative_to(P)
    obj=read(path);field='approved_author_sha256' if stage=='prepare' else 'approved_seal_sha256'
    assert obj['stage']==stage and obj['approved_by']=='root' and obj[field]==digest
    assert obj['max_invocations']==1 and obj['hard_seconds_per_tree']==20 and obj['automatic_retry'] is False
    assert obj['independent_reviews']
    for n,h in obj['independent_reviews'].items():assert sha(local(R,n))==h
    return sha(path)
def environment(t):
    env=os.environ.copy();env['PYTHONDONTWRITEBYTECODE']='1';env['PYTHONIOENCODING']='utf-8'
    env['PATH']=os.pathsep.join(str(local(R,n)) for n in t['path_prefix'])+os.pathsep+env.get('PATH','')
    return env
def copies(folder,hashes):
    assert not folder.exists();folder.mkdir(parents=True)
    for n,h in hashes.items():
        source=local(P,n);assert sha(source)==h
        dest=local(folder,n);dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(source,dest)
    exact(folder,hashes)
def exact(folder,hashes):
    assert {p.relative_to(folder).as_posix():sha(p) for p in folder.rglob('*') if p.is_file()}==hashes
def helpers(folder):
    modules=[]
    for name in ['tree_process','audit_raw']:
        spec=importlib.util.spec_from_file_location('b29_directed_tour_'+name,folder/(name+'.py'))
        assert spec and spec.loader
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);modules.append(module)
    return modules
def observe(run_child,attempt,record,env,cwd):
    metadata,out,err=run_child(dict(argv=record['argv'],cwd=str(cwd)),env)
    raw=attempt/'raw';raw.mkdir(exist_ok=True)
    for suffix,b in [('stdout',out),('stderr',err)]:
        path=raw/(record['name']+'.'+suffix);assert not path.exists();path.write_bytes(b)
        record[suffix]=path.relative_to(P).as_posix();record[suffix+'_sha256']=sha(path);record[suffix+'_bytes']=len(b)
    record.update(metadata);record['status']='OBSERVED'
    return out,err
def process_pass(record):
    assert not record['timed_out'] and record['launch_error'] is None
    assert record['elapsed_seconds']<20, 'hard execution limit reached'
def preserve_failure(attempt,receipt,generated=None):
    receipt['status']='FAILED_STOPPED_NO_RETRY';write(attempt/'receipt.json',receipt)
    files={p.relative_to(P).as_posix():sha(p) for p in attempt.rglob('*') if p.is_file()}
    if generated and generated.exists():files.update({p.relative_to(P).as_posix():sha(p) for p in generated.rglob('*') if p.is_file()})
    write(attempt/'FAILURE_ARCHIVE.json',dict(status='PERMANENT_PRESERVED_IN_PLACE',files_sha256=files,automatic_retry=False))

def prepare(digest,approval_path):
    a=author_guard(digest);approved=approval(approval_path,'prepare',digest);t=tool_guard()
    attempt=P/'preparation/attempt01';generated=P/'preparation/generated'
    assert not attempt.exists() and not generated.exists(), 'one preparation only'
    attempt.mkdir(parents=True);source_map={**a['files_sha256'],'AUTHOR_INPUTS.json':digest}
    receipt=dict(status='STARTED',kind='SINGLE_PREPARATION',approved_author_sha256=digest,approval_sha256=approved,source_copies_sha256=source_map,hard_seconds=20,automatic_retry=False,hardware='HW_UNVERIFIED')
    write(attempt/'receipt.json',receipt)
    try:
        copies(attempt/'tested_source',source_map);shutil.copyfile(approval_path,attempt/'approval.json')
        tree,raw=helpers(attempt/'tested_source')
        command=dict(name='prepare01',argv=[t['tools']['PYTHON']['path'],'-B',str(attempt/'tested_source/prepare.py'),'--once',str(generated)],status='RUNNING')
        receipt['record']=command;write(attempt/'receipt.json',receipt)
        out,err=observe(tree.run_child,attempt,command,environment(t),attempt/'tested_source')
        write(attempt/'receipt.json',receipt);process_pass(command)
        assert command['exit_code']==0 and not err
        summary=json.loads(out);assert summary==dict(status='PREPARED_FIXED_CASES_ONLY',normal_cases=40,normal_replays=80,reset_jobs=6,files=8)
        raw.verify_prepared(generated,read(P/'CASE_PLAN.json'))
        author_guard(digest);exact(attempt/'tested_source',source_map);assert sha(approval_path)==approved
        command['status']='PASS';receipt.update(status='PREPARATION_PASS',prepared_manifest_sha256=sha(generated/'MANIFEST.json'),generated_files=9)
        write(attempt/'receipt.json',receipt);print('PASS PREPARATION_ONCE');return 0
    except Exception as e:
        receipt['failure']=dict(type=type(e).__name__,message=str(e))
        if 'record' in receipt and receipt['record']['status']!='PASS':receipt['record']['status']='FAIL'
        preserve_failure(attempt,receipt,generated);print('FAILED_STOPPED PREPARATION');return 1

def hdl_checkpoint(seal,digest,approval_path,approved,attempt,source_map,artifact_map):
    assert sha(P/'SOURCE_SEAL.json')==digest and sha(approval_path)==approved
    author_guard(seal['author_sha256'])
    for n,h in seal['input_files_sha256'].items():assert sha(local(P,n))==h
    exact(attempt/'tested_source',source_map)
    actual={p.relative_to(P).as_posix():sha(p) for p in (attempt/'artifacts').rglob('*') if p.is_file()}
    assert actual==artifact_map, 'exact recursive artifact inventory/hash changed'

def hdl(digest,approval_path):
    assert sha(P/'SOURCE_SEAL.json')==digest
    seal=read(P/'SOURCE_SEAL.json');a=author_guard(seal['author_sha256'])
    approved=approval(approval_path,'hdl',digest);t=tool_guard();plan=read(P/'TEST_PLAN.json')
    assert seal['test_plan_sha256']==sha(P/'TEST_PLAN.json') and seal['children']==plan['children']
    assert read(P/'preparation/attempt01/receipt.json')['status']=='PREPARATION_PASS'
    for n,h in seal['input_files_sha256'].items():assert sha(local(P,n))==h
    attempt=P/'evidence/attempt01';assert not attempt.exists();attempt.mkdir(parents=True)
    source_map={**seal['input_files_sha256'],'SOURCE_SEAL.json':digest}
    receipt=dict(status='STARTED',source_seal_sha256=digest,approval_sha256=approved,source_copies_sha256=source_map,records=[dict(name=c['name'],status='NOT_RUN') for c in plan['children']],results=[],generated_artifacts_sha256={},hard_seconds=20,automatic_retry=False,hardware='HW_UNVERIFIED')
    write(attempt/'receipt.json',receipt);current=None;phase='setup'
    try:
        copies(attempt/'tested_source',source_map);shutil.copyfile(approval_path,attempt/'approval.json')
        tree,raw=helpers(attempt/'tested_source')
        generated=attempt/'tested_source/preparation/generated'
        expected=raw.verify_prepared(generated,read(P/'CASE_PLAN.json'))
        artifacts=attempt/'artifacts';artifacts.mkdir();env=environment(t)
        expansion={k:v['path'] for k,v in t['tools'].items()};expansion['ARTIFACTS']=str(artifacts)
        for i,c in enumerate(plan['children']):
            current=None;phase='pre_checkpoint:'+c['name']
            hdl_checkpoint(seal,digest,approval_path,approved,attempt,source_map,receipt['generated_artifacts_sha256'])
            argv=[x.format(**expansion) for x in c['argv']]
            current=dict(name=c['name'],kind=c['kind'],argv=argv,status='RUNNING');receipt['records'][i]=current
            phase='child:'+c['name']
            write(attempt/'receipt.json',receipt)
            out,err=observe(tree.run_child,attempt,current,env,attempt/'tested_source');write(attempt/'receipt.json',receipt)
            process_pass(current)
            if c['kind']=='reject':
                assert current['exit_code'] is not None and 0<current['exit_code']<128 and MARKER in out+err
                current['status']='EXPECTED_REJECT'
            else:
                assert current['exit_code']==0 and not err
                if c['kind']=='simulation':
                    p=expected['profiles'][c['profile']];frames=p['reset' if c['reset'] else 'main']
                    receipt['results'].append(raw.audit(out,p['profile'],frames,c['mode'],c['reset']))
                else:assert not out
                if c['kind']=='compile':
                    artifact=artifacts/(c['profile']+'.vvp');text=artifact.read_text('utf-8')
                    embedded={Path(n).resolve().relative_to(R).as_posix() for n in re.findall(r'^:vpi_module "([^"]+)";',text,re.MULTILINE)}
                    assert embedded==set(t['runtime_modules'])
                    receipt['generated_artifacts_sha256'][artifact.relative_to(P).as_posix()]=sha(artifact)
                current['status']='PASS'
            phase='post_checkpoint:'+c['name']
            hdl_checkpoint(seal,digest,approval_path,approved,attempt,source_map,receipt['generated_artifacts_sha256'])
            write(attempt/'receipt.json',receipt)
        current=None;phase='final_checkpoint'
        hdl_checkpoint(seal,digest,approval_path,approved,attempt,source_map,receipt['generated_artifacts_sha256'])
        assert len(receipt['records'])==25 and len(receipt['results'])==12 and len(receipt['generated_artifacts_sha256'])==5
        receipt.update(status='UNIT_SIM_PASS_FIXED25',max_child_seconds=max(r['elapsed_seconds'] for r in receipt['records']),successful_artifacts_retained_for_independent_review=True)
        write(attempt/'receipt.json',receipt);print('PASS FIXED25_HDL');return 0
    except Exception as e:
        receipt['failure']=dict(type=type(e).__name__,message=str(e),phase=phase)
        if current:current['status']='FAIL'
        preserve_failure(attempt,receipt);print('FAILED_STOPPED HDL');return 1

def main():
    parser=argparse.ArgumentParser();parser.add_argument('stage',choices=['prepare','hdl'])
    parser.add_argument('--approved',required=True);parser.add_argument('--approval',type=Path,required=True)
    args=parser.parse_args()
    return prepare(args.approved,args.approval) if args.stage=='prepare' else hdl(args.approved,args.approval)
if __name__=='__main__':raise SystemExit(main())
