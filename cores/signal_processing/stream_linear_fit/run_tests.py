#!/usr/bin/env python3
"""Bounded exact OLS oracle and unit simulation; no synthesis/physical tools."""
from datetime import datetime,timezone
from fractions import Fraction
from pathlib import Path
import hashlib,itertools,json,os,random,shutil,subprocess,tempfile

ROOT=Path(__file__).resolve().parent
DEPENDENCY=ROOT.parent/'linear_solve2x2/rtl/linear_solve2x2.sv'


def quantize(value,frac,width):
    scaled=value*(1<<frac)
    raw=(-1 if scaled<0 else 1)*(abs(scaled.numerator)//scaled.denominator)
    low,high=-(1<<(width-1)),(1<<(width-1))-1
    return max(low,min(high,raw)),int(not low<=raw<=high)


def oracle(rows,capacity,frac,width):
    pairs=[(x,y) for x,y,keep in rows if keep]
    retained=pairs[:capacity];n=len(retained)
    if n:
        mx=sum(Fraction(x,n) for x,_ in retained)
        my=sum(Fraction(y,n) for _,y in retained)
        centered_x=[Fraction(x)-mx for x,_ in retained]
        spread=n*sum(dx*dx for dx in centered_x)
    else:
        spread=0
    assert Fraction(spread).denominator==1
    if not spread:return (0,0,n,1,int(len(pairs)>capacity),0,int(spread))
    covariance=sum(dx*(y-my) for dx,(_,y) in zip(centered_x,retained))
    slope=covariance/sum(dx*dx for dx in centered_x)
    intercept=my-slope*mx
    # Independently check the least-squares stationarity conditions.
    residuals=[y-slope*x-intercept for x,y in retained]
    assert sum(residuals)==0 and sum(x*r for (x,_),r in zip(retained,residuals))==0
    qs,ss=quantize(slope,frac,width);qi,si=quantize(intercept,frac,width)
    return (qs,qi,n,0,int(len(pairs)>capacity),ss|(si<<1),int(spread))


def vectors(w,c,f,r,t):
    cap=(1<<c)-1;low=-(1<<(w-1));high=(1<<(w-1))-1
    rng=random.Random(20261104+w*101+c*17+f)
    frames=[[(low,high,0)],[(low,low,1)],[(0,low,1),(0,high,1)],
            [(low,low,1),(high,high,1)],[(low,high,1),(high,low,1)],
            [(-1,high,1),(0,high,1),(1,high,1)],
            [(low,low,1),(low+1,high,1)],
            [(high-1,low,1),(high,high,1)],
            [(0,0,0),(-1,0,1),(0,1,1),(1,1,1),(low,high,0)],
            [(high,low,0),(low,high,0),(0,0,0)],
            [(i%2,low if i%2 else high,1) for i in range(cap)],
            [((i*7)%(high-low+1)+low,(i*11)%(high-low+1)+low,1) for i in range(cap+4)]]
    # Every ordered pair of two samples in the smallest nontrivial profile.
    if w==2 and c==2:
        point_values=list(itertools.product(range(low,high+1),repeat=2))
        frames.extend([[(a,b,1),(d,e,1)] for (a,b),(d,e) in itertools.product(point_values,repeat=2)])
    for _ in range(24):
        length=rng.randrange(1,min(cap+5,22)+1)
        frames.append([(rng.randrange(low,high+1),rng.randrange(low,high+1),int(rng.randrange(4)!=0)) for _ in range(length)])
    calls=[];details={'data_w':w,'count_w':c,'frac':f,'result_w':r,'tag_w':t,
                     'frames':len(frames),'beats':0,'retained_pairs':0,'degenerate_frames':0,'overflow_frames':0,'saturated_frames':0}
    a=2*w+c+1;dw=2*a+1
    def lit(value,width):return f"{width}'h{value&((1<<width)-1):x}"
    for index,rows in enumerate(frames):
        expected=oracle(rows,cap,f,r);qs,qi,n,deg,over,sat,spread=expected
        tag=(index*13+7)&((1<<t)-1)
        for i,(x,y,keep) in enumerate(rows):
            beat_tag=tag if not i else (tag+i)&((1<<t)-1)
            gap=0 if i%3 else index%3
            calls.append(f'put({lit(x,w)},{lit(y,w)},{keep},{int(i==len(rows)-1)},{lit(beat_tag,t)},{gap});')
        solver_delay=2*(a+1) if deg else 6*(a+1)+2*(2*a+f+2)
        tail_retained=rows[-1][2] and sum(keep for _,_,keep in rows[:-1])<cap
        delay=solver_delay+(3 if tail_retained else 1)
        calls.append(f'get_result({lit(qs,r)},{lit(qi,r)},{lit(n,c)},{deg},{over},2\'h{sat:x},{lit(spread,dw)},{lit(tag,t)},{delay},{index%5});')
        details['beats']+=len(rows);details['retained_pairs']+=n
        details['degenerate_frames']+=deg;details['overflow_frames']+=over;details['saturated_frames']+=bool(sat)
    calls.append(f'if(frames!={len(frames)} || degenerate_frames!={details["degenerate_frames"]} || overflow_frames!={details["overflow_frames"]} || saturated_frames!={details["saturated_frames"]}) $fatal(1,"coverage mismatch");')
    return '\n'.join(calls)+'\n',details


def main():
    (ROOT/'verification.json').unlink(missing_ok=True)
    for path in [p for p in ROOT.rglob('*') if p.is_file()]+[DEPENDENCY]:
        if b'\r' in path.read_bytes():raise RuntimeError('LF source required: '+str(path))
    suite=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite';env=os.environ.copy()
    env['PATH']=str(suite/'bin')+os.pathsep+str(suite/'lib')+os.pathsep+env['PATH']
    iv=str(suite/'bin/iverilog.exe') if (suite/'bin/iverilog.exe').is_file() else shutil.which('iverilog')
    vv=str(suite/'bin/vvp.exe') if (suite/'bin/vvp.exe').is_file() else shutil.which('vvp')
    if not iv or not vv:raise SystemExit('NOT_RUN: requires Icarus Verilog/vvp')
    records=[];profiles=[]
    def run(command,cwd,negative=False):
        cmd=[str(x) for x in command]
        result=subprocess.run(cmd,cwd=cwd,env=env,capture_output=True,text=True,timeout=15)
        records.append({'command':cmd,'returncode':result.returncode,'stdout':result.stdout.strip(),'stderr':result.stderr.strip()})
        if negative:
            if result.returncode==0 or 'invalid_parameter__see_README' not in result.stderr:raise RuntimeError(result.stdout+result.stderr)
        elif result.returncode or (result.stderr.strip() and '-V' not in cmd):raise RuntimeError(result.stdout+result.stderr)
        if result.stdout.strip():print(result.stdout.splitlines()[0] if '-V' in cmd else result.stdout.strip())
        return result
    with tempfile.TemporaryDirectory(prefix='anscore_linear_fit_') as temp:
        tmp=Path(temp);version=run([iv,'-V'],tmp).stdout.splitlines()[0]
        run([iv,'-g2012','-Wall','-tnull','-s','stream_linear_fit','-f','files.f'],ROOT)
        run([iv,'-g2012','-Wall','-tnull','-s','fit8_example','-f','example/files.f'],ROOT)
        for w,c,f,r,t in [(2,2,0,4,1),(3,3,4,8,3),(8,6,16,32,8),(10,3,24,12,32),(2,12,0,64,8),(8,1,8,16,1)]:
            text,profile=vectors(w,c,f,r,t);(tmp/'vectors.svh').write_bytes(text.encode())
            exe=tmp/'unit.vvp';top='tb_stream_linear_fit'
            run([iv,'-g2012','-Wall','-I',tmp,'-s',top,'-o',exe]+[f'-P{top}.{key}={value}' for key,value in zip('WCFRT',(w,c,f,r,t))]+[DEPENDENCY,ROOT/'rtl/stream_linear_fit.sv',ROOT/'sim/tb_stream_linear_fit.sv'],tmp)
            result=run([vv,exe],tmp)
            if 'PASS linear_fit' not in result.stdout:raise RuntimeError('completion marker missing')
            profile['simulation_summary']=result.stdout.strip();profiles.append(profile)
        invalid=[('DATA_W',1),('DATA_W',11),('COUNT_W',0),('COUNT_W',13),('DATA_W',10),
                 ('FRAC',-1),('FRAC',25),('RESULT_W',1),('RESULT_W',65),('TAG_W',0),('TAG_W',33)]
        for key,value in invalid:
            run([iv,'-g2012','-tnull','-s','stream_linear_fit',f'-Pstream_linear_fit.{key}={value}',DEPENDENCY,ROOT/'rtl/stream_linear_fit.sv'],tmp,True)
    files=sorted(p for p in ROOT.rglob('*') if p.is_file() and p.name!='verification.json')
    report={'status':['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'],'baseline':'cf9b62d545d5e741589daf1fe99c6533f3148316',
            'checked_at_utc':datetime.now(timezone.utc).isoformat(),'tool_version':version,'profiles':profiles,
            'per_process_timeout_seconds':15,'commands':records,'invalid_parameter_rejections':len(invalid),
            'source_sha256':{str(p.relative_to(ROOT)).replace('\\','/'):hashlib.sha256(p.read_bytes()).hexdigest() for p in files},
            'dependency_sha256':{'../linear_solve2x2/rtl/linear_solve2x2.sv':hashlib.sha256(DEPENDENCY.read_bytes()).hexdigest()},
            'scope':'finite exact centered-Fraction oracle, protocol/latency/reset checks and example compilation',
            'reproduce':'python -B cores/signal_processing/stream_linear_fit/run_tests.py',
            'not_run':['synthesis','PnR','STA','hardware','expanded regression']}
    (ROOT/'verification.json').write_bytes((json.dumps(report,indent=2)+'\n').encode())


if __name__=='__main__':main()
