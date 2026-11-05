"""SPDX-License-Identifier: Apache-2.0. Bounded original bin-bandwidth checks."""
from pathlib import Path
from fractions import Fraction
from itertools import accumulate
import datetime,hashlib,json,os,random,signal,subprocess,sys,time,traceback

ROOT=Path(__file__).resolve().parent
BIN=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite/bin'
CONFIGS=[(1,1,1,0),(17,16,8,0),(4096,32,32,0),(1024,32,8,1)]
SOURCES=['.gitattributes','rtl/occupied_spectral_bandwidth.sv','example/iq_occupied_bandwidth.sv',
         'sim/tb_occupied_spectral_bandwidth.sv','files.f','example/files.f','run_tests.py',
         '../dsp_isp_library/dsp/spectrum/rtl/mag_squared.sv']

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def oracle(powers,num,den):
    total=sum(powers)
    if not total:return (3,0,0,0,0,0,0,0)
    # Independent rational CDF lookup and direct slice sums, no RTL states/product model.
    cdf=[Fraction(value,total) for value in accumulate(powers)]
    lower=Fraction(den-num,2*den);upper=Fraction(den+num,2*den)
    lo=next(i for i,value in enumerate(cdf) if value>lower)
    hi=next(i for i,value in enumerate(cdf) if value>=upper)
    retained=sum(powers[lo:hi+1]);below=sum(powers[:lo]);above=sum(powers[hi+1:])
    assert lo<=hi and retained*den>=total*num and total==retained+below+above
    assert 2*den*below<=total*(den-num) and 2*den*above<=total*(den-num)
    return (0,lo,hi,hi-lo+1,total,retained,below,above)

def prepare(n,data_w,tag_w,iq):
    assert oracle([1,1,1,1],1,2)==(0,1,2,2,4,2,1,1)
    assert oracle([0,0,7,0,0],1,1)==(0,2,2,1,7,7,0,0)
    assert oracle([0,0,0],99,100)==(3,0,0,0,0,0,0,0)
    rows=[];commands=records=samples=0
    def emit(*args):rows.append(list(args)+[0]*(10-len(args)))
    def power(word):
        if not iq:return word
        i=word&65535;q=word>>16
        if i>=32768:i-=65536
        if q>=32768:q-=65536
        return i*i+q*q
    mask=(1<<data_w)-1;maximum=0x80008000 if iq else mask
    unit=0x00040003 if iq else 1
    rng=random.Random(350035+n)
    def frame(words,num,den,gaps=False):
        nonlocal commands,records,samples
        tag=(0xfedc0000+commands+1)&((1<<tag_w)-1)
        emit(1,len(words),num,den,tag);commands+=1
        for index,word in enumerate(words):
            emit(2,word);samples+=1
            if gaps and index%11==5:emit(4,3)
        result=oracle(list(map(power,words)),num,den)
        emit(3,*result,tag);records+=1
    frame([0],99,100)
    frame([maximum],99,100)
    frame([unit]*min(n,4),1,2)
    short=min(n,9);frame([maximum if i==short//2 else 0 for i in range(short)],1,1)
    frame([0 if i%3==0 else unit for i in range(min(n,16))],1,2)
    frame([maximum]*n,65535,65535)
    frame([0]*n,1,65535)
    raw=[0x00040003,0xfffcfffd,0x7fff8000,0x00010000,0,0x80008000]
    frame([raw[i%len(raw)] if iq else (i*16777619+37)&mask for i in range(n)],99,100,True)
    short=min(n,17);frame([maximum if i==short//2 else 0 for i in range(short)],1,65535)
    frame([rng.choice(raw) if iq else rng.getrandbits(data_w) for _ in range(min(n,31))],65534,65535)
    frame([maximum if i in(0,min(n,16)-1) else unit for i in range(min(n,16))],2,3)
    for length,num,den,status in [(0,0,0,1),(n+1,1,1,1),(0x80000001,1,1,1),
                                  (1,0,1,2),(1,1,0,2),(1,2,1,2)]:
        tag=(commands+1)&((1<<tag_w)-1);emit(1,length,num,den,tag);emit(3,status,0,0,0,0,0,0,0,tag)
        commands+=1;records+=1
    assert commands==17 and records==17
    return ''.join(' '.join('%016x'%x for x in row)+'\n' for row in rows),dict(commands=commands,records=records,samples=samples,valid_frames=11,invalid_commands=6)

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
    result=dict(schema='occupied-spectral-bandwidth-finite-v1',utc=stamp,status='INCOMPLETE',
        source_sha256={p:sha(ROOT/p) for p in SOURCES},checks=[],profiles=[],preparation_attempts=0,preparation_completed_calls=0,
        preparation_complete=False,suite_complete=False,automatic_retry=False,hardware='HW_UNVERIFIED',
        synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN')
    # Exact byte archive precedes every numeric preparation and HDL child.
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
            result['profiles'].append(dict(max_bins=config[0],data_w=config[1],tag_w=config[2],iq=config[3],vectors_sha256=sha(path),**counts))
        result['preparation_complete']=True
        if not run('syntax_default',[iv,'-g2012','-Wall','-tnull','-s','occupied_spectral_bandwidth','-f','files.f']):return 1
        if not run('syntax_example',[iv,'-g2012','-Wall','-tnull','-s','iq_occupied_bandwidth','-f','example/files.f']):return 1
        for index,p in enumerate(result['profiles']):
            image=build/('sim%d.vvp'%index)
            params=['-Ptb_occupied_spectral_bandwidth.%s=%d'%(k,v) for k,v in zip(('N','D','T','IQ'),(p['max_bins'],p['data_w'],p['tag_w'],p['iq']))]
            if not run('compile%d'%index,[iv,'-g2012','-Wall','-s','tb_occupied_spectral_bandwidth',*params,'-o',image,'-f','example/files.f','sim/tb_occupied_spectral_bandwidth.sv']):return 1
            marker=('PASS occupied_spectral_bandwidth N=%d D=%d T=%d IQ=%d '%(p['max_bins'],p['data_w'],p['tag_w'],p['iq'])).encode()
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
        result['maturity']=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED'] if result['status']=='PASS' else ['RTL_CANDIDATE','HW_UNVERIFIED']
        (report/'results.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8',newline='\n')
        print('Evidence:',report.relative_to(ROOT),flush=True)
        if not unchanged or not vectors_unchanged:raise RuntimeError('Executed inputs changed')

if __name__=='__main__':sys.exit(main())
