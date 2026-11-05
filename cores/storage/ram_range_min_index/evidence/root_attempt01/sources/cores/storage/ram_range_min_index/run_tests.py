"""Separate future preparation/sealing/fixed25-child execution gates. No auto-run."""
from __future__ import annotations
import argparse,copy,hashlib,importlib.util,json,os,re,shutil,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
PACKAGE="cores/storage/ram_range_min_index"
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
def source_guard(author_digest,author_seal_digest):
    assert not sys.flags.optimize,'optimized Python forbidden'
    assert os.name=='nt','Windows Job execution required'
    assert sha(ROOT/'AUTHOR_INPUTS.json')==author_digest
    assert sha(ROOT/'AUTHOR_SEAL.json')==author_seal_digest,'approved author-seal bytes changed'
    a=read(ROOT/'AUTHOR_INPUTS.json')
    author_seal=read(ROOT/'AUTHOR_SEAL.json')
    assert author_seal['author_inputs_sha256']==author_digest
    assert author_seal['sources']==dict(a['sources'],**{'AUTHOR_INPUTS.json':author_digest})
    runtime={'prepared','preparation_evidence','evidence','failure_archive'}
    actual={p.relative_to(ROOT).as_posix():sha(p) for p in ROOT.rglob('*') if p.is_file() and p.relative_to(ROOT).parts[0] not in runtime and p.relative_to(ROOT).as_posix() not in ['AUTHOR_INPUTS.json','AUTHOR_SEAL.json','SOURCE_SEAL.json']}
    assert actual==a['sources'],'exact author source set changed'
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
def copy_inventory(hashes,author):
    result={PACKAGE+'/'+n:h for n,h in hashes.items()}
    result.update(author['external_sources'])
    result[author['baseline_manifest']]=author['baseline_manifest_sha256']
    return result
def freeze_copies(folder,hashes):
    for n,h in hashes.items():
        dest=local(folder,n);dest.parent.mkdir(parents=True,exist_ok=True)
        with dest.open('xb') as f:f.write(local(REPO,n).read_bytes())
        assert sha(dest)==h,n
def exact_files(folder,hashes):
    actual={p.relative_to(folder).as_posix():sha(p) for p in folder.rglob('*') if p.is_file()}
    assert actual==hashes,'exact file inventory/hash changed'
def preparation_required(author_digest,author_seal_digest,plan_digest,approval_path,copies):
    repository=(ROOT/'preparation_evidence/sources').resolve();package=repository/PACKAGE
    context=dict(original_package_root=str(ROOT),tested_repository_root=str(repository),
        tested_package_root=str(package),output_directory=str(ROOT/'prepared'),
        approval_path=str(approval_path.resolve()),preparation_cwd=str(package),tested_copies_sha256=copies,
        executed_source_paths={n:str(package/n) for n in ['prepare.py','oracle.py']})
    replacements={'{AUTHOR_SHA256}':author_digest,'{AUTHOR_SEAL_SHA256}':author_seal_digest,
        '{PREPARATION_PLAN_SHA256}':plan_digest,'{ORIGINAL_PACKAGE_ROOT}':str(ROOT),
        '{TESTED_REPOSITORY_ROOT}':str(repository),'{TESTED_PACKAGE_ROOT}':str(package),
        '{OUTPUT_DIRECTORY}':context['output_directory'],'{APPROVAL_PATH}':context['approval_path']}
    plan=read(ROOT/'PREPARATION_PLAN.json')
    assert plan['working_directory']=='{TESTED_PACKAGE_ROOT}' and plan['output_directory']=='{OUTPUT_DIRECTORY}'
    argv=list(plan['argv'])
    for token,value in replacements.items():argv=[x.replace(token,value) for x in argv]
    assert all('{' not in x or x=='{APPROVAL_SHA256}' for x in argv)
    context['preparation_argv_template']=argv
    return dict(author_sha256=author_digest,author_seal_sha256=author_seal_digest,
        preparation_plan_sha256=plan_digest,max_invocations=1,hard_seconds=20,automatic_retry=False,
        execution_context=context)
