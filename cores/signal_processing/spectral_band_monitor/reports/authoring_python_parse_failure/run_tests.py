"""SPDX-License-Identifier: Apache-2.0. Finite band/power-chain checks only."""
from pathlib import Path
import datetime,hashlib,json,os,signal,subprocess,sys,time

ROOT=Path(__file__).resolve().parent
BIN=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite/bin'
CONFIGS=[(1,1,1,0),(17,3,8,0),(4096,8,32,0),(1024,4,8,1)]
SOURCES=['.gitattributes','rtl/spectral_band_monitor.sv','example/iq_spectral_band_monitor.sv',
         'sim/tb_spectral_band_monitor.sv','files.f','example/files.f','run_tests.py',
         '../dsp_isp_library/dsp/spectrum/rtl/mag_squared.sv']
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def prepare(n,b,t,iq):
    rows=[];frames=0;records=0;samples=0
    def emit(*args):rows.append(list(args)+[0]*(12-len(args)))
    def configure(bands):
        for q,(lo,hi)in enumerate(bands):emit(0,q,lo,hi)
    def power(word):
        if not iq:return word
        i=word&65535;q=word>>16
        if i>=32768:i-=65536
        if q>=32768:q-=65536
        return i*i+q*q
    def frame(length,kind,threshold):
        nonlocal frames,records,samples
        bands=[]
        for q in range(b):
            lo=0 if q in(0,2)else(length-1 if q==1 else(q*3)%length)
            hi=length-1 if q==0 else(lo if q in(1,2)else min(length-1,lo+max(1,length//3)))
            bands.append((lo,hi))
        configure(bands);tag=(0xfedc0000+frames+1)&((1<<t)-1);emit(1,length,threshold,tag)
        words=[]
        for i in range(length):
            maximum=0x80008000 if iq else 0xffffffff
            if kind==0:word=0
            elif kind==1:word=maximum
            elif kind==2:word=[0x00040003,0xfffcfffd,0x7fff8000,0x00010000,0][i%5]if iq else(i*16777619+37)&0xffffffff
            elif kind==3:word=maximum if i==length//2 else(0x00040003 if iq else i%7)
            else:word=maximum if i in(0,length-1)else0
            words.append(word);emit(2,word);samples+=1
            if kind==2 and i%11==5:emit(4,2)
        powers=list(map(power,words))
        for q,(lo,hi)in enumerate(bands):
            subset=powers[lo:hi+1];peak=max(subset);index=powers.index(peak,lo,hi+1)
            energy=sum(subset);moment=sum(index*powers[index]for index in range(lo,hi+1))
            above=sum(v>=threshold for v in subset)
            emit(3,0,q,lo,hi,energy,moment,peak,index,above,int(q==b-1),tag);records+=1
        frames+=1
    maxpower=0x80000000 if iq else0xffffffff
    for length,kind,threshold in [(1,0,0),(1,1,maxpower),(min(n,17),2,25),(n,1,maxpower),
                                  (n,2,0x80000000),(n,4,maxpower),(n,3,1)]:
        frame(length,kind,threshold)
    for length in [0,n+1,0x80000001]:
        configure([(0,0)]*b);tag=(frames+10)&((1<<t)-1);emit(1,length,0,tag)
        emit(3,1,0,0,0,0,0,0,0,0,1,tag);records+=1;frames+=1
    for low,high in [(1,0),(0,0x80000000),(0,1)]:
        bands=[(0,0)]*b;bands[-1]=(low,high);configure(bands)
        tag=(frames+10)&((1<<t)-1);emit(1,1,0,tag);emit(3,2,b-1,0,0,0,0,0,0,0,1,tag)
        records+=1;frames+=1
    return ''.join(' '.join('%016x'%x for x in row)+'\n'for row in rows),dict(commands=frames,records=records,samples=samples,valid_frames=7,invalid_commands=6)

def execute(name,argv,cwd,env,report,marker=None):
    begin=time.monotonic();stdout=stderr=b'';record=dict(name=name,argv=list(map(str,argv)),cwd=str(cwd))
    options={'creationflags':subprocess.CREATE_NO_WINDOW}if os.name=='nt'else{'start_new_session':True}
    try:process=subprocess.Popen(argv,cwd=cwd,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**options)
    except(OSError,TypeError)as exc:record.update(status='NOT_RUN',error=repr(exc))
    else:
        try:
            stdout,stderr=process.communicate(timeout=20)
            record.update(status='PASS'if process.returncode==0 else'FAIL',returncode=process.returncode)
        except subprocess.TimeoutExpired as exc:
            record['status']='TIMEOUT';stdout=exc.stdout or b'';stderr=exc.stderr or b''
            try:
                if os.name=='nt':subprocess.run([str(Path(os.environ.get('SystemRoot',r'C:\Windows'))/'System32/taskkill.exe'),'/PID',str(process.pid),'/T','/F'],capture_output=True,timeout=5,creationflags=subprocess.CREATE_NO_WINDOW)
                else:os.killpg(process.pid,signal.SIGKILL)
            except(OSError,subprocess.TimeoutExpired)as exc:record['cleanup_error']=repr(exc)
            try:
                if process.poll()is None:process.kill()
                stdout,stderr=process.communicate(timeout=2)
            except(OSError,subprocess.TimeoutExpired)as exc:record['drain_error']=repr(exc)
            record['returncode']=process.poll()
    if record['status']=='PASS'and marker is not None and not any(line.startswith(marker)for line in stdout.splitlines()):
        record.update(status='FAIL_NO_PASS_MARKER',required_marker=marker.decode())
    (report/(name+'.stdout.txt')).write_bytes(stdout);(report/(name+'.stderr.txt')).write_bytes(stderr)
    record.update(seconds=round(time.monotonic()-begin,4),timeout_seconds=20,cleanup_budget_seconds=7,
                  stdout_sha256=hashlib.sha256(stdout).hexdigest(),stderr_sha256=hashlib.sha256(stderr).hexdigest())
    return record

def main():
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S_%fZ')
    report=ROOT/'reports'/stamp;report.mkdir(parents=True)
    build=ROOT/'.build'/stamp;build.mkdir(parents=True)
    result=dict(schema='spectral-band-monitor-finite-checks-v1',utc=stamp,status='INCOMPLETE',
                source_sha256={p:sha(ROOT/p)for p in SOURCES},checks=[],profiles=[],preparation_calls=0,
                preparation_complete=False,suite_complete=False,hardware='HW_UNVERIFIED',
                synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN')
    for p in SOURCES:
        target=report/'sources'/p.replace('../','parent/');target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes((ROOT/p).read_bytes())
    iv=BIN/'iverilog.exe';vvp=BIN/'vvp.exe';result['tools']={str(p):sha(p)for p in[iv,vvp]if p.is_file()}
    env=dict(os.environ);env['PATH']=str(BIN)+os.pathsep+str(BIN.parent/'lib')+os.pathsep+env.get('PATH','')
    stopped=False
    def run(name,argv,marker=None):
        nonlocal stopped
        if stopped:return False
        record=execute(name,argv,ROOT,env,report,marker);result['checks'].append(record)
        print(name,record['status'],flush=True);stopped=record['status']!='PASS';return not stopped
    try:
        # All exact input sources and all numerical vectors precede every HDL tool.
        for index,config in enumerate(CONFIGS):
            result['preparation_calls']+=1
            data,counts=prepare(*config);path=report/('vectors%d.txt'%index);path.write_text(data,encoding='ascii')
            result['profiles'].append(dict(max_bins=config[0],bands=config[1],tag_w=config[2],iq=config[3],vectors_sha256=sha(path),**counts))
        result['preparation_complete']=True
        if not run('syntax_default',[iv,'-g2012','-Wall','-tnull','-s','spectral_band_monitor','-f','files.f']):return 1
        if not run('syntax_example',[iv,'-g2012','-Wall','-tnull','-s','iq_spectral_band_monitor','-f','example/files.f']):return 1
        for index,p in enumerate(result['profiles']):
            image=build/('sim%d.vvp'%index)
            params=['-Ptb_spectral_band_monitor.%s=%d'%(k,v)for k,v in zip(('N','B','T','IQ'),(p['max_bins'],p['bands'],p['tag_w'],p['iq']))]
            if not run('compile%d'%index,[iv,'-g2012','-Wall','-s','tb_spectral_band_monitor',*params,'-o',image,'-f','example/files.f','sim/tb_spectral_band_monitor.sv']):return 1
            marker=('PASS spectral_band_monitor N=%d B=%d T=%d IQ=%d '%(p['max_bins'],p['bands'],p['tag_w'],p['iq'])).encode()
            if not run('sim%d'%index,[vvp,image,'+vectors='+(report/('vectors%d.txt'%index)).as_posix()],marker):return 1
        result['suite_complete']=True;result['status']='PASS';return 0
    except Exception as exc:
        result.update(status='PREPARATION_OR_RUNNER_FAILED',error=repr(exc));raise
    finally:
        unchanged=all(sha(ROOT/p)==h for p,h in result['source_sha256'].items());result['sources_unchanged']=unchanged
        if not unchanged:result['status']='SOURCE_CHANGED'
        elif stopped:result['status']=result['checks'][-1]['status']
        if result['status']=='PASS'and not(result['suite_complete']and result['preparation_complete']and len(result['checks'])==10):result['status']='INCOMPLETE'
        result['maturity']=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED']if result['status']=='PASS'else['RTL_CANDIDATE','HW_UNVERIFIED']
        (report/'results.json').write_text(json.dumps(result,indent=2)+'\n');print('Evidence:',report.relative_to(ROOT),flush=True)
        if not unchanged:raise RuntimeError('Checked sources changed')

if __name__=='__main__':sys.exit(main())
