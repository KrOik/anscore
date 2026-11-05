"""SPDX-License-Identifier: Apache-2.0. Finite physical-clock event tests."""
from pathlib import Path
import datetime,hashlib,json,os,signal,subprocess,sys,time

ROOT=Path(__file__).resolve().parent
BIN=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite/bin'
EXECUTED=['.gitattributes','rtl/event_interval_recorder.sv','sim/tb_event_interval_recorder.sv',
          'example/trigger_return_intervals.sv','files.f','example/files.f','run_tests.py']
CONFIGS=[(1,1,1,1,1),(4,3,3,3,8),(32,16,4,32,8),(8,32,16,4,32)]
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def packed(fields):
    result=0
    for value,width in fields:result=(result<<width)|(value&((1<<width)-1))
    return result

def prepare(t,e,depth,c,g):
    """Reference uses absolute physical edge timestamps and an ordinary list."""
    tick=0;state='idle';q=[];reference=None;epoch=0;tag=0;window=0;lost=0;saturated=0;error=0
    stimulus=[];expected=[]
    coverage=dict(observations=0,admitted=0,dropped=0,full_pop_push=0,simultaneous=0,
                  expired=0,no_reference=0,window_boundary=0,epoch_wrap=0,stop_ignored_events=0,
                  reset_queued=0,done_stalls=0,invalid_window=0,drop_saturation=0)
    def step(rst=0,arm=0,win=0,armtag=0,ref=0,obs=0,stop=0,ready=0,done=0):
        nonlocal tick,state,q,reference,epoch,tag,window,lost,saturated,error
        oldstate=state;oldcount=len(q)
        if rst:
            coverage['reset_queued']+=bool(q)
            state='idle';q=[];reference=None;epoch=0;tag=0;window=0;lost=0;saturated=0;error=0
        elif arm and state=='idle':
            tag=armtag;reference=None;epoch=0;lost=0;saturated=0;q=[];window=win
            error=int(win>=(1<<t));state='done'if error else 'run';coverage['invalid_window']+=error
        else:
            pop=bool(q)and ready
            if pop:q.pop(0)
            if state=='run':
                if stop:
                    coverage['stop_ignored_events']+=bool(ref or obs);state='drain'
                else:
                    if ref:
                        reference=tick;epoch=(epoch+1)% (1<<e)
                        coverage['epoch_wrap']+=epoch==0
                    if obs:
                        coverage['observations']+=1;coverage['simultaneous']+=bool(ref)
                        if reference is None:status=1;interval=0;coverage['no_reference']+=1
                        else:
                            difference=tick-reference
                            if difference>window:status=2;interval=0;coverage['expired']+=1
                            else:status=0;interval=difference;coverage['window_boundary']+=difference==window
                        if len(q)<depth:
                            coverage['admitted']+=1;coverage['full_pop_push']+=bool(oldcount==depth and pop)
                            q.append((status,interval,epoch))
                        else:
                            coverage['dropped']+=1
                            if lost==(1<<c)-1:
                                saturated=1;coverage['drop_saturation']+=1
                            else:lost+=1
            elif state=='drain'and oldcount==0:state='done'
            elif state=='done':
                if done:state='idle'
                else:coverage['done_stalls']+=1
        head=q[0]if q else(0,0,0)
        stimulus.append(packed([(rst,1),(arm,1),(win,32),(armtag,g),(ref,1),(obs,1),(stop,1),(ready,1),(done,1)]))
        expected.append(packed([(state=='idle',1),(state!='idle',1),(state=='run',1),(bool(q),1),
                               (head[0],2),(head[1],t),(head[2],e),(tag,g),(state=='done',1),
                               (error,1),(lost,c),(saturated,1),(tag,g)]))
        tick+=1
    def finish():
        step(stop=1,ref=1,obs=1)
        for _ in range(depth+4):step(ref=1,obs=1,ready=1)
        assert state=='done'and not q
        for _ in range(3):step(ref=1,obs=1)
        step(done=1);assert state=='idle'
    def arm(win,identifier):
        assert state=='idle'
        step(arm=1,win=win,armtag=identifier&((1<<g)-1),ref=1,obs=1)
    step(rst=1);step(rst=1)
    arm(0,1)
    step(obs=1,ready=1);step(obs=1,ready=1)
    step(ref=1,obs=1,ready=1);step(obs=1,ready=1);step(obs=1,ready=1)
    finish()
    # Fill queue, then prove full pop+push is admitted without loss.
    arm(min((1<<t)-1,15),2)
    for _ in range(depth):step(ref=1,obs=1)
    step(ref=1,obs=1,ready=1)
    for _ in range(40):step(ref=1,obs=1) # loss saturation for narrow counters
    finish()
    # Boundary interval and long waits past a small physical counter's wrap.
    w=min((1<<t)-1,15);arm(w,3);step(ref=1,obs=1,ready=1)
    for k in range(1,w+3):step(obs=1,ready=1)
    for _ in range(37):step(obs=1,ready=1)
    for k in range(20):step(ref=(k%2==0),obs=1,ready=(k%3!=0))
    finish()
    if t<32:
        arm(1<<t,4);assert state=='done';step();step(done=1)
    else:
        arm(0xffffffff,4);step(ref=1,obs=1,ready=1);step(obs=1,ready=1);finish()
    # Reset while nonempty, and reset a held DONE before fresh acquisition.
    arm(0,5);step(ref=1,obs=1);step(rst=1)
    arm(0,6);step(stop=1);step();assert state=='done';step(rst=1)
    arm(0,7);step(ref=1,obs=1,ready=1);finish();step()
    for name in ['full_pop_push','simultaneous','expired','no_reference','window_boundary','stop_ignored_events','reset_queued','done_stalls']:
        assert coverage[name]>0,name
    if c<6:assert coverage['drop_saturation']>0
    if e<=3:assert coverage['epoch_wrap']>0
    assert len(stimulus)==len(expected)
    return stimulus,expected,coverage