def prepared_files(receipt):
    raw=read(ROOT/'RAW_INPUTS.json');expected=set();counts={}
    for profile in raw['profiles']:
        labels=['main'];pc=dict(main=len(profile['commands']),resets={})
        for job in profile['reset_jobs']:
            labels.extend(['pre_'+job['name'],'fresh_'+job['name']])
            expected.add('prepared/fixtures/'+profile['name']+'/cancel_'+job['name']+'.txt')
            pc['resets'][job['name']]=dict(preload=len(job['preload']),fresh=len(job['fresh']))
        for label in labels:
            for ext in ['json','txt']:expected.add('prepared/fixtures/'+profile['name']+'/'+label+'.'+ext)
        counts[profile['name']]=pc
    assert set(receipt['files_sha256'])==expected and len(expected)==198
    assert receipt['counts']==counts
    files=dict(receipt['files_sha256'])
    files.update({'prepared/LOCK.json':sha(ROOT/'prepared/LOCK.json'),
        'prepared/receipt.json':sha(ROOT/'prepared/receipt.json')})
    exact_files(ROOT/'prepared',{n[len('prepared/'):]:h for n,h in files.items()})
    return files
def preparation_guard(context):
    a,t=source_guard(context['author_sha256'],context['author_seal_sha256'])
    assert sha(ROOT/'PREPARATION_PLAN.json')==context['preparation_plan_sha256']
    copies=copy_inventory({**a['sources'],'AUTHOR_INPUTS.json':context['author_sha256'],
        'AUTHOR_SEAL.json':context['author_seal_sha256']},a)
    required=preparation_required(context['author_sha256'],context['author_seal_sha256'],
        context['preparation_plan_sha256'],Path(context['approval_path']),copies)
    assert approval(Path(context['approval_path']),'b30-a-prepare-once-v1',required)==context['approval_sha256']
    out=ROOT/'preparation_evidence'
    assert sha(out/'receipt.json')==context['preparation_evidence_receipt_sha256']
    evidence=read(out/'receipt.json')
    identities=['author_sha256','author_seal_sha256','preparation_plan_sha256','approval_path','approval_sha256']
    assert all(evidence[k]==context[k] for k in identities),'preparation evidence identity mismatch'
    assert evidence['status']=='PREPARATION_PASS' and evidence['max_invocations']==1
    assert evidence['hard_seconds']==20 and evidence['automatic_retry'] is False
    assert evidence['returncode']==0 and not evidence['timed_out'] and evidence['failure'] is None
    assert 0<=evidence['elapsed_seconds']<20
    for stream,want in [('stdout',b'PASS PREPARATION FIXED_PROGRAMS\r\n'),('stderr',b'')]:
        path=out/(stream+'.raw')
        assert evidence[stream+'_file']==path.relative_to(ROOT).as_posix()
        assert evidence[stream+'_sha256']==sha(path) and evidence[stream+'_bytes']==path.stat().st_size
        assert path.read_bytes()==want
    assert evidence['tested_copies_sha256']==copies
    exact_files(out/'sources',copies)
    execution=required['execution_context']
    argv=[x.replace('{APPROVAL_SHA256}',context['approval_sha256']) for x in execution['preparation_argv_template']]
    for record in [context,evidence]:
        assert record['execution_context']==execution and record['argv']==argv
        assert record['working_directory']==execution['preparation_cwd']
    assert evidence['executed_sources_sha256']=={n:a['sources'][n] for n in ['prepare.py','oracle.py']}
    assert evidence['prepared_receipt_sha256']==context['prepared_receipt_sha256']
    assert evidence['prepared_lock_sha256']==context['prepared_lock_sha256']
    assert sha(ROOT/'prepared/receipt.json')==context['prepared_receipt_sha256']
    assert sha(ROOT/'prepared/LOCK.json')==context['prepared_lock_sha256']
    receipt=read(ROOT/'prepared/receipt.json');lock=read(ROOT/'prepared/LOCK.json')
    assert all(receipt[k]==context[k] and lock[k]==context[k] for k in identities)
    for record in [receipt,lock]:
        assert record['execution_context']==execution and record['argv']==argv
        assert record['working_directory']==execution['preparation_cwd']
        assert record['executed_sources_sha256']==evidence['executed_sources_sha256']
    assert receipt['status']=='PREPARED_FIXED_FINITE' and lock['status']=='STARTED_ONCE'
    assert receipt['preparation_invocations']==1 and receipt['automatic_retry'] is False and receipt['input_expansion'] is False
    return a,t,prepared_files(receipt)
