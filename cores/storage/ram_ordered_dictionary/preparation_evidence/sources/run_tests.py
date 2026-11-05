"""Separate future preparation/sealing/fixed22-child execution gates. No auto-run."""
from __future__ import annotations
import argparse,copy,hashlib,importlib.util,json,os,re,shutil,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p):return json.loads(p.read_bytes())
def local(base,name):
    p=(base/name).resolve();assert p.is_relative_to(base.resolve());return p
def write(p,obj):
    with p.open('w',encoding='utf-8',newline='\n') as f:json.dump(obj,f,indent=2);f.write('\n')
def rawsave(folder,name,raw):
    path=folder/name
    with path.open('xb') as f:f.write(raw)
    return {'file':path.relative_to(ROOT).as_posix(),'sha256':sha(path),'bytes':len(raw)}
def source_guard(author_digest):
    assert not sys.flags.optimize,'optimized Python forbidden'
    assert os.name=='nt','Windows Job execution required'
    assert sha(ROOT/'AUTHOR_INPUTS.json')==author_digest
    a=read(ROOT/'AUTHOR_INPUTS.json')
    for n,h in a['sources'].items():assert sha(local(ROOT,n))==h,n
    for n,h in a['external_sources'].items():assert sha(local(REPO,n))==h,n
    assert sha(local(REPO,a['baseline_manifest']))==a['baseline_manifest_sha256']
    t=read(ROOT/'TOOLCHAIN.json')
    for v in t['tools'].values():assert sha(Path(v['path']))==v['sha256']
    for n,v in t['PE_graph'].items():assert sha(local(REPO,n))==v['sha256'],n
    for n,h in t['compiler_configs_sha256'].items():assert sha(local(REPO,n))==h,n
    return a,t
def approval(path,schema,required):
    path=path.resolve();assert not path.is_relative_to(ROOT)
    obj=read(path);assert obj['schema']==schema and obj['approved_by']=='root'
    assert all(obj.get(k)==v for k,v in required.items()),'exact root approval mismatch'
    return sha(path)
def environment(t):
    env=os.environ.copy();before=env.get('PATH','')
    env['PATH']=os.pathsep.join(t['path_prefix'])+(os.pathsep+before if before else '')
    env['PYTHONDONTWRITEBYTECODE']='1';env['PYTHONIOENCODING']='utf-8'
    return env,dict(inherited_PATH_sha256=hashlib.sha256(before.encode()).hexdigest(),
                    effective_PATH_sha256=hashlib.sha256(env['PATH'].encode()).hexdigest(),path_prefix=t['path_prefix'])
def freeze_copies(folder,hashes):
    for n,h in hashes.items():
        dest=local(folder,n);dest.parent.mkdir(parents=True,exist_ok=True)
        with dest.open('xb') as f:f.write(local(ROOT,n).read_bytes())
        assert sha(dest)==h,n
def exact_files(folder,hashes):
    actual={p.relative_to(folder).as_posix():sha(p) for p in folder.rglob('*') if p.is_file()}
    assert actual==hashes,'exact file inventory/hash changed'
def helper(folder):
    p=folder/'process_tree.py'
    spec=importlib.util.spec_from_file_location('b29_a_frozen_job_helper',p)
    assert spec and spec.loader;sys.dont_write_bytecode=True
    mod=importlib.util.module_from_spec(spec);spec.loader.exec_module(mod)
    return mod.execute
def archive(folder,names):
    folder.mkdir(parents=True,exist_ok=False);inventory={}
    for base in names:
        if not base.exists():continue
        for path in sorted(base.rglob('*')):
            if path.is_file():
                n=path.relative_to(ROOT).as_posix();dest=local(folder,n)
                dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(path,dest)
                inventory[n]=sha(dest);assert inventory[n]==sha(path)
    write(folder/'ARCHIVE.json',dict(status='FAILED_STOPPED_NO_RETRY',files_sha256=inventory,files=len(inventory),automatic_retry=False))
