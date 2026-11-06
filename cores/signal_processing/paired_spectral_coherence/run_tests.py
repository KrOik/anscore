"""SPDX-License-Identifier: Apache-2.0. Finite exact coherence/unit checks."""
from pathlib import Path
from fractions import Fraction
import datetime,hashlib,json,os,random,signal,subprocess,sys,time,traceback

ROOT=Path(__file__).resolve().parent
BIN=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite/bin'
CONFIGS=[(1,1,1,0),(17,4,8,0),(256,64,32,0),(64,16,8,1)]
SOURCES=['.gitattributes','rtl/paired_spectral_coherence.sv','example/dual_fft_coherence64.sv',
         'sim/tb_paired_spectral_coherence.sv','files.f','example/files.f','run_tests.py',
         '../dsp_isp_library/infra/fixedpoint/rtl/cplx_mac.sv',
         '../dsp_isp_library/infra/fixedpoint/rtl/recip_div.sv',
         '../../system/common_scaffold/image/histogram/rtl/img_hist_serial_multiply.v']

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def oracle(pairs):
    # Direct mathematical sums and rational round-to-nearest-even, independent
    # of all RTL helpers, packed RAM, widths, schedules and divider recurrences.
    xx=sum(xr*xr+xi*xi for xr,xi,yr,yi in pairs)
    yy=sum(yr*yr+yi*yi for xr,xi,yr,yi in pairs)
    re=sum(xr*yr+xi*yi for xr,xi,yr,yi in pairs)
    im=sum(xr*yi-xi*yr for xr,xi,yr,yi in pairs)
    if not xx or not yy:
        assert re==im==0
        return 4,xx,yy,re,im,0
    ratio=Fraction(re*re+im*im,xx*yy)
    assert 0<=ratio<=1
    return 0,xx,yy,re,im,round(65536*ratio)

def prepare(nmax,kmax,tag_w,example):
    assert oracle([(1,0,1,0),(1,0,-1,0)])==(0,2,2,0,0,0)
    assert oracle([(1,0,1,0),(1,0,0,1)])==(0,2,2,1,1,32768)
    ties=[[(1,0,1,0),(0,0,255,256),(0,0,22,5),(0,0,1,0)],
          [(1,0,3,0),(0,0,627,8),(0,0,3,2),(0,0,1,0)]]
    assert oracle(ties[0])[-1]==0 and oracle(ties[1])[-1]==2
    rows=[];commands=records=samples=valid_batches=bad_commands=bad_last=0
    def emit(*args):
        assert len(args)<=10
        rows.append([x&((1<<64)-1) for x in args]+[0]*(10-len(args)))
    def tag():return (0xfedc0000+commands+1)&((1<<tag_w)-1)
    def pack(p):
        assert all(-32768<=x<=32767 for x in p)
        return sum((x&65535)<<(16*i) for i,x in enumerate(p))
    def batch(frames,gaps=False):
        nonlocal commands,records,samples,valid_batches
        n=len(frames[0]);k=len(frames);t=tag()
        assert 1<=n<=nmax and 1<=k<=kmax and all(len(f)==n for f in frames)
        emit(1,n,k,t);commands+=1;valid_batches+=1
        for frame in frames:
            for i,p in enumerate(frame):
                emit(2,pack(p),i==n-1,i==n-1);samples+=1
                if gaps and samples%7==3:emit(4,3)
        for i,column in enumerate(zip(*frames)):
            status,xx,yy,re,im,q=oracle(column)
            emit(3,status,i,xx,yy,re,im,q,i==n-1,t);records+=1
    # K=1 is explicitly diagnostic: all nonzero pairs give unity.
    for p in [(0,0,3,4),(3,4,0,0),(0,0,0,0),(3,4,3,4),
              (3,4,-3,-4),(3,4,-4,3),(-32768,-32768,-32768,-32768),
              (32767,-32768,-32768,32767)]:batch([[p]])
    raw=[(-32768,-32768,-32768,-32768),(32767,-32768,32767,32767),
         (3,4,-4,3),(0,0,0,0),(0,0,2,3),(-1,0,1,0)]
    batch([[raw[i%len(raw)] for i in range(nmax)]],True)
    # Maximum N and maximum K are separate finite extremes, never NxK max replay.
    batch([[(-32768,-32768,32767,-32768)]]*kmax)
    if kmax>=2:
        batch([[(1,0,1,0)],[(1,0,-1,0)]])
        batch([[(1,0,1,0)],[(1,0,0,1)]])
        batch([[raw[i%len(raw)] for i in range(min(nmax,11))],
               [raw[(i+2)%len(raw)] for i in range(min(nmax,11))]],True)
    if kmax>=4:
        for tie in ties:batch([[p] for p in tie])
    rng=random.Random(360036+nmax)
    choices=[-32768,-32767,-257,-1,0,1,256,32767]
    batch([[tuple(rng.choice(choices) for _ in range(4)) for i in range(min(nmax,13))]
           for j in range(min(kmax,4))],True)
    # Full-width bad-command validation and BAD_LENGTH precedence.
    for n,k,status in [(0,0,1),(nmax+1,1,1),(0x80000001,1,1),
                        (1,0,2),(1,kmax+1,2),(1,0x80000001,2)]:
        t=tag();emit(1,n,k,t);emit(3,status,0,0,0,0,0,0,1,t)
        commands+=1;records+=1;bad_commands+=1
    # Missing both LAST, X-only mismatch, Y-only mismatch and (when N>1)
    # an early marker plus a missing marker after a valid preceding bin.
    malformed=[(1,[(0,0)],0),(1,[(0,1)],0),(1,[(1,0)],0)]
    if nmax>1:malformed += [(2,[(1,0)],0),(2,[(0,0),(0,0)],1)]
    for n,marks,index in malformed:
        t=tag();emit(1,n,1,t);commands+=1;bad_last+=1
        for xl,yl in marks:emit(2,pack((3,4,-4,3)),xl,yl);samples+=1
        emit(3,3,index,0,0,0,0,0,1,t);records+=1
    return ''.join(' '.join('%016x'%x for x in row)+'\n' for row in rows),dict(
        commands=commands,records=records,samples=samples,valid_batches=valid_batches,
        invalid_commands=bad_commands,last_errors=bad_last,rne_ties=2 if kmax>=4 else 0)