def helper(folder):
    p=folder/PACKAGE/'process_tree.py'
    spec=importlib.util.spec_from_file_location('b30_a_frozen_job_helper',p)
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
    author_seal_digest=sha(ROOT/'AUTHOR_SEAL.json');plan_digest=sha(ROOT/'PREPARATION_PLAN.json')
    a,t=source_guard(author_digest,author_seal_digest)
    hashes=copy_inventory({**a['sources'],'AUTHOR_INPUTS.json':author_digest,'AUTHOR_SEAL.json':author_seal_digest},a)
    required=preparation_required(author_digest,author_seal_digest,plan_digest,approval_path,hashes)
    approved=approval(approval_path,'b30-a-prepare-once-v1',required)
    out=ROOT/'preparation_evidence';assert not out.exists() and not (ROOT/'prepared').exists()
    out.mkdir(exist_ok=False)
    execution=required['execution_context']
    argv=[x.replace('{APPROVAL_SHA256}',approved) for x in execution['preparation_argv_template']]
    copied_package=Path(execution['tested_package_root'])
    env,envinfo=environment(t)
    rec=dict(status='STARTED',author_sha256=author_digest,approval_sha256=approved,
             author_seal_sha256=author_seal_digest,approval_path=str(approval_path.resolve()),
             preparation_plan_sha256=plan_digest,max_invocations=1,hard_seconds=20,
             execution_context=execution,argv=argv,working_directory=execution['preparation_cwd'],
             executed_sources_sha256={n:a['sources'][n] for n in ['prepare.py','oracle.py']},
             automatic_retry=False,tested_copies_sha256=hashes,hardware='HW_UNVERIFIED',**envinfo)
    write(out/'receipt.json',rec)
    try:
        freeze_copies(out/'sources',hashes);exact_files(out/'sources',hashes)
        execute=helper(out/'sources')
        source_guard(author_digest,author_seal_digest);assert sha(approval_path.resolve())==approved
        assert sha(ROOT/'PREPARATION_PLAN.json')==plan_digest
        assert argv[2]==str(copied_package/'prepare.py')
        process=execute(argv,copied_package,env,20)
        for stream in ['stdout','stderr']:
            item=rawsave(out,stream+'.raw',process.pop(stream))
            for k,v in item.items():rec[stream+'_'+k]=v
        rec.update(process)
        assert rec['argv']==argv
        source_guard(author_digest,author_seal_digest);exact_files(out/'sources',hashes)
        assert sha(ROOT/'PREPARATION_PLAN.json')==plan_digest
        assert sha(approval_path.resolve())==approved
        assert rec['returncode']==0 and not rec['timed_out'] and rec['failure'] is None and rec['elapsed_seconds']<20
        assert (out/'stdout.raw').read_bytes()==b'PASS PREPARATION FIXED_PROGRAMS\r\n' and (out/'stderr.raw').read_bytes()==b''
        prepared=read(ROOT/'prepared/receipt.json');lock=read(ROOT/'prepared/LOCK.json')
        assert prepared['status']=='PREPARED_FIXED_FINITE' and lock['status']=='STARTED_ONCE'
        for key in ['author_sha256','author_seal_sha256','preparation_plan_sha256','approval_path','approval_sha256']:
            assert prepared[key]==rec[key] and lock[key]==rec[key]
        for record in [prepared,lock]:
            assert record['execution_context']==execution and record['argv']==argv
            assert record['working_directory']==execution['preparation_cwd']
            assert record['executed_sources_sha256']==rec['executed_sources_sha256']
        assert prepared['preparation_invocations']==1 and prepared['automatic_retry'] is False and prepared['input_expansion'] is False
        prepared_files(prepared)
        rec.update(status='PREPARATION_PASS',prepared_receipt_sha256=sha(ROOT/'prepared/receipt.json'),
            prepared_lock_sha256=sha(ROOT/'prepared/LOCK.json'))
        write(out/'receipt.json',rec);print('PASS PREPARATION_GATE',flush=True);return 0
    except Exception as exc:
        rec.update(status='FAILED_STOPPED',failure_detail=str(exc));write(out/'receipt.json',rec)
        archive(ROOT/'failure_archive/preparation01',[out,ROOT/'prepared'])
        print('FAILED_STOPPED PREPARATION',flush=True);return 1
