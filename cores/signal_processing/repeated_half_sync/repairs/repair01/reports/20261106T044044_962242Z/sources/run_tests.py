"""SPDX-License-Identifier: Apache-2.0. B37 finite, explicit-approval runner."""
from pathlib import Path
import datetime,hashlib,json,math,os,random,re,signal,subprocess,sys,time,traceback

ROOT=Path(__file__).resolve().parent
BIN=ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite/bin'
SOURCES=['.gitattributes','PRECHECK_PLAN.json','run_tests.py','files.f','example/files.f',
         'rtl/repeated_half_sync.sv','example/sync12_phase.sv','sim/tb_repeated_half_sync.sv',
         '../dsp_isp_library/infra/fixedpoint/rtl/cplx_mac.sv',
         '../../system/common_scaffold/image/histogram/rtl/img_hist_serial_multiply.v',
         '../../acceleration/stream_atan2/rtl/stream_atan2.sv']

def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def window_oracle(samples,lag):
    # Direct slices and whole-window sums: no ring buffer, finite-width update,
    # helper recurrence, pipeline or RTL state is emulated.
    assert len(samples)==2*lag
    earlier=samples[:lag];later=samples[lag:]
    energy=sum(x*x+y*y for x,y in samples)
    pre=sum(x*u+y*v for (x,y),(u,v) in zip(earlier,later))
    pim=sum(x*v-y*u for (x,y),(u,v) in zip(earlier,later))
    assert 4*(pre*pre+pim*pim)<=energy*energy
    return energy,pre,pim

def mathematical_phase(pre,pim):
    if pre==pim==0:return 0,1
    # Axes have exact binary-turn encodings; other expected angles come from
    # the independent mathematical function, not the reused CORDIC algorithm.
    if pim==0:return (0 if pre>0 else 1<<23),0
    if pre==0:return ((1<<22) if pim>0 else 3<<22),0
    return round(math.atan2(pim,pre)/(2*math.pi)*(1<<24))&0xffffff,0

