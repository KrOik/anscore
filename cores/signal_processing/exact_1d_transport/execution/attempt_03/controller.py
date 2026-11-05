"""Root-owned B TB fscanf repair:22 new children +3 exact carried records, no preparation."""
from pathlib import Path,PurePosixPath
import argparse,copy,hashlib,importlib.util,json,os,re,shutil,sys
if sys.flags.optimize:raise RuntimeError('optimized Python forbidden')
sys.dont_write_bytecode=True
R=Path(__file__).resolve().parent.parent
PROFILES={
 'b':dict(package='cores/signal_processing/exact_1d_transport',attempt='execution/attempt_03',
  author='27c7e7ef5e3c1c765020b510557c97aa6793b0cd7ce31a5bcc5fd1ab0d5bceac',
  seal='5d939604edf97dbaf0b0de181bbb53fc04dcc9d1973153936090b017dc50b2a1',
  failed_receipt='execution/attempt_02/receipt.json',
  failed_sha='69130a0e6ae15004f7284ad3bcb35c9e97b598bb79ffd5c7e52a01cfe65a6d89',
  finite='FINITE_PLAN.json',finite_sha='d4e3909bece619d0cf08a8a35f608ebf903892b7fd2c193b77e9f46ff4719cf1',
  children=22,simulations=10,rejects=8,carry=3)
}
TOOL_SHA='9731eaf4054dc619c878347f39bb3e8f2e02d6f739c46ae0c07feccd9373060b'
OVERLAY_NAME='sim/tb_transport.sv'
OVERLAY_PATH='.git/b30-b-fscanf-tb-draft01/tb_transport.sv'
OVERLAY_SHA='63987e8bbc53e0f9f2e1d906c2f5f0b8886dbc78a7d4b5dc02cd5e3f991da131'
BACKEND='D:/anscore/tools/oss-cad-suite/oss-cad-suite/lib/ivl'

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def read(path):return json.loads(path.read_bytes())
def write(path,value,exclusive=False):
    with path.open('x' if exclusive else 'w',encoding='utf-8',newline='\n') as stream:
        stream.write(json.dumps(value,indent=2)+'\n')
def local(base,name):
    relative=PurePosixPath(name)
    assert name and not relative.is_absolute() and '..' not in relative.parts
    assert not any(c in name for c in ('\\',':','\0','\r','\n'))
    value=(base/name).resolve();assert value.is_relative_to(base.resolve()) and not value.is_symlink()
    return value
def inventory(folder,exclude=None):
    result={}
    for path in folder.rglob('*'):
        if path.is_file():
            name=path.relative_to(folder).as_posix()
            if exclude and (name==exclude or name.startswith(exclude+'/')):continue
            assert path.resolve().is_relative_to(folder.resolve()) and not path.is_symlink()
            result[name]=sha(path)
    return result
def exact(folder,expected):assert inventory(folder)==expected,'exact copied path/hash set changed'
def load(folder,name):
    spec=importlib.util.spec_from_file_location('b30_repair_'+name.replace('/','_'),local(folder,name+'.py'))
    assert spec and spec.loader
    result=importlib.util.module_from_spec(spec);spec.loader.exec_module(result);return result
def reviews_guard(reviews):
    assert len(reviews)>=2
    for name,digest in reviews.items():
        path=local(R,name);assert path.is_relative_to(R/'.git') and sha(path)==digest