def seal_sources(author_digest,author_seal_digest,plan_digest,prepared_digest,evidence_digest,approval_path):
    assert sha(ROOT/'preparation_evidence/receipt.json')==evidence_digest
    evidence=read(ROOT/'preparation_evidence/receipt.json')
    context=dict(author_sha256=author_digest,author_seal_sha256=author_seal_digest,
        preparation_plan_sha256=plan_digest,approval_path=str(approval_path.resolve()),
        approval_sha256=sha(approval_path.resolve()),prepared_receipt_sha256=prepared_digest,
        preparation_evidence_receipt_sha256=evidence_digest,prepared_lock_sha256=evidence['prepared_lock_sha256'],
        execution_context=evidence['execution_context'],argv=evidence['argv'],working_directory=evidence['working_directory'])
    a,t,prepared=preparation_guard(context)
    sources={**a['sources'],'AUTHOR_INPUTS.json':author_digest,'AUTHOR_SEAL.json':author_seal_digest,**prepared}
    for n,h in sources.items():assert sha(local(ROOT,n))==h,n
    target=ROOT/'SOURCE_SEAL.json';assert not target.exists()
    write(target,dict(schema='b30-a-source-seal-v2',status='FROZEN_NOT_EXECUTION_APPROVAL',
        author_sha256=author_digest,author_seal_sha256=author_seal_digest,sources=sources,external_sources=a['external_sources'],
        preparation=context,
        test_plan_sha256=sha(ROOT/'TEST_PLAN.json'),toolchain_sha256=sha(ROOT/'TOOLCHAIN.json'),
        children=read(ROOT/'TEST_PLAN.json')['children'],hardware='HW_UNVERIFIED'))
    print('SOURCE_SEAL_SHA256 '+sha(target),flush=True)
def seal_guard(digest):
    assert sha(ROOT/'SOURCE_SEAL.json')==digest
    s=read(ROOT/'SOURCE_SEAL.json');assert s['schema']=='b30-a-source-seal-v2'
    assert s['author_sha256']==s['preparation']['author_sha256'] and s['author_seal_sha256']==s['preparation']['author_seal_sha256']
    a,t,prepared=preparation_guard(s['preparation'])
    assert s['sources']=={**a['sources'],'AUTHOR_INPUTS.json':s['author_sha256'],
        'AUTHOR_SEAL.json':s['author_seal_sha256'],**prepared}
    assert s['external_sources']==a['external_sources'] and s['toolchain_sha256']==sha(ROOT/'TOOLCHAIN.json')
    for n,h in s['sources'].items():assert sha(local(ROOT,n))==h,n
    assert s['test_plan_sha256']==sha(ROOT/'TEST_PLAN.json') and s['children']==read(ROOT/'TEST_PLAN.json')['children']
    return s,t