def execute(name,argv,cwd,env,report,marker=None):
    begin=time.monotonic();out=err=b'';record=dict(name=name,argv=list(map(str,argv)),cwd=str(cwd),cleanup=[])
    options={'creationflags':subprocess.CREATE_NO_WINDOW} if os.name=='nt' else {'start_new_session':True}
    try:child=subprocess.Popen(record['argv'],cwd=cwd,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**options)
    except OSError as exc:record.update(status='NOT_RUN',error=repr(exc))
    else:
        try:
            out,err=child.communicate(timeout=20);record.update(status='PASS' if child.returncode==0 else 'FAIL',returncode=child.returncode)
        except subprocess.TimeoutExpired as exc:
            record.update(status='TIMEOUT');out=exc.stdout or b'';err=exc.stderr or b''
            if os.name=='nt':
                kill=[str(Path(os.environ.get('SystemRoot',r'C:\Windows'))/'System32/taskkill.exe'),'/PID',str(child.pid),'/T','/F']
                try:
                    k=subprocess.run(kill,capture_output=True,timeout=5,creationflags=subprocess.CREATE_NO_WINDOW)
                    record['cleanup'].append(dict(argv=kill,returncode=k.returncode,stdout=k.stdout.decode(errors='replace'),stderr=k.stderr.decode(errors='replace')))
                except (OSError,subprocess.TimeoutExpired) as exc:record['cleanup'].append(dict(error=repr(exc)))
            else:
                try:os.killpg(child.pid,signal.SIGKILL)
                except OSError as exc:record['cleanup'].append(dict(error=repr(exc)))
            try:
                if child.poll() is None:child.kill()
                out,err=child.communicate(timeout=2)
            except (OSError,subprocess.TimeoutExpired) as exc:record['cleanup'].append(dict(drain_error=repr(exc)))
            record['returncode']=child.poll()
    if record['status']=='PASS' and marker is not None and not any(line.startswith(marker) for line in out.splitlines()):
        record.update(status='FAIL_NO_PASS_MARKER',required_marker=marker.decode())
    (report/(name+'.stdout.txt')).write_bytes(out);(report/(name+'.stderr.txt')).write_bytes(err)
    record.update(seconds=round(time.monotonic()-begin,4),timeout_seconds=20,cleanup_budget_seconds=7,
                  stdout_sha256=hashlib.sha256(out).hexdigest(),stderr_sha256=hashlib.sha256(err).hexdigest())
    return record