def derive(key,p):
    assert key=='b';cfg=PROFILES[key]
    assert sha(p/'AUTHOR_SEAL.json')==cfg['author'] and sha(p/'SOURCE_SEAL.json')==cfg['seal']
    assert sha(p/cfg['finite'])==cfg['finite_sha'] and sha(p/'TOOL_INVENTORY.json')==TOOL_SHA
    author=read(p/'AUTHOR_SEAL.json');seal=read(p/'SOURCE_SEAL.json')
    sources={**author['files_sha256'],'AUTHOR_SEAL.json':cfg['author'],
             'SOURCE_SEAL.json':cfg['seal'],**seal['prepared_sha256']}
    sources[OVERLAY_NAME]=OVERLAY_SHA;assert len(sources)==31
    children=copy.deepcopy(read(p/cfg['finite'])['children']);changed=0
    for child in children:
        if child['tool']=='IVERILOG':
            assert child['args'][:2]==['-B',BACKEND];child['args']=child['args'][2:];changed+=1
        else:assert child['tool']=='VVP' and child['kind']=='simulation'
    assert changed==15 and len(children)==25
    children=[c for c in children if c['name'] not in ('lint-core','lint-example','compile-example')]
    assert len(children)==22 and sum(c['kind']=='compile' for c in children)==4
    assert sum(c['kind']=='simulation' for c in children)==10 and sum(c['kind']=='reject' for c in children)==8
    return children,sources,{OVERLAY_NAME:dict(path=OVERLAY_PATH,sha256=OVERLAY_SHA)}

def carried_guard(key,p,plan):
    assert key=='b';cfg=PROFILES[key];receipt_path=p/cfg['failed_receipt']
    assert sha(receipt_path)==plan['parent_failed_receipt_sha256']==cfg['failed_sha']
    old=read(receipt_path);assert old['status']=='FAILED_STOPPED_NO_AUTOMATIC_RETRY'
    assert old['results']==[] and old['model_calls']==0 and old['preparation_reexecution'] is False
    records=old['records']
    assert [(r['name'],r['status']) for r in records if r['status']!='NOT_RUN']==[
        ('lint-core','PASS'),('lint-example','PASS'),('compile-p0','PASS'),('compile-p1','PASS'),
        ('compile-p2','PASS'),('compile-p3','PASS'),('compile-example','PASS'),('base-p0','FAIL')]
    assert sum(r['status']=='NOT_RUN' for r in records)==17
    selected=[records[i] for i in (0,1,6)]
    assert plan['carried_records']==selected
    for passed in selected:
        assert passed['status']=='PASS' and passed['returncode']==0 and not passed['timed_out'] and passed['failure'] is None
        assert 0<=passed['elapsed_seconds']<20 and passed['process_tree_cleanup']['windows_kill_on_close_job_closed'] is True
        for suffix in ('stdout','stderr'):
            raw=local(p,passed[suffix]);assert sha(raw)==passed[suffix+'_sha256'] and raw.read_bytes()==b''
    imported={'example.vvp':dict(path='execution/attempt_02/artifacts/example.vvp',
        sha256='65ae4227919fd4e65f76ded36b82dcee851f67a78874c9ae4edcabeff4753ae9',
        parent_record='compile-example')}
    assert plan['carried_artifacts']==imported
    for name,entry in imported.items():
        assert sha(local(p,entry['path']))==entry['sha256']==old['generated_artifacts_sha256'][name]
        assert selected[-1]['observed_artifacts_sha256'][name]==entry['sha256']
    # Old observed_artifacts dictionaries stay historical and are not imported as active maps.
    return [dict(**r,execution='CARRIED_NOT_RERUN',parent_receipt_sha256=cfg['failed_sha']) for r in selected]

