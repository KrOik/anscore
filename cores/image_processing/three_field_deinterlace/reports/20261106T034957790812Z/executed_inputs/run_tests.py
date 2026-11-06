"""Original Apache-2.0 finite checks. No synthesis, network, retries or cleanup of successful VVPs."""
from pathlib import Path
import datetime,hashlib,json,os,random,signal,subprocess,sys,time,traceback

ROOT=Path(__file__).resolve().parent
BIN=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite/bin'
IV=BIN/'iverilog.exe';VVP=BIN/'vvp.exe'
SOURCES=['run_tests.py','rtl/three_field_deinterlace.sv','sim/tb_three_field.sv',
         'files.f','example/deinterlace_rgb_preview.sv','example/files.f']
PROFILES=[dict(name='1x2_b8',w=1,h=2,b=8,protocol=1,example=0),
          dict(name='9x6_b10',w=9,h=6,b=10,protocol=1,example=0),
          dict(name='7x4_b12',w=7,h=4,b=12,protocol=1,example=0),
          dict(name='128x64_b8',w=128,h=64,b=8,protocol=0,example=0),
          dict(name='rgb_preview_9x6',w=9,h=6,b=8,protocol=0,example=1)]

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def execute(name,argv,cwd,env,report,marker=None):
    argv=list(map(str,argv));start=time.monotonic();code=None;out=err=b'';cleanup=[];reason=None
    options={'creationflags':subprocess.CREATE_NO_WINDOW} if os.name=='nt' else {'start_new_session':True}
    try:child=subprocess.Popen(argv,cwd=cwd,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**options)
    except OSError as exc:status='NOT_RUN';err=(repr(exc)+'\n').encode()
    else:
        try:
            out,err=child.communicate(timeout=20);code=child.returncode;status='PASS' if code==0 else 'FAIL'
        except subprocess.TimeoutExpired as exc:
            status='TIMEOUT';out=exc.stdout or b'';err=exc.stderr or b''
            if os.name=='nt':
                kill=[str(Path(os.environ.get('SystemRoot',r'C:\Windows'))/'System32/taskkill.exe'),'/PID',str(child.pid),'/T','/F']
                try:
                    result=subprocess.run(kill,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=5,check=False,creationflags=subprocess.CREATE_NO_WINDOW)
                    cleanup.append(dict(argv=kill,returncode=result.returncode,stdout=result.stdout.decode(errors='replace'),stderr=result.stderr.decode(errors='replace')))
                except (OSError,subprocess.TimeoutExpired) as exc:cleanup.append(dict(action='tree_kill',error=repr(exc)))
            else:
                try:os.killpg(child.pid,signal.SIGKILL)
                except OSError as exc:cleanup.append(dict(action='group_kill',error=repr(exc)))
            try:
                if child.poll() is None:child.kill()
            except OSError as exc:cleanup.append(dict(action='parent_kill',error=repr(exc)))
            try:out,err=child.communicate(timeout=2)
            except subprocess.TimeoutExpired as exc:
                out=exc.stdout or out;err=exc.stderr or err;cleanup.append(dict(action='drain',error=repr(exc)))
            except OSError as exc:cleanup.append(dict(action='drain',error=repr(exc)))
            code=child.poll()
    if status=='PASS' and name.startswith('sim_') and (marker is None or not any(line.startswith(marker) for line in out.splitlines())):
        status='FAIL';reason='required exact simulation completion prefix absent'
    (report/(name+'.stdout.txt')).write_bytes(out);(report/(name+'.stderr.txt')).write_bytes(err)
    return dict(name=name,argv=argv,cwd=str(cwd),status=status,returncode=code,reason=reason,
                marker=marker.decode() if marker else None,execution_deadline_seconds=20,cleanup_budget_seconds=7,
                cleanup=cleanup,seconds=round(time.monotonic()-start,3),stdout_sha256=hashlib.sha256(out).hexdigest(),stderr_sha256=hashlib.sha256(err).hexdigest())