def prepare_once(author_digest,approval_path):
    a,t=source_guard(author_digest);pp=read(ROOT/'PREPARATION_PLAN.json')
    required=dict(author_sha256=author_digest,preparation_plan_sha256=sha(ROOT/'PREPARATION_PLAN.json'),
                  max_invocations=1,hard_seconds=20,automatic_retry=False)
    approved=approval(approval_path,'b29-a-prepare-once-v1',required)
    out=ROOT/'preparation_evidence';assert not out.exists() and not (ROOT/'prepared').exists()
    out.mkdir(exist_ok=False)
    hashes={**a['sources'],'AUTHOR_INPUTS.json':author_digest}
    env,envinfo=environment(t)
    rec=dict(status='STARTED',author_sha256=author_digest,approval_sha256=approved,
             preparation_plan_sha256=required['preparation_plan_sha256'],hard_seconds=20,
             automatic_retry=False,tested_copies_sha256=hashes,hardware='HW_UNVERIFIED',**envinfo)
    write(out/'receipt.json',rec)
    try:
        freeze_copies(out/'sources',hashes);exact_files(out/'sources',hashes)
        execute=helper(out/'sources')
        source_guard(author_digest);assert sha(approval_path.resolve())==approved
        argv=[x.replace('{AUTHOR_SHA256}',author_digest) for x in pp['argv']]
        process=execute(argv,ROOT,env,20)
        for stream in ['stdout','stderr']:
            item=rawsave(out,stream+'.raw',process.pop(stream))
            for k,v in item.items():rec[stream+'_'+k]=v
        rec.update(process)
        source_guard(author_digest);exact_files(out/'sources',hashes)
        assert sha(approval_path.resolve())==approved
        assert rec['returncode']==0 and not rec['timed_out'] and rec['failure'] is None and rec['elapsed_seconds']<20
        assert (out/'stdout.raw').read_bytes()==b'PASS PREPARATION FIXED_PROGRAMS\r\n' and (out/'stderr.raw').read_bytes()==b''
        prepared=read(ROOT/'prepared/receipt.json');assert prepared['author_sha256']==author_digest and prepared['status']=='PREPARED_FIXED_FINITE'
        for n,h in prepared['files_sha256'].items():assert sha(local(ROOT,n))==h
        rec.update(status='PREPARATION_PASS',prepared_receipt_sha256=sha(ROOT/'prepared/receipt.json'))
        write(out/'receipt.json',rec);print('PASS PREPARATION_GATE',flush=True);return 0
    except Exception as exc:
        rec.update(status='FAILED_STOPPED',failure_detail=str(exc));write(out/'receipt.json',rec)
        archive(ROOT/'failure_archive/preparation01',[out,ROOT/'prepared'])
        print('FAILED_STOPPED PREPARATION',flush=True);return 1
def seal_sources(author_digest):
    a,t=source_guard(author_digest);receipt=read(ROOT/'prepared/receipt.json')
    evidence=read(ROOT/'preparation_evidence/receipt.json')
    assert evidence['status']=='PREPARATION_PASS' and evidence['author_sha256']==author_digest
    assert receipt['author_sha256']==author_digest and receipt['status']=='PREPARED_FIXED_FINITE'
    sources={**a['sources'],'AUTHOR_INPUTS.json':author_digest,
             **receipt['files_sha256'],'prepared/receipt.json':sha(ROOT/'prepared/receipt.json'),
             'prepared/LOCK.json':sha(ROOT/'prepared/LOCK.json')}
    for n,h in sources.items():assert sha(local(ROOT,n))==h,n
    target=ROOT/'SOURCE_SEAL.json';assert not target.exists()
    write(target,dict(schema='b29-a-source-seal-v1',status='FROZEN_NOT_EXECUTION_APPROVAL',
        author_sha256=author_digest,sources=sources,external_sources=a['external_sources'],
        preparation_evidence_receipt_sha256=sha(ROOT/'preparation_evidence/receipt.json'),
        test_plan_sha256=sha(ROOT/'TEST_PLAN.json'),toolchain_sha256=sha(ROOT/'TOOLCHAIN.json'),
        children=read(ROOT/'TEST_PLAN.json')['children'],hardware='HW_UNVERIFIED'))
    print('SOURCE_SEAL_SHA256 '+sha(target),flush=True)
def seal_guard(digest):
    assert sha(ROOT/'SOURCE_SEAL.json')==digest
    s=read(ROOT/'SOURCE_SEAL.json');a,t=source_guard(s['author_sha256'])
    assert s['schema']=='b29-a-source-seal-v1'
    for n,h in s['sources'].items():assert sha(local(ROOT,n))==h,n
    assert s['test_plan_sha256']==sha(ROOT/'TEST_PLAN.json') and s['children']==read(ROOT/'TEST_PLAN.json')['children']
    assert s['preparation_evidence_receipt_sha256']==sha(ROOT/'preparation_evidence/receipt.json')
    return s,t
