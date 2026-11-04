#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Finite exact eigenvalue checks via integer inertia predicates, without sqrt."""
from datetime import datetime,timezone
from pathlib import Path
import hashlib,itertools,json,os,random,re,shutil,subprocess,tempfile

ROOT=Path(__file__).resolve().parent
DEPENDENCY=ROOT.parent/'dsp_isp_library/infra/fixedpoint/rtl/sqrt_unit.sv'
BASELINE='cf23435dbaca0dc895e2c0b5470418fb9e56c046'


def oracle(a,b,d,w,frac,result_w):
    scale=1<<frac
    # Binary-search the last integer z for which the eigenvalue is >= z/scale.
    # Lower endpoint: M-zI is PSD iff both diagonals and determinant are >=0.
    # Upper endpoint: M-zI is negative definite iff first diagonal <0 and det>0.
    def predicate(z,upper):
        aa=a*scale-z;dd=d*scale-z;det=aa*dd-(b*scale)**2
        return not (aa<0 and det>0) if upper else aa>=0 and dd>=0 and det>=0
    def search(upper):
        low=-(1<<w)*scale;high=(1<<w)*scale+1
        assert predicate(low,upper) and not predicate(high,upper)
        while high-low>1:
            middle=(low+high)//2
            if predicate(middle,upper):low=middle
            else:high=middle
        assert predicate(low,upper) and not predicate(low+1,upper)
        return low
    minimum=search(False);maximum=search(True)
    assert minimum<=maximum
    low,high=-(1<<(result_w-1)),(1<<(result_w-1))-1
    clipped_min=int(not low<=minimum<=high);clipped_max=int(not low<=maximum<=high)
    trace=a+d;det=a*d-b*b
    # This discriminant identity differs from the RTL's difference-square sum.
    discriminant=trace*trace-4*det
    psd=int(a>=0 and d>=0 and det>=0)
    assert psd==int(minimum>=0)
    return (max(low,min(high,minimum)),max(low,min(high,maximum)),
            clipped_min|(clipped_max<<1),psd,int(a==d and b==0),trace,discriminant)


def vectors(w,f,r,t):
    low=-(1<<(w-1));high=(1<<(w-1))-1
    rng=random.Random(20261104+w*103+f*17+r)
    values=[(0,0,0),(high,0,high),(low,0,low),(low,0,high),
            (high,high,high),(low,low,low),(high,low,low),(low,high,high),
            (1,1,-1),(0,1,0),(-1,-1,1),(1,0,-1),
            # det=-1 yields a tiny negative eigenvalue at large positive trace.
            (high,high-1,high-2),(high-2,1-high,high),
            (1,high,1),(-1,high,-1)]
    for a in [low,low+1,-1,0,1,high-1,high]:values.append((a,0,a))
    if w<=3:
        values.extend(itertools.product(range(low,high+1),repeat=3))
    else:
        for _ in range(40):
            a,b,d=(rng.randrange(low,high+1) for _ in range(3))
            values.extend([(a,b,d),(d,b,a),(a,-b if b!=low else b,d)])
        k=max(1,int(high**0.5)-1)
        values.extend([(k*k+1,k,1),(1,k,k*k+1)])  # det=+1, tiny positive eigenvalue
    calls=[];stats={'w':w,'frac':f,'result_w':r,'tag_w':t,'commands':len(values),
                    'exhaustive_matrices':(1<<(3*w)) if w<=3 else 0,
                    'clipped_commands':0,'psd_commands':0,'repeated_commands':0,'reset_phase_cancellations':9}
    def lit(x,width):return f"{width}'h{x&((1<<width)-1):x}"
    for index,(a,b,d) in enumerate(values):
        minimum,maximum,sat,psd,repeated,trace,disc=oracle(a,b,d,w,f,r)
        tag=(index*13+3)&((1<<t)-1)
        calls.append(f'put({lit(a,w)},{lit(b,w)},{lit(d,w)},{lit(tag,t)},{index%3});')
        calls.append(f'get_result({lit(minimum,r)},{lit(maximum,r)},2\'h{sat:x},{psd},{repeated},{lit(trace,w+1)},{lit(disc,2*w+1)},{lit(tag,t)},{index%5});')
        stats['clipped_commands']+=bool(sat);stats['psd_commands']+=psd;stats['repeated_commands']+=repeated
    calls.append(f'if(commands!={len(values)} || clipped!={stats["clipped_commands"]} || psd_count!={stats["psd_commands"]} || repeated_count!={stats["repeated_commands"]} || reset_probes!=10) $fatal(1,"coverage mismatch");')
    return '\n'.join(calls)+'\n',stats


