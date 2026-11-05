"""SPDX-License-Identifier: Apache-2.0. Bounded syntax and finite LDLT tests."""
import datetime
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
CONFIGS=[(1,4,1),(3,8,3),(4,16,8),(8,16,14)]

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def reference(matrix,w,f):
    """Exact-rational symmetric rank-one updates, unlike RTL dot recomputation."""
    n=len(matrix);scale=1<<f;limit=1<<(w-1)
    work=[[Fraction(x,scale) for x in row] for row in matrix]
    lower=[[0]*n for _ in range(n)];diagonal=[0]*n
    for k in range(n):
        diagonal[k]=(work[k][k]*scale).__floor__()
        if diagonal[k]<=0:return [(2,k,k,0,1,1)]
        if diagonal[k]>=limit:return [(3,k,k,0,1,1)]
        lower[k][k]=scale
        for i in range(k+1,n):
            value=work[i][k]*scale*scale/diagonal[k]
            lower[i][k]=int(value) # Python Fraction truncates toward zero.
            if not -limit<=lower[i][k]<limit:return [(3,i,k,0,0,1)]
        for i in range(k+1,n):
            for j in range(k+1,n):
                work[i][j]-=Fraction(lower[i][k]*lower[j][k]*diagonal[k],scale**3)
    return [(0,i,j,diagonal[i] if i==j else lower[i][j],int(i==j),int(i==n-1 and i==j))
            for i in range(n) for j in range(i+1)]

