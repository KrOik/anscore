"""SPDX-License-Identifier: Apache-2.0. Single finite, fail-stop B37 invocation."""
from pathlib import Path
import datetime,hashlib,json,os,random,shutil,subprocess,sys,time
from reference_model import normalize,input_quantize
ROOT=Path(__file__).resolve().parent;REPO=ROOT.parents[2]
PROFILES=[(1,0,1,0),(9,12,8,0),(256,16,32,0),(8,12,8,1)]
INPUTS=['rtl/signed8_layer_norm.sv','example/quantized_layer_norm.sv',
    'sim/tb_signed8_layer_norm.sv','reference_model.py','run_checks.py','files.f','example/files.f',
    '../../system/common_scaffold/image/histogram/rtl/img_hist_serial_multiply.v',
    '../../signal_processing/dsp_isp_library/infra/fixedpoint/rtl/sqrt_unit.sv',
    '../../signal_processing/dsp_isp_library/infra/fixedpoint/rtl/recip_div.sv',
    '../int4_weight_matvec/rtl/deps/stream_requantize.v']
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()

def vectors(n,f,t,ex):
    rng=random.Random(0x37b0+n+f+ex);affine={};lines=[]
    counts=dict(configs=0,queries=0,ordinary_outputs=0,error_markers=0,live_resets=0,priority_flows=0)
    def cfg(op,index=0,gamma=1,beta=0,shift=None):
        if shift is None:shift=f
        error=0
        if op==0:
            if index>=n:error=1
            else:affine[index]=(gamma,beta,shift)
        elif op==1:affine.clear()
        else:error=2
        lines.append(f'0 {op} {index} {gamma} {beta} {shift} {error}\n');counts['configs']+=1
    def query(length,epsilon=1,samples=None,bad=None,pre=0):
        tag=(counts['queries']*31+5)%(1<<t);error=0
        if not 1<=length<=n:error=1
        elif any(i not in affine for i in range(length)):error=2
        samples=[] if error else (samples if samples is not None else [rng.randrange(-128,128)for _ in range(length)])
        assert len(samples)==(0 if error else length)
        marks=[int(i==length-1)for i in range(len(samples))]
        if bad is not None and not error:
            marks[bad]^=1;samples=samples[:bad+1];marks=marks[:bad+1];error=3
        ic=ii=0;out=[]
        if not error:
            x,ic,ii=input_quantize(samples,pre)if ex else(samples,0,0)
            ys=normalize(x,epsilon,[affine[i]for i in range(length)],f)
            for i,(y,clip,inexact,degen)in enumerate(ys):
                out.append((y,i,int(i==length-1),0,clip,inexact,degen,tag,ic,ii))
            counts['ordinary_outputs']+=len(out)
        else:
            # Errors are whole vectors before output; input quantization flags,
            # if any malformed inputs were transferred, are retained by adapter.
            if ex and samples:_,ic,ii=input_quantize(samples,pre)
            out=[(0,0,1,error,0,0,0,tag,ic,ii)];counts['error_markers']+=1
        lines.append(f'1 {length} {epsilon} {tag} {pre} {len(samples)} {len(out)}\n')
        lines.extend(f'{x} {mark}\n'for x,mark in zip(samples,marks))
        lines.extend(' '.join(map(str,y))+'\n'for y in out);counts['queries']+=1
    def setup(limit=None):
        limit=n if limit is None else limit
        gs=[1,-1,3,-3,32767,-32768,251,-17]
        for i in range(limit):
            cfg(0,i,gs[i%len(gs)],((i*19)%259)-129,[0,f,min(31,f+1),31][i%4])
    query(0);query(n+1);query(65535);query(1)
    cfg(0,n);cfg(2);cfg(3);cfg(1);query(n)
    setup()
    for length in sorted({1,min(2,n),min(7,n),n}):
        for epsilon in [0,1,65535]:query(length,epsilon)
    for epsilon in [0,1,65535]:
        query(n,epsilon,[127]*n);query(n,epsilon,[-128]*n)
    query(n,0,[-128 if i%2==0 else 127 for i in range(n)])
    if n>=2:
        cfg(0,0,1,1,f+1);cfg(0,1,3,1,f+1);query(2,0,[-1,1])
        cfg(0,0,-3,-1,f+1);cfg(0,1,-1,-1,f+1);query(2,0,[-1,1])
        if f<=12:
            cfg(0,0,1,(1<<f)-5,0);cfg(0,1,1,5-(1<<f),0);query(2,0,[-1,1])
        cfg(0,0,32767,32767,0);cfg(0,1,-32768,-32768,0);query(2,0,[-128,127])
        cfg(0,0,-32768,32767,31);cfg(0,1,32767,-32768,31);query(2,65535,[-128,127])
    setup()
    for j in range(8 if n<32 else 3):
        length=min(n,1+j*3);x=[rng.randrange(-80,81)for _ in range(length)]
        query(length,j%3,x);query(length,j%3,[v+11 for v in x])
    k=min(3,n);query(k,1,bad=0);query(k,1,bad=k-1)
    if ex:
        for pre in [0,1,8,31]:
            query(n,1,[[-2**31,2**31-1,-257,257,-3,3,-1,1][i%8]for i in range(n)],pre=pre)
    cfg(1);query(1)
    for phase in [0,1,2,3,4,5,7]+([6]if ex else[]):
        setup(min(n,3));lines.append(f'2 {phase}\n');counts['live_resets']+=1;affine.clear();query(1)
    cfg(0,0,1,7,f);lines.append('3\n');counts['priority_flows']+=1;affine[0]=(1,29,f)
    query(1,1,[5]);return ''.join(lines),counts