def fixtures(w,h,b,example=False):
    top=(1<<b)-1;size=w*h;rng=random.Random(360036+w*1009+h*17+b)
    ramp=[(x*31+y*53+(x*y*7))&top for y in range(h) for x in range(w)]
    zero=[0]*size;full=[top]*size
    random_frames=lambda: [[rng.randrange(top+1) for _ in range(size)] for _ in range(3)]
    def diagonal(slope):return [top if x+slope*y>=w//2 else 0 for y in range(h) for x in range(w)]
    cases=[]
    for parity in [0,1]:
        cases.extend([
            (parity,0,1,ramp,ramp,ramp,'static_detail'),
            (parity,0,0,full,full,full,'fullscale_mean'),
            (parity,top,1,zero,ramp,full,'threshold_fullscale_equality'),
            (parity,0,1,zero,zero,full,'all_direction_tie'),
            *[(parity,0,1,zero,diagonal(slope),full,f'diagonal_{slope}') for slope in [-2,-1,1,2]],
            (parity,0,1,*random_frames(),'random_motion'),
            (parity,1,0,zero,ramp,[1]*size,'threshold_one_equality'),
            (parity,0,1,zero,ramp,[1]*size,'threshold_one_spatial'),
            (parity,0,1,zero,[top*((y//2)%2) for y in range(h) for x in range(w)],full,'maximum_score'),
            (parity,top,0,*random_frames(),'random_temporal')])
    if w==128 and h==64:cases=[cases[0],cases[21],cases[4]]
    if example:cases=[cases[i] for i in [0,4,5,6,7,8,9,11,12,21]]
    return cases

def model(w,h,b,case):
    # Direct indexing of whole images; no RAM, pipeline, or sliding-window emulation.
    parity,threshold,tint,p,c,n,label=case
    clamp=lambda x:max(0,min(w-1,x))
    at=lambda image,x,y:image[y*w+clamp(x)]
    output=[];sources=[0,0,0];directions={d:0 for d in [-2,-1,0,1,2]}
    equality=odd_means=max_scores=ties=0
    for y in range(h):
        for x in range(w):
            if y%2!=parity:pixel=c[y*w+x];source=0;direction=0
            else:
                upper=y-1 if y>0 else 1
                lower=y+1 if y+1<h else h-2
                motion=max(abs(at(p,x+k,y)-at(n,x+k,y)) for k in [-1,0,1])
                equality+=motion==threshold
                if motion<=threshold:
                    total=p[y*w+x]+n[y*w+x];pixel=(total+1)//2;odd_means+=total%2
                    source=1;direction=0
                else:
                    costs={d:sum(abs(at(c,x+k-d,upper)-at(c,x+k+d,lower)) for k in [-1,0,1]) for d in [-2,-1,0,1,2]}
                    direction=min([0,-1,1,-2,2],key=lambda d:costs[d])
                    ties+=sum(value==costs[direction] for value in costs.values())>1
                    max_scores+=max(costs.values())==3*((1<<b)-1)
                    total=at(c,x-direction,upper)+at(c,x+direction,lower)
                    pixel=(total+1)//2;odd_means+=total%2;source=2;directions[direction]+=1
                assert 0<=pixel<(1<<b)
            sources[source]+=1
            output.append(pixel | (source<<b) | ((direction&7)<<(b+2)))
    captured=[]
    for image,field_parity in [(p,parity),(c,1-parity),(n,parity)]:
        captured.extend(image[y*w+x] for y in range(field_parity,h,2) for x in range(w))
    assert len(captured)==3*w*h//2 and len(output)==w*h
    return captured,output,dict(label=label,first_parity=parity,threshold=threshold,tint=tint,sources=sources,
        directions=directions,threshold_equalities=equality,odd_rounded_means=odd_means,maximum_scores=max_scores,directional_ties=ties)

def write_hex(path,values,bits):
    digits=(bits+3)//4
    path.write_text(''.join(f'{value:0{digits}x}\n' for value in values),encoding='ascii',newline='\n')

def prepare(report):
    profiles=[]
    for profile in PROFILES:
        p=dict(profile);w,h,b=p['w'],p['h'],p['b'];dest=report/p['name'];dest.mkdir()
        cases=fixtures(w,h,b,bool(p['example']));inputs=[];configs=[];golden=[];coverage=[]
        for case in cases:
            captured,result,counts=model(w,h,b,case);inputs.extend(captured);golden.extend(result);coverage.append(counts)
            configs.append(case[1] | (case[0]<<b) | (case[2]<<(b+1)))
        for filename,values,bits in [('inputs.hex',inputs,b),('configs.hex',configs,b+2),('golden.hex',golden,b+5)]:write_hex(dest/filename,values,bits)
        count=len(cases);p.update(cases=count,checked=w*h*(count+(11 if p['protocol'] else 0)),
            completions=count+(15 if p['protocol'] else 0),resets=6 if p['protocol'] else 1,
            errors=5 if p['protocol'] else 0,timing_checks=1,coverage=coverage,
            vectors_sha256={name:sha(dest/name) for name in ['inputs.hex','configs.hex','golden.hex']})
        assert sum(c['threshold_equalities'] for c in coverage)>0
        if w>1:
            assert sum(c['odd_rounded_means'] for c in coverage)>0
            assert sum(c['directional_ties'] for c in coverage)>0
        profiles.append(p)
    # The complete-sized random fixture must exercise every directional winner.
    wide=next(p for p in profiles if p['name']=='128x64_b8')
    assert all(sum(c['directions'][d] for c in wide['coverage'])>0 for d in [-2,-1,0,1,2])
    return profiles

def main():
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    report=ROOT/'reports'/stamp;report.mkdir(parents=True,exist_ok=False)
    build=ROOT/'.build'/stamp;build.mkdir(parents=True,exist_ok=False)
    hashes={source:sha(ROOT/source) for source in SOURCES};copies={}
    for source in SOURCES:
        target=report/'executed_inputs'/source;target.parent.mkdir(parents=True,exist_ok=True)
        target.write_bytes((ROOT/source).read_bytes());copies[source]=str(target.relative_to(report)).replace('\\','/')
    expected=['lint_default','lint_example']+[prefix+p['name'] for p in PROFILES for prefix in ['compile_','sim_']]
    plan=dict(expected_checks=expected,profiles=PROFILES,deadline_seconds=20,automatic_retry=False,
              source_sha256=hashes,preparation_order='archive exact executable inputs; generate/archive all vectors; launch first HDL child')
    (report/'plan.json').write_text(json.dumps(plan,indent=2)+'\n',encoding='utf8',newline='\n')
    plan_sha=sha(report/'plan.json')
    env=os.environ.copy();env['PATH']=str(BIN)+os.pathsep+str(BIN.parent/'lib')+os.pathsep+env.get('PATH','')
    records=[];profiles=[];attempts=0;preparation_complete=False;suite_complete=False;exception=None
    def run(name,argv,cwd=ROOT,marker=None):
        result=execute(name,argv,cwd,env,report,marker);records.append(result);print(name,result['status'],flush=True)
        return result['status']=='PASS'
    try:
        attempts+=1;profiles=prepare(report);preparation_complete=True
        if not run('lint_default',[IV,'-g2012','-Wall','-tnull','-s','three_field_deinterlace','-f','files.f']):return 1
        if not run('lint_example',[IV,'-g2012','-Wall','-tnull','-s','deinterlace_rgb_preview','-f','example/files.f']):return 1
        for p in profiles:
            name=p['name'];image=build/(name+'.vvp')
            parameters=[f"-Ptb_three_field.{key.upper()}={p[key]}" for key in ['w','h','b','cases','protocol','example']]
            files='example/files.f' if p['example'] else 'files.f'
            if not run('compile_'+name,[IV,'-g2012','-Wall','-s','tb_three_field',*parameters,'-o',image,'-f',files,'sim/tb_three_field.sv']):return 1
            marker=(f"PASS DEINTERLACE W={p['w']} H={p['h']} B={p['b']} EXAMPLE={p['example']} cases={p['cases']} "
                    f"checked={p['checked']} completions={p['completions']} resets={p['resets']} errors={p['errors']} timing=1 ").encode()
            if not run('sim_'+name,[VVP,image],report/name,marker):return 1
        suite_complete=True;return 0
    except Exception:
        exception=traceback.format_exc();(report/'exception.txt').write_text(exception,encoding='utf8');return 1
    finally:
        unchanged=all(sha(ROOT/source)==digest for source,digest in hashes.items())
        vectors_unchanged=all(sha(report/p['name']/name)==digest for p in profiles for name,digest in p['vectors_sha256'].items())
        plan_unchanged=sha(report/'plan.json')==plan_sha
        archive_unchanged=all(sha(report/copies[source])==digest for source,digest in hashes.items())
        complete=preparation_complete and suite_complete and [r['name'] for r in records]==expected and all(r['status']=='PASS' for r in records)
        intact=unchanged and vectors_unchanged and plan_unchanged and archive_unchanged
        status='SOURCE_CHANGED' if not intact else 'PASS' if complete else next((r['status'] for r in records if r['status']!='PASS'),'INCOMPLETE')
        result=dict(schema='anscore-b36-three-field-finite-v1',status=status,source_sha256=hashes,exact_checked_copies=copies,
            sources_unchanged=unchanged,archive_unchanged=archive_unchanged,vectors_unchanged=vectors_unchanged,
            plan_unchanged=plan_unchanged,plan_sha256=plan_sha,preparation_attempts=attempts,
            preparation_complete=preparation_complete,suite_complete=suite_complete,expected_checks=expected,
            records=records,profiles=profiles,automatic_retry=False,exception=exception,
            tools={str(path):sha(path) for path in [IV,VVP] if path.is_file()},
            synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',hardware='HW_UNVERIFIED')
        (report/'results.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf8',newline='\n')
        print('REPORT',report,'STATUS',status,flush=True)
        if not intact:raise RuntimeError('Executed inputs, archive, plan or vectors changed during checks')
if __name__=='__main__':sys.exit(main())