def prepare(profile):
    dw,lag,cap,tagw,example=(profile[k] for k in ('data_w','lag','max_samples','tag_w','example'))
    cw=2*dw+1+(lag-1).bit_length();mask=(1<<dw)-1
    low=-(1<<(dw-1));high=(1<<(dw-1))-1
    rows=[];commands=records=samples=events=qualifications=0
    counts=dict(valid_batches=0,invalid_commands=0,last_errors=0,exact_threshold_equalities=0,
                energy_floor_equalities=0,largest_runtime_n=0,nonaxis_phase_windows=0)
    rng=random.Random(370037+lag*31+dw)
    def emit(*args):
        assert len(args)<=16
        rows.append([int(x)&((1<<64)-1) for x in args]+[0]*(16-len(args)))
    def tag():return (0xfedc0000+commands+1)&((1<<tagw)-1)
    def result(status,end,start,event_start,qual,event,last,t,energy,pre,pim,timing=True):
        nonlocal records,events,qualifications
        phase,zero=mathematical_phase(pre,pim)
        emit(3 if timing else 5,status,end,start,event_start,qual,event,last,t,energy,pre,pim,phase,zero)
        records+=1;events+=event;qualifications+=qual
        counts['nonaxis_phase_windows']+=pre!=0 and pim!=0
    def batch(words,threshold=49152,hold=1,floor=0,gaps=False,bad_last=None):
        nonlocal commands,samples
        n=len(words);assert 2*lag<=n<=cap and 1<=hold<=64 and 1<=threshold<=65536
        t=tag();emit(1,n,threshold,hold,floor,t);commands+=1
        counts['valid_batches']+=bad_last is None;counts['last_errors']+=bad_last is not None
        counts['largest_runtime_n']=max(counts['largest_runtime_n'],n)
        qualified_starts=[]
        for end,word in enumerate(words):
            assert all(low<=v<=high for v in word)
            packed=(word[0]&mask)|((word[1]&mask)<<dw)
            last=end==n-1
            if bad_last is not None and end==bad_last:last=not last
            emit(2,packed,last);samples+=1
            if bad_last is not None and end==bad_last:
                result(5,end,max(0,end-2*lag+1),0,False,False,True,t,0,0,0,False);break
            if end>=2*lag-1:
                start=end-2*lag+1;energy,pre,pim=window_oracle(words[start:end+1],lag)
                numerator=pre*pre+pim*pim
                qualifies=energy>0 and energy>=floor and (numerator<<18)>=threshold*energy*energy
                counts['exact_threshold_equalities']+=energy>0 and (numerator<<18)==threshold*energy*energy
                counts['energy_floor_equalities']+=energy>0 and energy==floor
                if qualifies:qualified_starts.append(start)
                else:qualified_starts=[]
                event=len(qualified_starts)==hold
                event_start=qualified_starts[0] if event else 0
                result(0 if energy else 7,end,start,event_start,qualifies,event,last,t,energy,pre,pim)
            if gaps and end%11==5:emit(4,3)
    assert window_oracle([(1,0),(1,1)],1)==(3,1,1)
    assert mathematical_phase(0,1)==(1<<22,0) and mathematical_phase(0,-1)==(3<<22,0)
    batch([(0,0)]*(2*lag+3))
    batch([(low,low)]*(2*lag+3),65536,3)
    batch([(high,low)]*(2*lag+2),65536,1)
    batch([(3,4)]*(2*lag+5),65536,3,gaps=True) # CW is intentionally a possible hit.
    batch([(3,4)]*(2*lag),65536,1,50*lag)
    batch([(3,4)]*(2*lag),65536,1,50*lag+1)
    # Unknown length-L content, with +/-quarter-turn change each lag.
    basis=[(rng.choice([-7,-3,1,5]),rng.choice([-5,-1,2,6])) for _ in range(lag)]
    def rotated(word,quarter):
        x,y=word
        return [(x,y),(-y,x),(-x,-y),(y,-x)][quarter%4]
    for sign in [1,-1]:
        batch([rotated(basis[i%lag],sign*(i//lag)) for i in range(2*lag+3)],65536,2)
    batch([(1,0)]*lag+[(3,4)]*lag,1,1) # Independent nonaxis phase, amplitude mismatch.
    batch([(1,0)]*lag+[(-1,0)]*lag,65536,1)
    if lag>=2:
        words=[(1,0),(1,0)]+[(0,0)]*(lag-2)+[(1,0),(0,1)]+[(0,0)]*(lag-2)
        assert window_oracle(words,lag)==(4,1,1)
        for threshold in [32767,32768,32769]:batch(words,threshold,1)
    else:
        # Non-dyadic exact M=8/9, tested immediately below/above its Q16 location.
        for threshold in [58254,58255]:batch([(1,0),(1,1)],threshold,1)
    random_length=2*lag+min(lag+4,17)
    batch([(rng.choice([low,-17,-1,0,1,23,high]),rng.choice([low,-9,0,7,high]))
           for _ in range(random_length)],49152,2,gaps=True)
    if lag<64:
        words=[(3,4)]*(2*lag+3)+[(0,0)]*(2*lag+2)+[(3,4)]*(2*lag+3)
        batch(words,65536,2,gaps=True) # qualification failure, then rearm and reacquire.
    if lag<=3:batch([(2,-1)]*cap,65536,64) # finite profile cap, separate from maximum L.
    # Before data, validate full 32/64-bit commands and precedence.
    for n,threshold,hold,floor,status in [
        (0,0,0,0,1),(2*lag-1,1,1,0,1),(cap+1,1,1,0,1),(0x80000001,1,1,0,1),
        (2*lag,0,1,0,2),(2*lag,65537,1,0,2),(2*lag,0x80000001,1,0,2),
        (2*lag,1,0,0,3),(2*lag,1,65,0,3),(2*lag,1,0x80000001,0,3),
        (2*lag,1,1,1<<cw,4),(2*lag,1,1,1<<63,4)]:
        t=tag();emit(1,n,threshold,hold,floor,t);commands+=1;counts['invalid_commands']+=1
        result(status,0,0,0,False,False,True,t,0,0,0,False)
    batch([(3,4)]*(2*lag+2),bad_last=0)
    batch([(3,4)]*(2*lag),bad_last=2*lag-1)
    batch([(3,4)]*(2*lag+2),bad_last=2*lag) # a prior successful result stays retired.
    assert counts['exact_threshold_equalities']>0 and counts['energy_floor_equalities']>0
    if lag==64:assert counts['largest_runtime_n']<=145
    return ''.join(' '.join('%016x'%x for x in row)+'\n' for row in rows),dict(
        commands=commands,records=records,samples=samples,events=events,qualifications=qualifications,**counts)

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
    if sys.argv[1:]!=['--execute-approved-plan']:
        raise SystemExit('HDL execution requires prior root review and --execute-approved-plan')
    # Even an empty started report directory blocks another attempt. A crash
    # never silently becomes an unrecorded retry under a different timestamp.
    report_root=ROOT/'reports'
    if report_root.exists() and any(report_root.iterdir()):
        raise SystemExit('Existing receipt or started report directory: explicit root recovery required; no rerun')
    plan=json.loads((ROOT/'PRECHECK_PLAN.json').read_text())
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S_%fZ')
    report=ROOT/'reports'/stamp;report.mkdir(parents=True,exist_ok=False)
    build=ROOT/'.build'/stamp;build.mkdir(parents=True,exist_ok=False)
    result=dict(schema='anscore-b37-repeated-half-sync-finite-v1',utc=stamp,status='INCOMPLETE',baseline=plan['baseline'],
        source_sha256={p:sha(ROOT/p) for p in SOURCES},checks=[],profiles=[],preparation_attempts=0,preparation_completed_calls=0,
        preparation_complete=False,suite_complete=False,automatic_retry=False,hardware='HW_UNVERIFIED',
        synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',expected_checks=plan['expected_checks'],
        phase='SOURCE_ARCHIVE',active_child=None,archive_complete=False,
        rerun_guard='refuse_any_existing_report_entry')
    def persist():
        temporary=report/'results.json.tmp'
        with temporary.open('w',encoding='utf-8',newline='\n') as handle:
            json.dump(result,handle,indent=2);handle.write('\n');handle.flush();os.fsync(handle.fileno())
        temporary.replace(report/'results.json')
    # A durable INCOMPLETE receipt exists before any numerical preparation.
    persist()
    # Archive exact source/plan bytes before importing no model and preparing no vectors.
    for p in SOURCES:
        target=report/'sources'/p.replace('../','parent/');target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes((ROOT/p).read_bytes())
    result['archive_complete']=True;persist()
    iv=BIN/'iverilog.exe';vvp=BIN/'vvp.exe';result['tools']={str(p):sha(p) for p in [iv,vvp] if p.is_file()}
    env=dict(os.environ);env['PATH']=str(BIN)+os.pathsep+str(BIN.parent/'lib')+os.pathsep+env.get('PATH','')
    stopped=False
    def run(name,argv,marker=None):
        nonlocal stopped
        if stopped:return False
        result.update(phase='HDL_CHILD',active_child=name);persist()
        rec=execute(name,argv,ROOT,env,report,marker);result['checks'].append(rec)
        result['active_child']=None;stopped=rec['status']!='PASS'
        if stopped:result['status']=rec['status']
        persist();print(name,rec['status'],flush=True);return not stopped
    try:
        for index,config in enumerate(plan['profiles']):
            result['preparation_attempts']+=1
            result.update(phase='NUMERICAL_PREPARATION',active_preparation=index);persist()
            data,counts=prepare(config);path=report/('vectors%d.txt'%index);path.write_text(data,encoding='ascii',newline='\n')
            result['preparation_completed_calls']+=1
            result['profiles'].append(dict(config,vectors_sha256=sha(path),expected_vector_counts=counts))
            result['active_preparation']=None;persist()
        result['preparation_complete']=True;persist()
        if not run('syntax_default',[iv,'-g2012','-Wall','-tnull','-s','repeated_half_sync','-f','files.f']):return 1
        if not run('syntax_example',[iv,'-g2012','-Wall','-tnull','-s','sync12_phase','-f','example/files.f']):return 1
        for index,p in enumerate(result['profiles']):
            image=build/('sim%d.vvp'%index)
            params=['-Ptb_repeated_half_sync.%s=%d'%(k,v) for k,v in zip(('D','L','M','T','EX'),(p['data_w'],p['lag'],p['max_samples'],p['tag_w'],p['example']))]
            if not run('compile%d'%index,[iv,'-g2012','-Wall','-s','tb_repeated_half_sync',*params,'-o',image,'-f','example/files.f','sim/tb_repeated_half_sync.sv']):return 1
            p['artifact']=dict(path=image.relative_to(ROOT).as_posix(),sha256=sha(image),bytes=image.stat().st_size)
            marker=('PASS repeated_half_sync D=%d L=%d M=%d T=%d EX=%d '%(p['data_w'],p['lag'],p['max_samples'],p['tag_w'],p['example'])).encode()
            if not run('sim%d'%index,[vvp,image,'+vectors='+(report/('vectors%d.txt'%index)).as_posix()],marker):return 1
            line=next(x for x in (report/('sim%d.stdout.txt'%index)).read_text().splitlines() if x.startswith(marker.decode()))
            p['observed']={key:int(value) for key,value in re.findall(r'(\w+)=(\d+)',line)}
        result['suite_complete']=True;result['status']='PASS';return 0
    except Exception:
        result.update(status='PREPARATION_OR_RUNNER_FAILED',exception=traceback.format_exc());raise
    finally:
        unchanged=all(sha(ROOT/p)==h for p,h in result['source_sha256'].items())
        archive_unchanged=all(sha(report/'sources'/p.replace('../','parent/'))==h for p,h in result['source_sha256'].items())
        vectors_unchanged=all(sha(report/('vectors%d.txt'%i))==p['vectors_sha256'] for i,p in enumerate(result['profiles']))
        result.update(sources_unchanged=unchanged,archive_unchanged=archive_unchanged,vectors_unchanged=vectors_unchanged)
        # Re-read both the actual plan and its exact archived copy. The final
        # sequence is validated against their actual expected_checks fields.
        final_expected=json.loads((ROOT/'PRECHECK_PLAN.json').read_text())['expected_checks']
        archived_expected=json.loads((report/'sources/PRECHECK_PLAN.json').read_text())['expected_checks']
        sequence_matches=[c['name'] for c in result['checks']]==final_expected==archived_expected==plan['expected_checks']
        result.update(expected_checks_from_final_plan=final_expected,expected_checks_from_archived_plan=archived_expected,
                      check_sequence_matches=sequence_matches)
        if not(unchanged and archive_unchanged and vectors_unchanged):result['status']='SOURCE_CHANGED'
        elif stopped:result['status']=result['checks'][-1]['status']
        if result['status']=='PASS' and not(result['suite_complete'] and result['preparation_complete'] and
            sequence_matches):result['status']='INCOMPLETE'
        result['maturity']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'] if result['status']=='PASS' else ['RTL_CANDIDATE','HW_UNVERIFIED']
        result['phase']='COMPLETE' if result['status']=='PASS' else 'STOPPED';persist()
        print('Evidence:',report.relative_to(ROOT),flush=True)
        if not(unchanged and archive_unchanged and vectors_unchanged):raise RuntimeError('Executed inputs changed')

if __name__=='__main__':sys.exit(main())