def validate_simulation(c,raw,copies):
    lines=raw.decode('utf-8','strict').splitlines()
    assert lines,'empty simulation stdout'
    assert re.fullmatch(r'sim[/\\]tb_ram_range_min_index\.sv:\d+: \$finish called at \d+ \(1ps\)',lines[-1])
    assert sum('$finish' in x for x in lines)==1
    lines=lines[:-1];profile=c['profile']
    plan=read(copies/'RAW_INPUTS.json');p=next(x for x in plan['profiles'] if x['name']==profile)
    def program(label):
        rows=read(copies/'prepared/fixtures'/profile/(label+'.json'));result=[]
        for i,row in enumerate(rows):
            result.append(' '.join(map(str,['CMD',profile,label,i]+row['command'])))
            result.append(' '.join(map(str,['REC',profile,label,i]+row['response'])))
        return result,len(rows)
    if c['mode']=='main':
        expected,count=program('main')
        expected.append(f'PASS MAIN profile={profile} stall={c["stall"]} commands={count} records={count}')
        assert lines==expected,'exact main command/record stream mismatch';return
    cursor=total=0
    for job in p['reset_jobs']:
        label=job['name'];number=int(label[1:]);want,count=program('pre_'+label)
        assert lines[cursor:cursor+len(want)]==want;cursor+=len(want);total+=count
        assert lines[cursor]==' '.join(map(str,['CANCEL',profile,label]+job['cancel_command']));cursor+=1
        fields=lines[cursor].split();cursor+=1
        assert len(fields)==14 and fields[:3]==['PROBE',profile,label]
        # Canonical unsigned decimal fields, no alternate spellings or extra tokens.
        assert all(re.fullmatch(r'0|[1-9][0-9]*',x) for x in fields[3:])
        st,op,node,span,valid,status,ready,offer_valid,write,ret,lazy=map(int,fields[3:])
        P=1<<(p['buckets']-1).bit_length()
        assert op==job['cancel_command'][0] and 1<=node<2*P
        assert span and span<=P and span&(span-1)==0 and ready==0
        assert lazy in [0,1]
        assert valid==int(number>=8) and status==int(number==9) and offer_valid==int(number==11)
        if number==1:assert st==3 and node==1 and span==P
        elif number in [2,7]:
            assert st==13 and write==0 and ret==4
            if number==7:assert op==1 and node==1 and span==P
        elif number==3:assert st==13 and write==1 and ret==5
        elif number==4:assert st==13 and write==1 and ret==6
        elif number==5:
            assert st==13 and op==0 and write==1 and ret==7 and span==1 and lazy==1
            assert node==P+job['cancel_command'][1]
        elif number==6:
            assert st==13 and op==0 and write==1 and ret==7 and span==2 and lazy==0
            assert node==(P+job['cancel_command'][1])//2
        else:assert st==11
        assert lines[cursor]==' '.join(map(str,['OFFER',profile,label]+job['fresh'][0][1:]));cursor+=1
        for edge in range(3):
            assert lines[cursor]==f'RESETEDGE {profile} {label} {edge} 1 0 0';cursor+=1
        want,count=program('fresh_'+label)
        assert lines[cursor:cursor+len(want)]==want;cursor+=len(want);total+=count
        assert lines[cursor]==f'RESETDONE {profile} {label}';cursor+=1
    assert lines[cursor:]==[f'PASS RESET profile={profile} probes={len(p["reset_jobs"])} commands={total} records={total}']
