"""Reviewed fixed23 continuation after a preserved time-zero TB EOF failure."""
from pathlib import Path
import argparse,hashlib,importlib.util,json,os,re,sys
if sys.flags.optimize: raise RuntimeError('optimized Python forbidden')
sys.dont_write_bytecode=True
P=Path(__file__).resolve().parent;R=P.parents[2]
ATTEMPT='evidence/attempt02'
SEAL='REPAIR_SEAL_ATTEMPT02.json'

def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def read(p): return json.loads(p.read_bytes())
def dump(p,v,exclusive=False):
    with p.open('x' if exclusive else 'w',encoding='utf-8',newline='\n') as f:
        json.dump(v,f,indent=2);f.write('\n')
def fmap(folder):
    return {p.relative_to(folder).as_posix():sha(p) for p in folder.rglob('*') if p.is_file()}
def verify(base,mapping):
    for n,h in mapping.items():
        q=(base/n).resolve();assert q.is_relative_to(base.resolve()) and not q.is_symlink()
        assert sha(q)==h,n
def exact(folder,mapping): assert fmap(folder)==mapping

def run(expected,approval_path):
    assert sha(P/SEAL)==expected
    seal=read(P/SEAL);plan=read(P/'REPAIR_PLAN_ATTEMPT02.json');tools=read(P/'TOOLCHAIN.json')
    assert seal['repair_plan_sha256']==sha(P/'REPAIR_PLAN_ATTEMPT02.json') and seal['children']==plan['children']
    assert seal['children']==read(P/'TEST_PLAN.json')['children'][2:] and len(seal['children'])==23
    assert seal['carried_lint_indices']==[0,1] and seal['superseded_compile_indices']==[2,3,4,5,6]
    approval_path=approval_path.resolve();assert approval_path.is_relative_to((R/'.git').resolve())
    approved=sha(approval_path);approval=read(approval_path)
    assert approval['stage']=='hdl_repair02' and approval['approved_by']=='root'
    assert approval['approved_repair_seal_sha256']==expected and approval['children']==seal['children']
    assert approval['max_invocations']==1 and approval['hard_seconds_per_tree']==20 and approval['automatic_retry'] is False
    assert approval['preparation_reexecution'] is False and approval['independent_reviews']
    static={**seal['current_input_files_sha256'],**seal['parent_evidence_sha256'],SEAL:expected}
    copies={**seal['current_input_files_sha256'],SEAL:expected}
    output=P/ATTEMPT;sources=output/'tested_source';artifacts=output/'artifacts'
    retained={};generated={}
    def context():
        assert sha(P/SEAL)==expected and sha(approval_path)==approved
        actual={n:h for n,h in fmap(P).items() if not n.startswith(ATTEMPT+'/')}
        assert actual==static,'exact original/source/parent evidence inventory changed'
        verify(R,approval['independent_reviews'])
        assert sha(R/'docs/snapshots/source_20261105_b28.json')==seal['baseline_manifest_sha256']
        for tool in tools['tools'].values(): assert sha(Path(tool['path']))==tool['sha256']
        for group in ['runtime_dlls','runtime_modules','ivl_files_sha256']: verify(R,tools[group])
        assert {p.relative_to(R).as_posix():sha(p) for p in (R/tools['ivl_directory']).rglob('*') if p.is_file()}==tools['ivl_files_sha256']
        verify(P,retained)
    def checkpoint(artifact_map):
        context();exact(sources,copies);exact(artifacts,artifact_map)
        assert sha(output/'approval.json')==approved
        wanted={'receipt.json','approval.json'}|{'tested_source/'+n for n in copies}
        wanted|={'artifacts/'+n for n in artifact_map}
        wanted|={str(Path(n).relative_to(ATTEMPT)).replace('\\','/') for n in retained}
        assert set(fmap(output))==wanted,'exact attempt file inventory changed'
    context();assert not output.exists();output.mkdir(parents=True,exist_ok=False)
    records=[dict(c,status='NOT_RUN',launched=False) for c in plan['children']]
    receipt=dict(status='STARTED',repair_seal_sha256=expected,repair_plan_sha256=seal['repair_plan_sha256'],
        original_source_seal_sha256=seal['original_source_seal_sha256'],approval_sha256=approved,
        records=records,results=[],tested_copies_sha256=copies,generated_artifacts_sha256=generated,
        retained_raw_sha256=retained,hard_seconds=20,automatic_retry=False,stop_on_first_failure=True,
        preparation_reexecuted=False,model_reexecuted=False,carried_lint_indices=[0,1],
        superseded_compile_indices=[2,3,4,5,6],hardware='HW_UNVERIFIED')
    current=None;phase='setup';raw={}
    try:
        dump(output/'receipt.json',receipt,True)
        dump(output/'LOCK.json',dict(status='ONE_FIXED23_REPAIR_ATTEMPT',repair_seal_sha256=expected),True)
        retained[(output/'LOCK.json').relative_to(P).as_posix()]=sha(output/'LOCK.json')
        sources.mkdir();artifacts.mkdir();(output/'raw').mkdir()
        for n,h in copies.items():
            target=sources/n;target.parent.mkdir(parents=True,exist_ok=True)
            with target.open('xb') as f: f.write((P/n).read_bytes())
            assert sha(target)==h
        with (output/'approval.json').open('xb') as f:f.write(approval_path.read_bytes())
        modules=[]
        for name in ['tree_process','audit_raw']:
            spec=importlib.util.spec_from_file_location('b29_directed_tour_repair02_'+name,sources/(name+'.py'))
            module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module);modules.append(module)
        tree,audit=modules
        stored=audit.verify_prepared(sources/'preparation/generated',read(sources/'CASE_PLAN.json'))
        env=os.environ.copy();env['PYTHONDONTWRITEBYTECODE']='1';env['PYTHONIOENCODING']='utf-8'
        env['PATH']=os.pathsep.join(str(R/n) for n in tools['path_prefix'])+os.pathsep+env.get('PATH','')
        expansion={k:v['path'] for k,v in tools['tools'].items()};expansion['ARTIFACTS']=str(artifacts)
        for record in records:
            current=None;raw={};phase='pre_checkpoint:'+record['name'];checkpoint(generated)
            current=record;current['argv']=[v.format(**expansion) for v in record['argv']]
            if current['kind']=='compile':assert not (artifacts/(current['profile']+'.vvp')).exists()
            if current['kind']=='simulation':assert set(generated)=={f'p{i}.vvp' for i in range(5)}
            phase='child:'+current['name'];current.update(status='RUNNING',launched=True)
            metadata,out,err=tree.run_child(dict(argv=current['argv'],cwd=str(sources)),env)
            raw={'stdout':out,'stderr':err};current.update(metadata)
            phase='raw_persistence'
            for stream,data in raw.items():
                path=output/'raw'/(current['name']+'.'+stream)
                with path.open('xb') as f:f.write(data)
                n=path.relative_to(P).as_posix();current[stream]=n;current[stream+'_sha256']=sha(path)
                current[stream+'_bytes']=len(data);retained[n]=sha(path)
            candidate=dict(generated)
            if current['kind']=='compile':
                artifact=artifacts/(current['profile']+'.vvp')
                if artifact.is_file():
                    candidate[artifact.name]=sha(artifact)
                    current['produced_artifact']=dict(name=artifact.name,bytes=artifact.stat().st_size,sha256=sha(artifact))
            phase='post_child_checkpoint';checkpoint(candidate)
            phase='validation:'+current['name']
            assert not current['timed_out'] and current['launch_error'] is None and 0<=current['elapsed_seconds']<20
            assert current['supervision'].get('contained_before_resume') and current['supervision'].get('job_closed')
            if current['kind']=='reject':
                assert current['exit_code'] is not None and 0<current['exit_code']<128
                assert b'exact_directed_hamiltonian_cycle_invalid_parameters__see_README' in out+err
                status='EXPECTED_REJECT'
            else:
                assert current['exit_code']==0 and not err
                if current['kind']=='simulation':
                    p=stored['profiles'][current['profile']];frames=p['reset' if current['reset'] else 'main']
                    receipt['results'].append(audit.audit(out,p['profile'],frames,current['mode'],current['reset']))
                else:assert not out
                if current['kind']=='compile':
                    assert current['produced_artifact']['bytes']>0
                    text=artifact.read_text('utf-8')
                    embedded={Path(n).resolve().relative_to(R).as_posix() for n in re.findall(r'^:vpi_module "([^"]+)";',text,re.MULTILINE)}
                    assert embedded==set(tools['runtime_modules'])
                status='PASS'
            generated.clear();generated.update(candidate)
            phase='post_validation_checkpoint';checkpoint(generated);current['status']=status
            dump(output/'receipt.json',receipt)
        current=None;phase='final_checkpoint';checkpoint(generated)
        assert len(receipt['results'])==12 and len(generated)==5
        receipt.update(status='UNIT_SIM_PASS_FIXED23_REPAIR',completed_children=23,
            max_child_seconds=max(v['elapsed_seconds'] for v in records),successful_artifacts_retained_for_independent_review=True)
        dump(output/'receipt.json',receipt);print('PASS FIXED23_REPAIR_HDL');return 0
    except Exception as exc:
        if current is not None and current['launched']:current['status']='TIMEOUT' if current.get('timed_out') else 'FAIL'
        receipt.update(status='FAILED_STOPPED_NO_RETRY',failure=dict(type=type(exc).__name__,message=str(exc),phase=phase))
        for stream,data in raw.items():
            path=output/'raw'/(current['name']+'.'+stream)
            if not path.exists():
                try:
                    with path.open('xb') as f:f.write(data)
                except Exception as e:receipt.setdefault('raw_preservation_errors',{})[stream]=str(e)
        try:
            receipt['observed_artifacts_sha256']=fmap(artifacts)
            receipt['observed_tested_copies_sha256']=fmap(sources)
            receipt['observed_raw_sha256']=fmap(output/'raw')
        except Exception as e:receipt['observation_error']=str(e)
        try:dump(output/'receipt.json',receipt)
        except Exception as e:receipt['terminal_receipt_write_error']=str(e)
        try:
            dump(output/'FAILURE_ARCHIVE.json',dict(status='PERMANENT_PRESERVED_IN_PLACE',files_sha256=fmap(output),terminal_receipt=receipt,automatic_retry=False),True)
        except Exception as e:
            receipt['archive_error']=str(e)
            try:dump(output/'receipt.json',receipt)
            except Exception:pass
        print('FAILED_STOPPED FIXED23_REPAIR');return 1

def main():
    p=argparse.ArgumentParser();p.add_argument('--approved',required=True);p.add_argument('--approval',required=True,type=Path)
    args=p.parse_args();return run(args.approved,args.approval)
if __name__=='__main__':raise SystemExit(main())