def main():
    # Existing receipts are immutable: invoking twice requires a new task decision.
    if list((ROOT/'reports').glob('*/results.json')):
        print('REFUSED: existing finite receipt; no automatic rerun',flush=True);return 2
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    out=ROOT/'reports'/stamp;out.mkdir(parents=True);archive=out/'executed_inputs';archive.mkdir()
    work=ROOT/'.work'/stamp;work.mkdir(parents=True)
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite';suffix='.exe'if os.name=='nt'else''
    tools={n:suite/'bin'/(n+suffix)for n in ['iverilog','vvp']}
    env=dict(os.environ);env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    report=dict(schema='anscore-b37-finite-checks-v1',status='INCOMPLETE',checks=[],profiles=[],source_sha256={},archived_sources={},tools={},hard_seconds_per_child=20,automatic_retry=False,
        synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',hardware='HW_UNVERIFIED')
    stopped=False
    def save():(out/'results.json').write_bytes((json.dumps(report,indent=2)+'\n').encode())
    save()
    try:
        plan=json.loads((ROOT/'FINITE_PLAN.json').read_bytes())
        if plan['source_review']!='NO_BLOCKER_A':raise ValueError('source review must close before HDL')
        if set(plan['executable_sources'])!=set(INPUTS):raise ValueError('planned input set mismatch')
        if any(digest(ROOT/n)!=h for n,h in plan['executable_sources'].items()):raise ValueError('planned source changed')
        shutil.copyfile(ROOT/'FINITE_PLAN.json',out/'plan.json');report['plan_sha256']=digest(out/'plan.json')
        for name in INPUTS:
            source=(ROOT/name).resolve();target=archive/source.relative_to(REPO);target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(source,target);report['source_sha256'][name]=digest(target);report['archived_sources'][name]=target.relative_to(ROOT).as_posix()
        for name,path in tools.items():report['tools'][name]=dict(path=str(path),sha256=digest(path))
        for n,f,t,ex in PROFILES:
            data,counts=vectors(n,f,t,ex);label=f'n{n}_f{f}_t{t}_e{ex}';file=out/(label+'.txt');file.write_bytes(data.encode('ascii'))
            report['profiles'].append(dict(label=label,max_len=n,frac=f,tag_w=t,example=ex,counts=counts,vector=file.name,vector_sha256=digest(file)))
            if digest(file)!=plan['profiles'][len(report['profiles'])-1]['vector_sha256']:raise ValueError('planned vector changed')
        report['preparation_complete']=True
    except Exception as exc:report.update(status='NOT_RUN',preparation_error=repr(exc));save();return 1
    save()
    def run(name,args):
        nonlocal stopped
        if stopped:return False
        rec=dict(name=name,argv=list(map(str,args)),cwd=str(ROOT));start=time.monotonic();stdout=stderr=b''
        try:
            p=subprocess.Popen(rec['argv'],cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,start_new_session=os.name!='nt')
            try:
                stdout,stderr=p.communicate(timeout=20);rec.update(status='PASS'if p.returncode==0 else'FAIL',returncode=p.returncode)
            except subprocess.TimeoutExpired as exc:
                stdout,stderr=exc.stdout or b'',exc.stderr or b'';rec.update(status='TIMEOUT',returncode=None)
                try:
                    if os.name=='nt':subprocess.run(['taskkill','/PID',str(p.pid),'/T','/F'],capture_output=True,timeout=5)
                    else:
                        import signal
                        os.killpg(p.pid,signal.SIGKILL)
                except(OSError,subprocess.SubprocessError)as exc:stderr+=str(exc).encode()
                try:
                    if p.poll()is None:p.kill()
                    stdout,stderr=p.communicate(timeout=2)
                except(OSError,subprocess.SubprocessError)as exc:stderr+=str(exc).encode()
        except OSError as exc:rec.update(status='NOT_RUN',returncode=None);stderr=str(exc).encode()
        if name.startswith('sim_')and rec['status']=='PASS'and(b'PASS signed8_layer_norm'not in stdout or b'$finish'not in stdout):rec['status']='FAIL_NO_MARKER'
        rec.update(seconds=round(time.monotonic()-start,4),stdout_sha256=hashlib.sha256(stdout).hexdigest(),stderr_sha256=hashlib.sha256(stderr).hexdigest())
        (out/(name+'.stdout.txt')).write_bytes(stdout);(out/(name+'.stderr.txt')).write_bytes(stderr)
        if '-o'in rec['argv']:
            image=Path(rec['argv'][rec['argv'].index('-o')+1])
            if image.is_file():rec.update(image=str(image.relative_to(ROOT)),image_sha256=digest(image))
        report['checks'].append(rec);save();print(name,rec['status'],flush=True);stopped=rec['status']!='PASS';return not stopped
    run('syntax_default',[tools['iverilog'],'-g2012','-Wall','-tnull','-s','signed8_layer_norm','-f','files.f'])
    run('syntax_limit',[tools['iverilog'],'-g2012','-Wall','-tnull','-s','signed8_layer_norm','-Psigned8_layer_norm.MAX_LEN=256','-Psigned8_layer_norm.FRAC=16','-Psigned8_layer_norm.TAG_W=32','-f','files.f'])
    run('syntax_example',[tools['iverilog'],'-g2012','-Wall','-tnull','-s','quantized_layer_norm','-f','example/files.f'])
    for profile in report['profiles']:
        if stopped:break
        label=profile['label'];image=work/(label+'.vvp')
        args=[tools['iverilog'],'-g2012','-Wall','-s','tb_signed8_layer_norm',f'-Ptb_signed8_layer_norm.N={profile["max_len"]}',f'-Ptb_signed8_layer_norm.F={profile["frac"]}',f'-Ptb_signed8_layer_norm.T={profile["tag_w"]}',f'-Ptb_signed8_layer_norm.EX={profile["example"]}','-o',image,'-f','example/files.f','sim/tb_signed8_layer_norm.sv']
        if run('compile_'+label,args):run('sim_'+label,[tools['vvp'],image,'+vectors='+(out/profile['vector']).as_posix()])
    unchanged=all(digest(ROOT/name)==h for name,h in report['source_sha256'].items())
    vectors_unchanged=all(digest(out/p['vector'])==p['vector_sha256']for p in report['profiles'])
    archive_unchanged=all(digest(ROOT/report['archived_sources'][n])==h for n,h in report['source_sha256'].items())
    plan_unchanged=digest(ROOT/'FINITE_PLAN.json')==report['plan_sha256']==digest(out/'plan.json')
    ok=not stopped and unchanged and vectors_unchanged and archive_unchanged and plan_unchanged and len(report['checks'])==11
    report.update(sources_unchanged=unchanged,vectors_unchanged=vectors_unchanged,archive_unchanged=archive_unchanged,plan_unchanged=plan_unchanged,suite_complete=ok,status='PASS'if ok else'INCOMPLETE')
    report['maturity']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED']if ok else['RTL_CANDIDATE','HW_UNVERIFIED']
    save();print(out.relative_to(ROOT).as_posix(),flush=True);return 0 if ok else 1
if __name__=='__main__':sys.exit(main())