def validate_simulation(c,raw,copies):
    lines=raw.decode('utf-8','strict').splitlines()
    finish=re.fullmatch(r'sim[/\\]tb_ram_ordered_dictionary\.sv:\d+: \$finish called at \d+ \(1ps\)',lines[-1])
    assert finish and sum('$finish' in x for x in lines)==1
    lines=lines[:-1];expected=[];profile=c['profile']
    rawplan=read(copies/'RAW_INPUTS.json')
    meta=next(p for p in rawplan['profiles'] if p['name']==profile)
    def program(rows):
        out=[]
        for i,row in enumerate(rows):
            out.append(' '.join(map(str,['CMD',profile,i]+row['command']+[len(row['responses'])])))
            for ri,response in enumerate(row['responses']):
                out.append(' '.join(map(str,['REC',profile,i,ri]+response)))
        return out
    if c['mode']=='main':
        rows=read(copies/'prepared/fixtures'/profile/'main.json');expected=program(rows)
        records=sum(len(x['responses']) for x in rows)
        expected.append(f'PASS MAIN profile={profile} stall={c["stall"]} commands={len(rows)} records={records}')
        assert lines==expected,'main exact command/response stream mismatch';return
    cursor=0;total_commands=total_records=0
    state={'search_wait':3,'bound_wait':6,'insert_shift_read':9,'insert_shift_write':11,
           'delete_shift_write':11,'final_write':13,'response_held':18,'range_row_held':18,'range_end_held':18,'next_offer':18}
    for i,target in enumerate(rawplan['reset_targets'][profile]):
        row=lines[cursor].split();cursor+=1
        assert len(row)==10 and row[:4]==['PROBE',profile,str(i),target]
        st,op,count,valid,kind,ready=map(int,row[4:])
        wanted_op=1 if target.startswith('insert_') or target=='final_write' else 2 if target=='delete_shift_write' else 4 if target in ['range_row_held','range_end_held','next_offer'] else 0
        assert st==state[target] and op==wanted_op and count==(1 if meta['capacity']==1 else 3) and ready==0
        held=target in ['response_held','range_row_held','range_end_held','next_offer']
        assert valid==int(held) and (not held or kind==({'response_held':0,'range_end_held':2}.get(target,1)))
        if target=='next_offer':
            assert lines[cursor]==f'OFFER {profile} {i} 0 {(1<<meta["v_w"])-1}';cursor+=1
        for edge in range(3):
            assert lines[cursor]==f'RESETEDGE {profile} {i} {edge} 0 0';cursor+=1
        if target=='next_offer':
            assert lines[cursor]==f'NEXTHANDSHAKE {profile} {i}';cursor+=1
        rows=read(copies/'prepared/fixtures'/profile/('reset_'+target+'.json'));want=program(rows)
        assert lines[cursor:cursor+len(want)]==want,'fresh reset commands/records mismatch';cursor+=len(want)
        assert lines[cursor]==f'RESETDONE {profile} {i} {target}';cursor+=1
        total_commands+=len(rows);total_records+=sum(len(x['responses']) for x in rows)
    count=len(rawplan['reset_targets'][profile])
    assert lines[cursor:]==[f'PASS RESET profile={profile} probes={count} commands={total_commands} records={total_records}']