def main():
    (ROOT/'verification.json').unlink(missing_ok=True)
    files=sorted(p for p in ROOT.rglob('*') if p.is_file())
    for path in files+[DEPENDENCY]:
        if b'\r' in path.read_bytes():raise RuntimeError('LF source required: '+str(path))
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=str(suite/'bin')+os.pathsep+str(suite/'lib')+os.pathsep+env['PATH']
    iv=str(suite/'bin/iverilog.exe') if (suite/'bin/iverilog.exe').is_file() else shutil.which('iverilog')
    vv=str(suite/'bin/vvp.exe') if (suite/'bin/vvp.exe').is_file() else shutil.which('vvp')
    if not iv or not vv:raise SystemExit('NOT_RUN: requires Icarus Verilog/vvp')
    records=[];profiles=[]
    def run(command,cwd,negative=False):
        cmd=[str(x) for x in command]
        p=subprocess.run(cmd,cwd=cwd,env=env,capture_output=True,text=True,timeout=15)
        records.append({'command':cmd,'returncode':p.returncode,'stdout':p.stdout.strip(),'stderr':p.stderr.strip()})
        if negative:
            if not p.returncode or 'symmetric_eigen2x2_invalid_parameter__see_README' not in p.stderr:raise RuntimeError(p.stdout+p.stderr)
        else:
            known_header='warning: Some design elements have no explicit time unit and/or\n       : time precision. This may cause confusing timing results.\n       : Affected design elements are:\n'
            diagnostic=p.stderr.strip()
            known_timescale=diagnostic.startswith(known_header) and all(
                re.fullmatch(r'       :   -- module fp_sqrt_(iter|pipe) declared here: .*sqrt_unit\.sv:[0-9]+',line)
                for line in diagnostic[len(known_header):].splitlines())
            if p.returncode or (diagnostic and not known_timescale):raise RuntimeError(p.stdout+p.stderr)
        if p.stdout.strip():print(p.stdout.splitlines()[0] if '-V' in cmd else p.stdout.strip(),flush=True)
        return p
    with tempfile.TemporaryDirectory(prefix='anscore_eigen2x2_') as temp:
        tmp=Path(temp);version=run([iv,'-V'],tmp).stdout.splitlines()[0]
        run([iv,'-g2012','-Wall','-tnull','-s','symmetric_eigen2x2','-f','files.f'],ROOT)
        run([iv,'-g2012','-Wall','-tnull','-s','eigen16_example','-f','example/files.f'],ROOT)
        for w,f,r,t in [(2,0,5,1),(3,4,12,3),(8,8,16,8),(16,12,32,8),(24,24,64,32),(24,0,2,1),(8,24,32,8)]:
            text,profile=vectors(w,f,r,t);(tmp/'vectors.svh').write_bytes(text.encode());exe=tmp/'unit.vvp'
            top='tb_symmetric_eigen2x2'
            run([iv,'-g2012','-Wall','-I',tmp,'-s',top,'-o',exe]+[f'-P{top}.{k}={v}' for k,v in zip('WFRT',(w,f,r,t))]+
                [DEPENDENCY,ROOT/'rtl/symmetric_eigen2x2.sv',ROOT/'sim/tb_symmetric_eigen2x2.sv'],tmp)
            p=run([vv,exe],tmp)
            if 'PASS eigen' not in p.stdout:raise RuntimeError('completion marker missing')
            profile['result']=p.stdout.strip();profiles.append(profile)
        invalid=[('W',1),('W',25),('FRAC',-1),('FRAC',25),('RESULT_W',1),('RESULT_W',65),('TAG_W',0),('TAG_W',33)]
        for key,value in invalid:
            run([iv,'-g2012','-tnull','-s','symmetric_eigen2x2',f'-Psymmetric_eigen2x2.{key}={value}',DEPENDENCY,ROOT/'rtl/symmetric_eigen2x2.sv'],tmp,True)
    report={'status':['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],'baseline':BASELINE,
            'checked_at_utc':datetime.now(timezone.utc).isoformat(),'tool_version':version,'profiles':profiles,
            'per_process_timeout_seconds':15,'commands':records,'invalid_parameter_rejections':len(invalid),
            'scope':'finite exact integer-inertia bisection oracle, protocol/latency/reset checks and example compilation',
            'source_sha256':{str(p.relative_to(ROOT)).replace('\\','/'):hashlib.sha256(p.read_bytes()).hexdigest() for p in files},
            'dependency_sha256':{'../dsp_isp_library/infra/fixedpoint/rtl/sqrt_unit.sv':hashlib.sha256(DEPENDENCY.read_bytes()).hexdigest()},
            'reproduce':'python -B cores/signal_processing/symmetric_eigen2x2/run_tests.py',
            'not_run':['synthesis','PnR','STA','hardware','expanded regression']}
    (ROOT/'verification.json').write_bytes((json.dumps(report,indent=2)+'\n').encode())


if __name__=='__main__':main()