def child(name,argv,cwd,env,report):
    begin=time.monotonic();stdout=stderr=b'';record=dict(name=name,argv=list(map(str,argv)),cwd=str(cwd))
    opts={'creationflags':subprocess.CREATE_NO_WINDOW}if os.name=='nt'else{'start_new_session':True}
    try:
        process=subprocess.Popen(argv,cwd=cwd,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**opts)
        try:
            stdout,stderr=process.communicate(timeout=20)
            record.update(status='PASS'if process.returncode==0 else 'FAIL',returncode=process.returncode)
        except subprocess.TimeoutExpired as exc:
            record['status']='TIMEOUT';stdout=exc.stdout or b'';stderr=exc.stderr or b''
            try:
                if os.name=='nt':
                    subprocess.run([str(Path(os.environ.get('SystemRoot',r'C:\Windows'))/'System32/taskkill.exe'),'/PID',str(process.pid),'/T','/F'],capture_output=True,timeout=5,creationflags=subprocess.CREATE_NO_WINDOW)
                else:os.killpg(process.pid,signal.SIGKILL)
            except (OSError,subprocess.TimeoutExpired)as exc:record['cleanup_error']=repr(exc)
            try:
                if process.poll()is None:process.kill()
                stdout,stderr=process.communicate(timeout=2)
            except (OSError,subprocess.TimeoutExpired)as exc:record['drain_error']=repr(exc)
            record['returncode']=process.poll()
    except (OSError,TypeError)as exc:record.update(status='NOT_RUN',error=repr(exc))
    if name.startswith('sim')and record['status']=='PASS'and b'PASS event_interval_recorder'not in stdout:record['status']='FAIL_NO_PASS_MARKER'
    (report/(name+'.stdout.txt')).write_bytes(stdout);(report/(name+'.stderr.txt')).write_bytes(stderr)
    record.update(seconds=round(time.monotonic()-begin,4),timeout_seconds=20,stdout_sha256=hashlib.sha256(stdout).hexdigest(),stderr_sha256=hashlib.sha256(stderr).hexdigest())
    return record