def execute_once(digest,approval_path):
    s,t=seal_guard(digest)
    required=dict(source_seal_sha256=digest,test_plan_sha256=sha(ROOT/'TEST_PLAN.json'),
        author_sha256=s['author_sha256'],children=s['children'],max_invocations=1,hard_seconds=20,automatic_retry=False)
    approved=approval(approval_path,'b29-a-fixed-hdl-once-v1',required)
    out=ROOT/'evidence/attempt01';assert not out.exists()
    out.mkdir(parents=True,exist_ok=False);(out/'artifacts').mkdir()
    hashes={**s['sources'],'SOURCE_SEAL.json':digest}
    slots=[]
    for child in s['children']:
        slot=copy.deepcopy(child);slot['plan_argv']=slot.pop('argv');slot['status']='NOT_RUN';slots.append(slot)
    env,envinfo=environment(t);rec=dict(status='STARTED',source_seal_sha256=digest,approval_sha256=approved,
        author_sha256=s['author_sha256'],test_plan_sha256=sha(ROOT/'TEST_PLAN.json'),tested_copies_sha256=hashes,
        children=slots,generated_artifacts_sha256={},hard_seconds=20,automatic_retry=False,
        hardware='HW_UNVERIFIED',**envinfo)
    write(out/'receipt.json',rec);current=None;artifacts={}
    try:
        freeze_copies(out/'sources',hashes)
        exact_files(out/'sources',hashes);execute=helper(out/'sources')
        for current in slots:
            seal_guard(digest);exact_files(out/'sources',hashes);exact_files(out/'artifacts',artifacts)
            assert sha(approval_path.resolve())==approved
            if current['kind']=='compile':assert not (out/'artifacts'/(current['profile']+'.vvp')).exists()
            if current['kind']=='simulation':assert set(artifacts)=={'p0.vvp','p1.vvp','p2.vvp'}
            argv=[x.replace('{ARTIFACT}',str((out/'artifacts').resolve())) for x in current['plan_argv']]
            result=execute(argv,out/'sources',env,20)
            raw_out,raw_err=result.pop('stdout'),result.pop('stderr')
            for stream,raw in [('stdout',raw_out),('stderr',raw_err)]:
                for key,value in rawsave(out,current['name']+'.'+stream+'.raw',raw).items():current[stream+'_'+key]=value
            current.update(result);current['working_directory']=str((out/'sources').resolve())
            if current['kind']=='compile':
                path=out/'artifacts'/(current['profile']+'.vvp')
                if path.exists():current['produced_artifact']=dict(name=path.name,sha256=sha(path),bytes=path.stat().st_size)
            assert not current['timed_out'] and current['failure'] is None and 0<=current['elapsed_seconds']<20
            if current['kind']=='reject':
                assert current['returncode']!=0 and b'ram_ordered_dictionary_invalid_parameters__see_README' in raw_out+raw_err
                current['status']='EXPECTED_REJECT'
            else:
                assert current['returncode']==0 and raw_err==b''
                if current['kind'] in ['compile','compile_lint']:assert raw_out==b''
                elif current['kind']=='stored':assert raw_out==b'PASS STORED HASHES NO_ORACLE_REEXECUTION\r\n'
                else:validate_simulation(current,raw_out,out/'sources')
                if current['kind']=='compile':
                    produced=current['produced_artifact'];assert produced['bytes']>0
                    artifacts[produced['name']]=produced['sha256']
                    text=(out/'artifacts'/produced['name']).read_text('utf-8')
                    modules={Path(n).resolve().relative_to(REPO).as_posix() for n in re.findall(r'^:vpi_module "([^"]+)";',text,re.MULTILINE)}
                    assert modules==set(t['VPI_paths'])
                current['status']='PASS'
            exact_files(out/'artifacts',artifacts);exact_files(out/'sources',hashes);seal_guard(digest)
            assert sha(approval_path.resolve())==approved
            rec['generated_artifacts_sha256']=dict(artifacts);write(out/'receipt.json',rec)
        rec.update(status='FINITE_UNIT_PASS',completed_children=22,simulations=9,named_parameter_rejects=7)
        write(out/'receipt.json',rec);print('PASS FIXED22 simulations=9 rejects=7',flush=True);return 0
    except Exception as exc:
        if current is not None:current['status']='TIMEOUT' if current.get('timed_out') else 'FAIL'
        rec.update(status='FAILED_STOPPED',failure_detail=str(exc),generated_artifacts_sha256=dict(artifacts),
            observed_artifacts_sha256={p.relative_to(out/'artifacts').as_posix():sha(p) for p in (out/'artifacts').rglob('*') if p.is_file()},
            not_run_children=[x['name'] for x in slots if x['status']=='NOT_RUN'])
        write(out/'receipt.json',rec);archive(ROOT/'failure_archive/attempt01',[out])
        print('FAILED_STOPPED FIXED22',flush=True);return 1
def main():
    parser=argparse.ArgumentParser();group=parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--prepare',action='store_true');group.add_argument('--seal',action='store_true');group.add_argument('--execute',action='store_true')
    parser.add_argument('--approved-author');parser.add_argument('--approved-seal');parser.add_argument('--approval',type=Path)
    a=parser.parse_args()
    if a.prepare:assert a.approved_author and a.approval;return prepare_once(a.approved_author,a.approval)
    if a.seal:assert a.approved_author;seal_sources(a.approved_author);return 0
    assert a.approved_seal and a.approval;return execute_once(a.approved_seal,a.approval)
if __name__=='__main__':raise SystemExit(main())