def vectors(maxn,w,f):
    scale=1<<f;lo=-(1<<(w-1));hi=(1<<(w-1))-1
    cases=[]
    def diagonal(n):return [[(scale+(i%2)*(scale//2)) if i==j else 0 for j in range(n)] for i in range(n)]
    for n in sorted({1,maxn}):
        cases.append(diagonal(n))
        a=diagonal(n)
        for i in range(n):
            for j in range(i):a[i][j]=a[j][i]=((i*7+j*3)%5-2)*max(1,scale//8)
        cases.append(a)
    if maxn>1:
        for sign in (1,-1):
            # Small nonzero pivot and extreme off-diagonal force L overflow.
            cases.append([[1,hi if sign>0 else lo],[hi if sign>0 else lo,scale]])
        cases.append([[scale,min(hi,2*scale)],[min(hi,2*scale),scale]])
        # Quantized inputs from a known lower-triangular factorization.
        n=maxn;l=[[scale if i==j else (max(1,scale//4)*((i-j)%3-1) if i>j else 0) for j in range(n)]for i in range(n)]
        d=[max(1,scale//2)]*n
        a=[[sum(l[i][k]*l[j][k]*d[k]for k in range(n))//(scale*scale)for j in range(n)]for i in range(n)]
        assert all(lo<=x<=hi for row in a for x in row)
        cases.append(a)
    cases.extend([[[0]],[[-1]],[[lo]],[[hi]]])
    lines=[];expect=0;success=0;errors=0
    for tag,a in enumerate(cases,1):
        n=len(a);lines.append((0,n,tag,0,0,0,0,0))
        lines.extend((1,a[i][j],0,0,0,0,0,0)for i in range(n)for j in range(i+1))
        result=reference(a,w,f)
        expect+=len(result);success+=result[0][0]==0;errors+=result[0][0]!=0
        lines.extend((2,*row,tag) for row in result)
    for tag,n in enumerate((0,maxn+1,0x80000001),90):
        lines.extend([(0,n,tag,0,0,0,0,0),(2,1,0,0,0,0,1,tag)])
        expect+=1;errors+=1
    return ''.join(' '.join(map(str,row))+'\n' for row in lines),dict(cases=len(cases)+3,records=expect,successful_matrices=success,error_matrices=errors)

def main():
    syntax_only='--syntax-only' in sys.argv[1:]
    if any(arg!='--syntax-only'for arg in sys.argv[1:]):
        raise SystemExit('usage: python run_tests.py [--syntax-only]')
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S_%fZ')
    out=ROOT/'reports'/stamp;out.mkdir(parents=True)
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite';bindir=suite/'bin'
    compiler=str(bindir/'iverilog.exe') if (bindir/'iverilog.exe').is_file() else shutil.which('iverilog') or 'iverilog'
    runtime=str(bindir/'vvp.exe') if (bindir/'vvp.exe').is_file() else shutil.which('vvp') or 'vvp'
    env=dict(os.environ);env['PATH']=os.pathsep.join([str(bindir),str(suite/'lib'),env.get('PATH','')])
    paths=['.gitattributes','rtl/fixedpoint_ldlt.sv','sim/tb_fixedpoint_ldlt.sv','run_tests.py','files.f','example/files.f','example/ldlt_matrix4.sv',
           '../../image_processing/grayscale_anisotropic_diffusion/rtl/deps/integer_divider.v','rtl/deps/signed_divider.v']
    report=dict(utc=stamp,scope='Icarus syntax only'if syntax_only else 'Icarus syntax and finite deterministic unit simulations only',
                sources={p:sha(ROOT/p) for p in paths},tools={p:sha(Path(p)) for p in (compiler,runtime)if Path(p).is_file()},
                timeout_seconds=20,checks=[],configurations=[],hardware='HW_UNVERIFIED')
    # Exact input sources are saved before any invocation, including failures.
    source_root=out/'sources'
    for p in paths:
        target=source_root/Path(p.replace('../','parent/'));target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(ROOT/p,target)
    stopped=False
    def save(): (out/'results.json').write_text(json.dumps(report,indent=2)+'\n')
    def run(name,argv,marker=None):
        nonlocal stopped
        if stopped:return False
        begin=time.monotonic();stdout=b'';stderr=b''
        record=dict(name=name,argv=list(map(str,argv)))
        try:
            child=subprocess.Popen(argv,cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=os.name!='nt')
            try:
                stdout,stderr=child.communicate(timeout=20)
                record['status']='PASS' if child.returncode==0 and (marker is None or marker in stdout) else 'FAIL'
            except subprocess.TimeoutExpired:
                record['status']='TIMEOUT'
                try:
                    if os.name=='nt':subprocess.run(['taskkill','/PID',str(child.pid),'/T','/F'],capture_output=True,timeout=5)
                    else:os.killpg(child.pid,signal.SIGKILL)
                    stdout,stderr=child.communicate(timeout=5)
                except (OSError,subprocess.TimeoutExpired) as exc:
                    record['cleanup_error']=str(exc)
                    child.kill()
            record['returncode']=child.poll()
        except (OSError,TypeError) as exc:
            record.update(status='NOT_RUN',error=str(exc))
        (out/(name+'.stdout.txt')).write_bytes(stdout);(out/(name+'.stderr.txt')).write_bytes(stderr)
        record.update(seconds=round(time.monotonic()-begin,4),stdout_sha256=hashlib.sha256(stdout).hexdigest(),stderr_sha256=hashlib.sha256(stderr).hexdigest())
        report['checks'].append(record);save()
        print(name,record['status'],stdout.decode(errors='replace').strip())
        stopped=record['status']!='PASS'
        return not stopped
    ok=run('syntax_default',[compiler,'-g2012','-Wall','-tnull','-s','fixedpoint_ldlt','-f','files.f'])
    ok=run('syntax_example',[compiler,'-g2012','-Wall','-tnull','-s','ldlt_matrix4','-f','example/files.f'])and ok
    with tempfile.TemporaryDirectory(prefix='anscore_b32_ldlt_')as temporary:
        for index,(n,w,f)in enumerate(CONFIGS):
            if syntax_only:break
            if stopped:break
            data,counts=vectors(n,w,f);vector=out/('vectors%d.txt'%index);vector.write_text(data,encoding='ascii')
            report['configurations'].append(dict(max_n=n,data_w=w,frac=f,vector_sha256=sha(vector),**counts))
            image=Path(temporary)/('sim%d.vvp'%index)
            args=[compiler,'-g2012','-Wall','-s','tb_fixedpoint_ldlt','-Ptb_fixedpoint_ldlt.N=%d'%n,'-Ptb_fixedpoint_ldlt.W=%d'%w,'-Ptb_fixedpoint_ldlt.F=%d'%f,'-o',str(image),'-f','files.f','sim/tb_fixedpoint_ldlt.sv']
            passed=run('compile%d'%index,args);ok=passed and ok
            if passed:ok=run('sim%d'%index,[runtime,str(image),'+vectors='+vector.as_posix()],b'PASS fixedpoint_ldlt')and ok
    report['status']='PASS'if ok else 'INCOMPLETE'
    report['maturity']=(['LINT_PASS','HW_UNVERIFIED']if syntax_only else ['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'])if ok else ['RTL_CANDIDATE','HW_UNVERIFIED']
    save();print('Evidence:',out.relative_to(ROOT));return 0 if ok else 1

if __name__=='__main__':sys.exit(main())