def execute_once(digest,approval_path):
    s,t=seal_guard(digest)
    required=dict(source_seal_sha256=digest,test_plan_sha256=sha(ROOT/'TEST_PLAN.json'),
        author_sha256=s['author_sha256'],author_seal_sha256=sha(ROOT/'AUTHOR_SEAL.json'),children=s['children'],max_invocations=1,hard_seconds=20,automatic_retry=False)
    approved=approval(approval_path,'b30-a-fixed-hdl-once-v1',required)
    out=ROOT/'evidence/attempt01';assert not out.exists()
    out.mkdir(parents=True,exist_ok=False);(out/'artifacts').mkdir()
    hashes=copy_inventory({**s['sources'],'SOURCE_SEAL.json':digest},read(ROOT/'AUTHOR_INPUTS.json'))
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
            if current['kind']=='simulation':assert set(artifacts)=={'p0.vvp','p1.vvp','p2.vvp','p3.vvp'}
            argv=[x.replace('{ARTIFACT}',str((out/'artifacts').resolve())) for x in current['plan_argv']]
            result=execute(argv,out/'sources'/PACKAGE,env,20)
            raw_out,raw_err=result.pop('stdout'),result.pop('stderr')
            for stream,raw in [('stdout',raw_out),('stderr',raw_err)]:
                for key,value in rawsave(out,current['name']+'.'+stream+'.raw',raw).items():current[stream+'_'+key]=value
            current.update(result);current['working_directory']=str((out/'sources'/PACKAGE).resolve())
            if current['kind']=='compile':
                path=out/'artifacts'/(current['profile']+'.vvp')
                if path.exists():current['produced_artifact']=dict(name=path.name,sha256=sha(path),bytes=path.stat().st_size)
            assert not current['timed_out'] and current['failure'] is None and 0<=current['elapsed_seconds']<20
            if current['kind']=='reject':
                assert current['returncode']!=0 and b'ram_range_min_index_invalid_parameters__see_README' in raw_out+raw_err
                current['status']='EXPECTED_REJECT'
            else:
                assert current['returncode']==0 and raw_err==b''
                if current['kind'] in ['compile','compile_lint']:assert raw_out==b''
                elif current['kind']=='stored':assert raw_out==b'PASS STORED HASHES NO_ORACLE_REEXECUTION\r\n'
                else:validate_simulation(current,raw_out,out/'sources'/PACKAGE)
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
        rec.update(status='FINITE_UNIT_PASS',completed_children=25,simulations=12,named_parameter_rejects=6)
        write(out/'receipt.json',rec);print('PASS FIXED25 simulations=12 rejects=6',flush=True);return 0
    except Exception as exc:
        if current is not None:current['status']='TIMEOUT' if current.get('timed_out') else 'FAIL'
        rec.update(status='FAILED_STOPPED',failure_detail=str(exc),generated_artifacts_sha256=dict(artifacts),
            observed_artifacts_sha256={p.relative_to(out/'artifacts').as_posix():sha(p) for p in (out/'artifacts').rglob('*') if p.is_file()},
            not_run_children=[x['name'] for x in slots if x['status']=='NOT_RUN'])
        write(out/'receipt.json',rec);archive(ROOT/'failure_archive/attempt01',[out])
        print('FAILED_STOPPED FIXED25',flush=True);return 1
def main():
    parser=argparse.ArgumentParser();group=parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--prepare',action='store_true');group.add_argument('--seal',action='store_true');group.add_argument('--execute',action='store_true')
    parser.add_argument('--approved-author');parser.add_argument('--approved-seal');parser.add_argument('--approval',type=Path)
    parser.add_argument('--approved-author-seal');parser.add_argument('--approved-preparation-plan')
    parser.add_argument('--approved-prepared-receipt');parser.add_argument('--approved-preparation-evidence')
    a=parser.parse_args()
    if a.prepare:assert a.approved_author and a.approval;return prepare_once(a.approved_author,a.approval)
    if a.seal:
        assert a.approved_author and a.approved_author_seal and a.approved_preparation_plan
        assert a.approved_prepared_receipt and a.approved_preparation_evidence and a.approval
        seal_sources(a.approved_author,a.approved_author_seal,a.approved_preparation_plan,
            a.approved_prepared_receipt,a.approved_preparation_evidence,a.approval);return 0
    assert a.approved_seal and a.approval;return execute_once(a.approved_seal,a.approval)
if __name__=='__main__':raise SystemExit(main())
