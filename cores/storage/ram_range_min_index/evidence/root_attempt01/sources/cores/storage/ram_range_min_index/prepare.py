"""Future once-only preparation from approved frozen sources; no import-time work."""
from __future__ import annotations
import argparse,hashlib,importlib.util,json,sys
from pathlib import Path
ROOT=Path(__file__).resolve().parent
PACKAGE='cores/storage/ram_range_min_index'
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    if sys.flags.optimize:raise RuntimeError('optimized Python forbidden')
    parser=argparse.ArgumentParser();parser.add_argument('--approved-author',required=True)
    parser.add_argument('--approved-author-seal',required=True)
    parser.add_argument('--approved-preparation-plan',required=True)
    parser.add_argument('--original-package-root',type=Path,required=True)
    parser.add_argument('--tested-repository-root',type=Path,required=True)
    parser.add_argument('--tested-package-root',type=Path,required=True)
    parser.add_argument('--output-directory',type=Path,required=True)
    parser.add_argument('--root-approval',type=Path,required=True)
    parser.add_argument('--approved-approval',required=True)
    args=parser.parse_args()
    original=args.original_package_root.resolve(strict=True);original_repo=original.parents[2]
    repository=args.tested_repository_root.resolve(strict=True)
    package=args.tested_package_root.resolve(strict=True);output=args.output_directory.resolve()
    approval=args.root_approval.resolve(strict=True)
    assert original==original_repo/PACKAGE
    assert repository==(original/'preparation_evidence/sources').resolve(strict=True)
    assert package==ROOT==repository/PACKAGE and Path.cwd().resolve()==ROOT
    assert Path(__file__).resolve()==ROOT/'prepare.py'
    assert output==original/'prepared' and not output.is_relative_to(repository)
    assert not approval.is_relative_to(original) and not approval.is_relative_to(repository)
    assert sha(ROOT/'AUTHOR_INPUTS.json')==args.approved_author
    assert sha(ROOT/'AUTHOR_SEAL.json')==args.approved_author_seal
    assert sha(ROOT/'PREPARATION_PLAN.json')==args.approved_preparation_plan
    author=json.loads((ROOT/'AUTHOR_INPUTS.json').read_bytes())
    seal=json.loads((ROOT/'AUTHOR_SEAL.json').read_bytes())
    assert seal['author_inputs_sha256']==args.approved_author
    assert seal['sources']==dict(author['sources'],**{'AUTHOR_INPUTS.json':args.approved_author})
    copied={PACKAGE+'/'+n:h for n,h in dict(seal['sources'],**{'AUTHOR_SEAL.json':args.approved_author_seal}).items()}
    copied.update(author['external_sources']);copied[author['baseline_manifest']]=author['baseline_manifest_sha256']
    execution=dict(original_package_root=str(original),tested_repository_root=str(repository),
        tested_package_root=str(ROOT),output_directory=str(output),approval_path=str(approval),
        preparation_cwd=str(ROOT),tested_copies_sha256=copied,
        executed_source_paths={n:str(ROOT/n) for n in ['prepare.py','oracle.py']})
    replacements={'{AUTHOR_SHA256}':args.approved_author,'{AUTHOR_SEAL_SHA256}':args.approved_author_seal,
        '{PREPARATION_PLAN_SHA256}':args.approved_preparation_plan,'{ORIGINAL_PACKAGE_ROOT}':str(original),
        '{TESTED_REPOSITORY_ROOT}':str(repository),'{TESTED_PACKAGE_ROOT}':str(ROOT),
        '{OUTPUT_DIRECTORY}':str(output),'{APPROVAL_PATH}':str(approval)}
    plan=json.loads((ROOT/'PREPARATION_PLAN.json').read_bytes())
    assert plan['working_directory']=='{TESTED_PACKAGE_ROOT}' and plan['output_directory']=='{OUTPUT_DIRECTORY}'
    argv=plan['argv']
    for token,value in replacements.items():argv=[x.replace(token,value) for x in argv]
    assert all('{' not in x or x=='{APPROVAL_SHA256}' for x in argv)
    execution['preparation_argv_template']=argv
    argv=[x.replace('{APPROVAL_SHA256}',args.approved_approval) for x in argv]
    assert sys.orig_argv==argv and sys.flags.dont_write_bytecode
    tools=json.loads((ROOT/'TOOLCHAIN.json').read_bytes())
    assert argv[0]==tools['tools']['PYTHON']['path'] and argv[2]==str(ROOT/'prepare.py')
    assert Path(sys.executable).resolve()==Path(argv[0]).resolve()
    assert sha(Path(argv[0]))==tools['tools']['PYTHON']['sha256']
    assert sha(approval)==args.approved_approval
    gate=json.loads(approval.read_bytes())
    assert gate['schema']=='b30-a-prepare-once-v1' and gate['approved_by']=='root'
    required=dict(author_sha256=args.approved_author,author_seal_sha256=args.approved_author_seal,
        preparation_plan_sha256=args.approved_preparation_plan,max_invocations=1,hard_seconds=20,
        automatic_retry=False,execution_context=execution)
    assert all(gate.get(k)==v for k,v in required.items())
    executed={n:author['sources'][n] for n in ['prepare.py','oracle.py']}
    def context_guard():
        assert Path.cwd().resolve()==ROOT and sys.orig_argv==argv
        assert sha(approval)==args.approved_approval
        for base in [ROOT,original]:
            assert sha(base/'AUTHOR_INPUTS.json')==args.approved_author
            assert sha(base/'AUTHOR_SEAL.json')==args.approved_author_seal
            assert sha(base/'PREPARATION_PLAN.json')==args.approved_preparation_plan
            for n,h in author['sources'].items():assert sha(base/n)==h,n
        for base in [repository,original_repo]:
            for n,h in author['external_sources'].items():assert sha(base/n)==h,n
            assert sha(base/author['baseline_manifest'])==author['baseline_manifest_sha256']
        actual={p.relative_to(repository).as_posix():sha(p) for p in repository.rglob('*') if p.is_file()}
        assert actual==copied,'exact tested execution source tree changed'
    context_guard()
    output.mkdir(exist_ok=False)
    identity=dict(author_sha256=args.approved_author,author_seal_sha256=args.approved_author_seal,
        preparation_plan_sha256=args.approved_preparation_plan,approval_path=str(approval),
        approval_sha256=args.approved_approval,execution_context=execution,argv=argv,
        working_directory=str(ROOT),executed_sources_sha256=executed)
    with (output/'LOCK.json').open('x',encoding='utf-8',newline='\n') as f:
        json.dump(dict(status='STARTED_ONCE',**identity),f);f.write('\n')
    sys.dont_write_bytecode=True
    spec=importlib.util.spec_from_file_location('b30_a_approved_frozen_oracle',ROOT/'oracle.py')
    assert spec and spec.loader and spec.name not in sys.modules
    oracle=importlib.util.module_from_spec(spec);spec.loader.exec_module(oracle)
    assert Path(oracle.__file__).resolve()==ROOT/'oracle.py' and sha(ROOT/'oracle.py')==executed['oracle.py']
    raw=json.loads((ROOT/'RAW_INPUTS.json').read_bytes());inventory={};counts={}
    def save(profile,name,commands):
        answers=oracle.evaluate(commands,profile['buckets'])
        folder=output/'fixtures'/profile['name'];folder.mkdir(parents=True,exist_ok=True)
        obj=folder/(name+'.json');txt=folder/(name+'.txt')
        with obj.open('x',encoding='utf-8',newline='\n') as f:json.dump(answers,f,indent=2);f.write('\n')
        with txt.open('x',encoding='utf-8',newline='\n') as f:
            f.write(str(len(answers))+'\n')
            for row in answers:f.write(' '.join(map(str,row['command']+row['response']))+'\n')
        for path in [obj,txt]:inventory[path.relative_to(original).as_posix()]=sha(path)
        return len(answers)
    for profile in raw['profiles']:
        pc=dict(main=save(profile,'main',profile['commands']),resets={})
        for job in profile['reset_jobs']:
            label=job['name']
            control=output/'fixtures'/profile['name']/('cancel_'+label+'.txt')
            control.parent.mkdir(parents=True,exist_ok=True)
            with control.open('x',encoding='utf-8',newline='\n') as f:f.write(' '.join(map(str,job['cancel_command']))+'\n')
            inventory[control.relative_to(original).as_posix()]=sha(control)
            pc['resets'][label]=dict(preload=save(profile,'pre_'+label,job['preload']),
                                    fresh=save(profile,'fresh_'+label,job['fresh']))
        counts[profile['name']]=pc
    context_guard()
    assert Path(oracle.__file__).resolve()==ROOT/'oracle.py' and sha(ROOT/'oracle.py')==executed['oracle.py']
    receipt=dict(status='PREPARED_FIXED_FINITE',**identity,files_sha256=inventory,counts=counts,
        preparation_invocations=1,oracle_passes='one evaluation per frozen named main/preload/fresh program',
        input_expansion=False,automatic_retry=False,hardware='HW_UNVERIFIED')
    with (output/'receipt.json').open('x',encoding='utf-8',newline='\n') as f:json.dump(receipt,f,indent=2);f.write('\n')
    context_guard()
    print('PASS PREPARATION FIXED_PROGRAMS',flush=True)
if __name__=='__main__':main()