def main():
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S_%fZ')
    report=ROOT/'reports'/stamp;report.mkdir(parents=True)
    build=ROOT/'.build'/stamp;build.mkdir(parents=True)
    result=dict(schema='event-interval-recorder-finite-checks-v1',utc=stamp,status='INCOMPLETE',
                sources={f:sha(ROOT/f)for f in EXECUTED},checks=[],profiles=[],preparation_complete=False,
                hardware='HW_UNVERIFIED',synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN')
    for f in EXECUTED:
        target=report/'sources'/f;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes((ROOT/f).read_bytes())
    iv=BIN/'iverilog.exe';vvp=BIN/'vvp.exe'
    result['tools']={str(p):sha(p)for p in [iv,vvp]if p.is_file()}
    env=dict(os.environ);env['PATH']=str(BIN)+os.pathsep+str(BIN.parent/'lib')+os.pathsep+env.get('PATH','')
    stopped=False
    def run(name,argv,cwd=ROOT):
        nonlocal stopped
        if stopped:return False
        record=child(name,argv,cwd,env,report);result['checks'].append(record)
        print(name,record['status'],flush=True)
        stopped=record['status']!='PASS';return not stopped
    try:
        if not run('syntax_default',[iv,'-g2012','-Wall','-tnull','-s','event_interval_recorder','-f','files.f']):return 1
        if not run('syntax_example',[iv,'-g2012','-Wall','-tnull','-s','trigger_return_intervals','-f','example/files.f']):return 1
        for index,config in enumerate(CONFIGS):
            t,e,d,c,g=config
            inputs,outputs,coverage=prepare(*config)
            folder=report/('profile%d'%index);folder.mkdir()
            for name,values,bits in [('stimulus.hex',inputs,39+g),('expected.hex',outputs,9+t+e+c+2*g)]:
                (folder/name).write_text(''.join(('%0*x\n'%((bits+3)//4,value))for value in values),encoding='ascii')
            result['profiles'].append(dict(time_w=t,epoch_w=e,fifo_depth=d,drop_w=c,tag_w=g,cycles=len(inputs),coverage=coverage,
                                           stimulus_sha256=sha(folder/'stimulus.hex'),expected_sha256=sha(folder/'expected.hex')))
        result['preparation_complete']=True
        for index,p in enumerate(result['profiles']):
            image=build/('sim%d.vvp'%index)
            values=[p['time_w'],p['epoch_w'],p['fifo_depth'],p['drop_w'],p['tag_w'],p['cycles']]
            parameters=['-Ptb_event_interval_recorder.%s=%d'%(name,value)for name,value in zip(('T','E','D','C','G','N'),values)]
            if not run('compile%d'%index,[iv,'-g2012','-Wall','-s','tb_event_interval_recorder',*parameters,'-o',image,'-f','files.f','sim/tb_event_interval_recorder.sv']):return 1
            if not run('sim%d'%index,[vvp,image],report/('profile%d'%index)):return 1
        result['status']='PASS';return 0
    except Exception as exc:
        result['status']='PREPARATION_OR_RUNNER_FAILED';result['error']=repr(exc);raise
    finally:
        unchanged=all(sha(ROOT/f)==h for f,h in result['sources'].items())
        result['sources_unchanged']=unchanged
        if not unchanged:result['status']='SOURCE_CHANGED'
        elif stopped:result['status']=result['checks'][-1]['status']
        result['maturity']=['LINT_PASS','UNIT_SIM_PASS','HW_UNVERIFIED']if result['status']=='PASS'else['RTL_CANDIDATE','HW_UNVERIFIED']
        (report/'results.json').write_text(json.dumps(result,indent=2)+'\n')
        print('Evidence:',report.relative_to(ROOT),flush=True)
        if not unchanged:raise RuntimeError('Source changed during checks')

if __name__=='__main__':sys.exit(main())
