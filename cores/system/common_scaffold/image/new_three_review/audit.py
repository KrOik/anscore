"""Read-only source audit; rerun simulations only in disposable source copies."""
from pathlib import Path
import sys,json,hashlib,tempfile,shutil,subprocess,os,concurrent.futures,datetime
sys.dont_write_bytecode=True
HERE=Path(__file__).resolve().parent;IMAGE=HERE.parent;PACKAGE=IMAGE.parent
sys.path.insert(0,str(PACKAGE));from integration.tooling import tool_env
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
names=['seam_find','poisson_blend','phase_correlation']
snapshot={f'{n}/{p.name}':sha(p) for n in names for p in (IMAGE/n).iterdir() if p.is_file()}
checks=[]
for name,freeze in [('poisson_blend','FINAL_SOURCE_SHA256.json'),('phase_correlation','freeze_hashes.json')]:
    for file,expected in json.loads((IMAGE/name/freeze).read_text()).items():
        actual=sha(IMAGE/name/file);assert actual==expected,(name,file,actual,expected)
        checks.append(dict(file=f'{name}/{file}',sha256=actual,match=True))
for name,rtl,evidence in [('seam_find','seam_find.sv',['manifest.json','evidence.json','error_evidence.json','synthesis.json']),('poisson_blend','poisson_blend_frame.sv',['test_evidence.json','synthesis_evidence.json']),('phase_correlation','phase_correlation_frame.v',['test_result.json','synthesis_result.json'])]:
    actual=sha(IMAGE/name/rtl)
    for f in evidence:
        data=json.loads((IMAGE/name/f).read_text());assert data['rtl_sha256']==actual,(name,f)
        checks.append(dict(file=f'{name}/{f}',rtl_sha256=actual,match=True))
env=tool_env();env['PYTHONDONTWRITEBYTECODE']='1';env['PYTHONPATH']=os.pathsep.join([str(PACKAGE),str(PACKAGE/'integration'),env.get('PYTHONPATH','')])
commands=[('seam_find','test_seam.py'),('seam_find','test_errors.py'),('poisson_blend','run_tests.py'),('phase_correlation','run_tests.py')]
results=[]
with tempfile.TemporaryDirectory(prefix='new_three_readonly_review_') as temporary:
    root=Path(temporary)/'common_ip_scaffold'/'image';root.mkdir(parents=True)
    for name in names:shutil.copytree(IMAGE/name,root/name,ignore=shutil.ignore_patterns('__pycache__'))
    def run(job):
        name,script=job
        p=subprocess.run([sys.executable,'-B',str(root/name/script)],cwd=root/name,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,encoding='utf-8',errors='replace',timeout=600)
        result=dict(name=name,script=script,returncode=p.returncode,output_tail=p.stdout[-4000:])
        print(name,script,'PASS' if p.returncode==0 else 'FAIL',flush=True)
        return result
    with concurrent.futures.ThreadPoolExecutor(max_workers=3) as pool:
        results=list(pool.map(run,commands))
    assert all(r['returncode']==0 for r in results),results
after={f'{n}/{p.name}':sha(p) for n in names for p in (IMAGE/n).iterdir() if p.is_file()}
changed=[f for f in set(snapshot)|set(after) if snapshot.get(f)!=after.get(f)]
# Root may concurrently rerun the common regression and refresh reports.
reports={'seam_find/evidence.json','seam_find/error_evidence.json','poisson_blend/test_evidence.json','phase_correlation/test_result.json'}
unexpected=[f for f in changed if f not in reports]
report=dict(status='PASS' if not unexpected else 'FAIL',utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),freeze_checks=checks,source_snapshot=snapshot,original_code_assets_unchanged=not unexpected,concurrently_refreshed_reports=changed,simulation_copies=results,board_access=False,synthesis_rerun=False)
(HERE/'audit_evidence.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
assert not unexpected,('unexpected source change',unexpected)
print('ALL PASS; original code/assets unchanged')