def main():
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S_%fZ')
    report=ROOT/'reports'/stamp;report.mkdir(parents=True,exist_ok=False)
    build=ROOT/'.build'/stamp;build.mkdir(parents=True,exist_ok=False)
    result=dict(schema='paired-spectral-coherence-finite-v1',utc=stamp,status='INCOMPLETE',
        source_sha256={p:sha(ROOT/p) for p in SOURCES},checks=[],profiles=[],preparation_attempts=0,preparation_completed_calls=0,
        preparation_complete=False,suite_complete=False,automatic_retry=False,hardware='HW_UNVERIFIED',
        synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN')
    # Exact byte archive precedes every numerical preparation and HDL child.
    for p in SOURCES:
        target=report/'sources'/p.replace('../','parent/');target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes((ROOT/p).read_bytes())
    iv=BIN/'iverilog.exe';vvp=BIN/'vvp.exe';result['tools']={str(p):sha(p) for p in [iv,vvp] if p.is_file()}
    env=dict(os.environ);env['PATH']=str(BIN)+os.pathsep+str(BIN.parent/'lib')+os.pathsep+env.get('PATH','')
    stopped=False
    def run(name,argv,marker=None):
        nonlocal stopped
        if stopped:return False
        rec=execute(name,argv,ROOT,env,report,marker);result['checks'].append(rec)
        print(name,rec['status'],flush=True);stopped=rec['status']!='PASS';return not stopped
    try:
        for index,config in enumerate(CONFIGS):
            result['preparation_attempts']+=1
            data,counts=prepare(*config);path=report/('vectors%d.txt'%index);path.write_text(data,encoding='ascii',newline='\n')
            result['preparation_completed_calls']+=1
            result['profiles'].append(dict(max_bins=config[0],max_averages=config[1],tag_w=config[2],example=config[3],vectors_sha256=sha(path),**counts))
        result['preparation_complete']=True
        if not run('syntax_default',[iv,'-g2012','-Wall','-tnull','-s','paired_spectral_coherence','-f','files.f']):return 1
        if not run('syntax_example',[iv,'-g2012','-Wall','-tnull','-s','dual_fft_coherence64','-f','example/files.f']):return 1
        for index,p in enumerate(result['profiles']):
            image=build/('sim%d.vvp'%index)
            params=['-Ptb_paired_spectral_coherence.%s=%d'%(k,v) for k,v in zip(('N','K','T','EX'),(p['max_bins'],p['max_averages'],p['tag_w'],p['example']))]
            if not run('compile%d'%index,[iv,'-g2012','-Wall','-s','tb_paired_spectral_coherence',*params,'-o',image,'-f','example/files.f','sim/tb_paired_spectral_coherence.sv']):return 1
            marker=('PASS paired_spectral_coherence N=%d K=%d T=%d EX=%d '%(p['max_bins'],p['max_averages'],p['tag_w'],p['example'])).encode()
            if not run('sim%d'%index,[vvp,image,'+vectors='+(report/('vectors%d.txt'%index)).as_posix()],marker):return 1
        result['suite_complete']=True;result['status']='PASS';return 0
    except Exception:
        result.update(status='PREPARATION_OR_RUNNER_FAILED',exception=traceback.format_exc());raise
    finally:
        unchanged=all(sha(ROOT/p)==h for p,h in result['source_sha256'].items())
        vectors_unchanged=all(sha(report/('vectors%d.txt'%i))==p['vectors_sha256'] for i,p in enumerate(result['profiles']))
        result.update(sources_unchanged=unchanged,vectors_unchanged=vectors_unchanged)
        if not unchanged or not vectors_unchanged:result['status']='SOURCE_CHANGED'
        elif stopped:result['status']=result['checks'][-1]['status']
        if result['status']=='PASS' and not(result['suite_complete'] and result['preparation_complete'] and len(result['checks'])==10):result['status']='INCOMPLETE'
        result['maturity']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'] if result['status']=='PASS' else ['RTL_CANDIDATE','HW_UNVERIFIED']
        (report/'results.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8',newline='\n')
        print('Evidence:',report.relative_to(ROOT),flush=True)
        if not unchanged or not vectors_unchanged:raise RuntimeError('Executed inputs changed')

if __name__=='__main__':sys.exit(main())