def approved_context(plan_path,plan_digest,approval_path):
    assert sha(plan_path)==plan_digest and plan_path.is_relative_to(R/'.git')
    plan=read(plan_path);assert plan['schema']=='anscore-b30-qualified-repair-plan-v1'
    assert plan['controller_sha256']==sha(Path(__file__))
    key=plan['channel'];assert key in PROFILES
    cfg=PROFILES[key];p=local(R,cfg['package']);children,sources,overlay=derive(key,p)
    assert plan['package']==cfg['package'] and plan['attempt']==cfg['attempt']
    assert plan['children']==children and plan['copy_files_sha256']==sources and plan['overlays']==overlay
    assert plan['preparation_reexecution'] is False and plan['model_calls']==0
    assert plan['first_failure_stop'] is True and plan['hard_seconds_per_tree']==20 and plan['automatic_retry'] is False
    assert plan['parent_author_sha256']==cfg['author'] and plan['parent_source_seal_sha256']==cfg['seal']
    assert inventory(p)==plan['baseline_package_files_sha256']
    for name,entry in overlay.items():assert sha(local(R,entry['path']))==entry['sha256']==sources[name]
    carried=carried_guard(key,p,plan)
    approval_path=approval_path.resolve();assert approval_path.is_relative_to(R/'.git')
    approval=read(approval_path)
    required=dict(schema='anscore-b30-qualified-repair-approval-v1',approved_by='root',channel=key,
                  controller_sha256=sha(Path(__file__)),repair_plan_sha256=plan_digest,max_invocations=1,
                  hard_seconds_per_tree=20,first_failure_stop=True,automatic_retry=False,preparation_reexecution=False,model_calls=0)
    assert all(approval.get(k)==v for k,v in required.items())
    reviews_guard(approval['independent_reviews']);reviews_guard(plan['independent_source_reviews'])
    return key,cfg,p,plan,approval,carried

def run(plan_path,plan_digest,approval_path):
    assert os.name=='nt'
    key,cfg,p,plan,approval,carried=approved_context(plan_path,plan_digest,approval_path)
    approved=sha(approval_path);controller=sha(Path(__file__));attempt=local(p,cfg['attempt'])
    assert not attempt.exists();attempt.mkdir(parents=True,exist_ok=False)
    sources=plan['copy_files_sha256'];copies=attempt/'tested_source';artifacts=attempt/'artifacts'
    receipt=dict(schema='anscore-b30-qualified-repair-receipt-v1',status='STARTED_ONCE',channel=key,
                 repair_plan_sha256=plan_digest,approval_sha256=approved,controller_sha256=controller,
                 parent_author_sha256=cfg['author'],parent_source_seal_sha256=cfg['seal'],
                 parent_failed_receipt_sha256=plan['parent_failed_receipt_sha256'],carried_records=carried,
                 records=[dict(name=c['name'],kind=c['kind'],status='NOT_RUN') for c in plan['children']],
                 copied_files_sha256=sources,generated_artifacts_sha256={},results=[],model_calls=0,
                 preparation_reexecution=False,hard_seconds_per_tree=20,automatic_retry=False,hardware='HW_UNVERIFIED')
    current=None;phase='initial_receipt';runtime=None;tools=None
    retained={'controller.py':controller,'repair_plan.json':plan_digest,'approval.json':approved}
    lock=dict(status='STARTED_ONCE',repair_plan_sha256=plan_digest,approval_sha256=approved)
    def save():write(attempt/'receipt.json',receipt)
    def boundary():
        assert sha(Path(__file__))==controller and sha(plan_path)==plan_digest and sha(approval_path)==approved
        reviews_guard(approval['independent_reviews']);reviews_guard(plan['independent_source_reviews'])
        for name,digest in retained.items():assert sha(attempt/name)==digest,'retained execution metadata changed'
        assert read(attempt/'LOCK.json')==lock and sha(attempt/'LOCK.json')==receipt['lock_sha256']
        raw_files={}
        for record in receipt['records']:
            for suffix in ('stdout','stderr'):
                if suffix in record:
                    raw_files[local(p,record[suffix]).relative_to(attempt/'raw').as_posix()]=record[suffix+'_sha256']
        exact(attempt/'raw',raw_files)
        assert inventory(p,exclude=cfg['attempt'])==plan['baseline_package_files_sha256'],'historical/original package bytes changed'
        for entry in plan['overlays'].values():assert sha(local(R,entry['path']))==entry['sha256']
        carried_guard(key,p,plan);exact(copies,sources)
        assert inventory(artifacts)==receipt['generated_artifacts_sha256'],'artifact path/bytes changed'
        runtime.verify(tools)
    try:
        save();write(attempt/'LOCK.json',lock,True);receipt['lock_sha256']=sha(attempt/'LOCK.json')
        for filename,source in [('controller.py',Path(__file__)),('repair_plan.json',plan_path),('approval.json',approval_path)]:
            with (attempt/filename).open('xb') as stream:stream.write(source.read_bytes())
        copies.mkdir()
        for name,digest in sources.items():
            source=local(R,plan['overlays'][name]['path']) if name in plan['overlays'] else local(p,name)
            assert sha(source)==digest
            destination=local(copies,name);destination.parent.mkdir(parents=True,exist_ok=True)
            with destination.open('xb') as stream:stream.write(source.read_bytes())
        exact(copies,sources);artifacts.mkdir();(attempt/'raw').mkdir();(attempt/'tmp').mkdir()
        for name,entry in plan['carried_artifacts'].items():
            path=local(artifacts,name);original=local(p,entry['path']);assert sha(original)==entry['sha256']
            with path.open('xb') as stream:stream.write(original.read_bytes())
            assert sha(path)==entry['sha256'];receipt['generated_artifacts_sha256'][name]=entry['sha256']
        receipt['carried_artifacts']=plan['carried_artifacts']
        tools=read(copies/'TOOL_INVENTORY.json');assert sha(copies/'TOOL_INVENTORY.json')==TOOL_SHA
        if key=='b':
            runtime=load(copies,'sim/runtime');supervisor=load(copies,'sim/process_tree');parser=load(copies,'sim/raw_parser')
            system=Path(os.environ['SystemRoot']).resolve(strict=True)
            env=dict(SystemRoot=str(system),WINDIR=str(system),PATH=os.pathsep.join(tools['path_prefix']),
                     TEMP=str((attempt/'tmp').resolve()),TMP=str((attempt/'tmp').resolve()),
                     PYTHONDONTWRITEBYTECODE='1',PYTHONNOUSERSITE='1',PYTHONPATH='',PYTHONIOENCODING='utf-8',LANG='C',LC_ALL='C')
        else:
            runtime=load(copies,'tool_runtime');supervisor=load(copies,'tree_process');parser=load(copies,'audit_raw')
            env=os.environ.copy();env['PATH']=os.pathsep.join(tools['path_prefix'])
            env['PYTHONDONTWRITEBYTECODE']='1';env['PYTHONIOENCODING']='utf-8'
            env.pop('PYTHONPATH',None);env.pop('PYTHONHOME',None)
            data=read(copies/'preparation/generated/DATA.json')
        receipt['environment_sha256']=hashlib.sha256(json.dumps(env,sort_keys=True).encode()).hexdigest()
        if key=='b':receipt['fixed_environment']=env
        expansion={name:value['path'] for name,value in tools['tools'].items()};expansion['ARTIFACTS']=str(artifacts)
        for i,child in enumerate(plan['children']):
            current=None;phase='pre_boundary:'+child['name'];boundary()
            if key=='b':argv=[tools['tools'][child['tool']]['path']]+[a.replace('{ARTIFACT}',str(artifacts)) for a in child['args']]
            else:argv=[a.format(**expansion) for a in child['argv']]
            if child['kind']=='compile':
                filename=(child['profile'] if key=='b' else 'p'+str(child['profile']))+'.vvp'
                assert not (artifacts/filename).exists()
            if child['kind']=='simulation':
                filename=(child['profile'] if key=='b' else 'p'+str(child['profile']))+'.vvp'
                assert filename in receipt['generated_artifacts_sha256']
            current=dict(name=child['name'],kind=child['kind'],status='RUNNING',argv=argv,cwd=str(copies))
            receipt['records'][i]=current;phase='child:'+child['name'];save()
            if key=='b':
                result=supervisor.execute(argv,copies,env,20);stdout,stderr=result.pop('stdout'),result.pop('stderr');current.update(result)
            else:
                result,stdout,stderr=supervisor.run_child(dict(argv=argv,cwd=str(copies)),env);current.update(result)
            # Persist every byte before checking exit, warning or supplied tuples.
            for suffix,raw in [('stdout',stdout),('stderr',stderr)]:
                path=attempt/'raw'/(child['name']+'.'+suffix+'.raw')
                with path.open('xb') as stream:stream.write(raw)
                current[suffix]=path.relative_to(p).as_posix();current[suffix+'_sha256']=sha(path);current[suffix+'_bytes']=len(raw)
            current['observed_artifacts_sha256']=inventory(artifacts);save()
            assert not current['timed_out'] and 0<=current['elapsed_seconds']<20
            if key=='b':
                assert current['failure'] is None and current['process_tree_cleanup']['windows_kill_on_close_job_closed'] is True
                code=current['returncode']
            else:
                assert current['launch_error'] is None and current['supervision']['contained_before_resume'] is True
                assert current['supervision']['job_closed'] is True;code=current['exit_code']
            if child['kind']=='reject':
                assert code is not None and (code!=0 if key=='b' else 0<code<128)
                assert child['marker'].encode('ascii') in stdout+stderr
                if key=='root':assert b'exact_undirected_steiner_tree_invalid_' in stdout+stderr
                current['status']='EXPECTED_REJECT'
            else:
                assert code==0 and stderr==b'','process error or unexpected diagnostic'
                if child['kind'] in ('lint','compile'):assert stdout==b''
                else:
                    assert child['kind']=='simulation'
                    if key=='b':
                        result=parser.validate(stdout,child,copies);assert result==child['expected_tuples']
                    else:
                        job=next(j for j in data['jobs'] if j['name']==child['name'])
                        result=parser.audit(parser.normalized_output(stdout),data,job)
                    receipt['results'].append(result)
                if child['kind']=='compile':
                    path=artifacts/filename;assert path.is_file() and path.stat().st_size>0
                    modules={str(Path(n).resolve()).casefold() for n in re.findall(r'^:vpi_module "([^"]+)";',path.read_text('utf-8'),re.MULTILINE)}
                    assert modules=={str(Path(n).resolve()).casefold() for n in tools['runtime_modules_sha256']}
                    receipt['generated_artifacts_sha256'][filename]=sha(path)
                current['status']='PASS'
            phase='post_boundary:'+child['name'];boundary();save()
        current=None;phase='final_boundary';boundary()
        assert len(receipt['results'])==cfg['simulations'] and len(receipt['generated_artifacts_sha256'])==5
        if key=='b':
            totals={k:sum(x[k] for x in receipt['results']) for k in receipt['results'][0]}
            assert all(totals[k]==v for k,v in dict(IN=1212,OUT=659,HOLD=90,OFFER=12,PROBE=8,RESET=24).items())
            receipt['actual_tuples']=totals
        receipt.update(status='PASS_FIXED_QUALIFICATION_WITH_REVIEWED_REPAIR',actual_children=cfg['children'],
                       effective_records=cfg['children']+cfg['carry'],max_child_seconds=max(c['elapsed_seconds'] for c in receipt['records']),
                       successful_artifacts_retained_for_independent_review=True)
        save();print('PASS REPAIRED_FIXED_QUALIFICATION '+key);return 0
    except Exception as error:
        if current is not None:current['status']='FAIL'
        receipt.update(status='FAILED_STOPPED_NO_AUTOMATIC_RETRY',failure=dict(type=type(error).__name__,message=str(error),phase=phase),
                       observed_artifacts_sha256=inventory(artifacts),not_run=[r['name'] for r in receipt['records'] if r['status']=='NOT_RUN'])
        save();files=inventory(attempt)
        write(attempt/'FAILURE_ARCHIVE.json',dict(status='PERMANENT_PRESERVED_IN_PLACE',files_sha256=files,automatic_retry=False),True)
        print('FAILED_STOPPED REPAIRED_FIXED_QUALIFICATION '+key);return 1

if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--plan',type=Path,required=True)
    parser.add_argument('--approved-plan',required=True);parser.add_argument('--approval',type=Path,required=True)
    args=parser.parse_args();raise SystemExit(run(args.plan.resolve(),args.approved_plan,args.approval.resolve()))
