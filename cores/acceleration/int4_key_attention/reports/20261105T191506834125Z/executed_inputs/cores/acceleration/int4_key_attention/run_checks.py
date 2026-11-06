"""SPDX-License-Identifier: Apache-2.0. Finite composed attention checks."""
from pathlib import Path
import datetime,hashlib,json,os,random,shutil,subprocess,sys,time
ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
PROFILES=[(1,1,1),(9,3,8),(64,32,32)]
INPUTS=['rtl/int4_key_attention.sv','sim/tb_int4_key_attention.sv','sim/tb_two_token_attention.sv',
 'run_checks.py','files.f','example/files.f','example/two_token_attention.sv',
 '../int4_weight_matvec/rtl/deps/stream_requantize.v','../int4_weight_matvec/rtl/int4_weight_matvec.sv',
 '../integer_divider/rtl/integer_divider.v','../../system/ip_series/src/ips_softmax_fixed.v']
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def rne(n,d):
    q,r=divmod(n,d);return q+int(2*r>d or(2*r==d and q%2))
def vectors(mc,mv,tw):
    # Integer list/dictionary and rational normalization oracle, no RTL scheduling.
    keys={};meta={};values={};lines=[];kw=(mc+7)//8;vw=(mv+3)//4
    counts=dict(configs=0,queries=0,ordinary_outputs=0,error_outputs=0,resets=0,priority=0)
    rng=random.Random(360000+mc*mv)
    def cfg(op,row=0,word=0,data=0,bias=0,scale=1,shift=0,zero=0):
        error=0
        if op==0:
            if row>=16 or word>=kw:error=1
            else:keys[row,word]=data
        elif op==1:
            if row>=16:error=1
            else:meta[row]=(bias,scale,shift,zero)
        elif op==2:keys.clear();meta.clear();values.clear()
        elif op==3:
            if row>=16 or word>=vw:error=1
            else:values[row,word]=data
        else:error=2
        lines.append(f'0 {op} {row} {word} {data} {bias} {scale} {shift} {zero} {error}\n');counts['configs']+=1
    def query(nt,nc,nv,z=128,x=None,bad_last=None):
        tag=(counts['queries']*17+3)%2**tw
        error=0
        if not(1<=nt<=16 and 1<=nc<=mc and 1<=nv<=mv):error=1
        elif any((r,w)not in values for r in range(nt)for w in range((nv+3)//4)):error=4
        elif any(r not in meta or any((r,w)not in keys for w in range((nc+7)//8))for r in range(nt)):error=2
        if x is None:x=[]if error else[rng.randrange(256)for _ in range(nc)]
        assert len(x)==(0 if error else nc)
        marks=[int(i==nc-1)for i in range(len(x))]
        if bad_last is not None and not error:
            marks[bad_last]^=1;x=x[:bad_last+1];marks=marks[:bad_last+1];error=3
        outputs=[];score_clip=score_inexact=prob_clip=psum=0
        if not error:
            scores=[]
            for r in range(nt):
                bias,scale,shift,zero=meta[r];acc=bias
                for i,byte in enumerate(x):
                    weight=(keys[r,i//8]>>(4*(i%8)))&15
                    if weight>=8:weight-=16
                    acc+=(byte-z)*weight
                scaled=acc*scale;score=rne(scaled,1<<shift)+zero
                score_clip|=int(not -128<=score<=127);score_inexact|=int(scaled%(1<<shift)!=0)
                scores.append(max(-128,min(127,score)))
            exp=[255,155,94,57,35,21,13,8,5,3,2,1,1,0,0,0]
            reciprocal=[510,170,102,72,56,46,39,34,30,26,24,22,20,18,17,16]
            exponents=[exp[min(15,max(scores)-s)]for s in scores];rec=reciprocal[sum(exponents)//256]
            raw=[e*rec//256 for e in exponents];probs=[min(255,p)for p in raw]
            prob_clip=int(any(p>255 for p in raw));psum=sum(probs);assert psum>0
            for j in range(nv):
                v=[((values[r,j//4]>>(8*(j%4)))&255)for r in range(nt)]
                v=[value-256 if value>=128 else value for value in v]
                data=rne(sum(p*value for p,value in zip(probs,v)),psum);assert -128<=data<=127
                outputs.append((data,j,int(j==nv-1),0,score_clip,score_inexact,prob_clip,psum,tag))
            counts['ordinary_outputs']+=len(outputs)
        else:outputs=[(0,0,1,error,0,0,0,0,tag)];counts['error_outputs']+=1
        lines.append(f'1 {nt} {nc} {nv} {z} {tag} {len(x)} {len(outputs)}\n')
        lines.extend(f'{byte} {mark}\n'for byte,mark in zip(x,marks));lines.extend(' '.join(map(str,o))+'\n'for o in outputs)
        counts['queries']+=1
    def setup():
        for r in range(16):
            for w in range(kw):cfg(0,r,w,sum(((r*3+(w*8+i)*5+8)%16)<<(i*4)for i in range(8)))
            cfg(1,r,bias=r*3-20,scale=r+1,shift=5,zero=r-8)
            for w in range(vw):cfg(3,r,w,sum(((r*17+(w*4+i)*31+128)%256)<<(i*8)for i in range(4)))
    for nt,nc,nv in[(0,1,1),(17,1,1),(1,0,1),(1,mc+1,1),(1,1,0),(1,1,mv+1),(65535,65535,65535)]:query(nt,nc,nv)
    query(1,1,1);cfg(3,0,0,0x807f00ff);query(1,1,1);cfg(0,0,0,0);query(1,1,1)
    cfg(1,0);query(1,1,1,0,[255]);query(1,1,1,255,[0])
    for op,row,word in[(0,16,0),(0,0,kw),(1,16,0),(3,16,0),(3,0,vw),(4,0,0),(7,0,0)]:cfg(op,row,word)
    setup();query(16,mc,mv,123);query(3,min(mc,7),mv,0);query(1,mc,1,255)
    query(16,mc,mv,128,[128]*mc)
    query(2,mc,mv,bad_last=0);query(2,mc,mv,bad_last=mc-1)
    # All equal scores -> equal approximate weights; RNE signed half ties.
    cfg(1,0,scale=0);cfg(1,1,scale=0)
    for a,b in[(0,1),(1,2),(-1,0),(-2,-1),(-128,-128),(127,127),(-128,127)]:
        for r,value in enumerate((a,b)):
            for w in range(vw):cfg(3,r,w,sum((value&255)<<(i*8)for i in range(4)))
        query(2,mc,mv)
    cfg(1,0,bias=2**31-1,scale=65535,zero=-128);cfg(1,1,bias=-2**31,scale=65535,shift=31,zero=127)
    query(2,mc,mv);query(1,mc,mv)
    cfg(2);query(1,1,1)
    for phase in range(5):
        setup();lines.append(f'2 {phase}\n');counts['resets']+=1;keys.clear();meta.clear();values.clear();query(1,1,1)
    setup();cfg(1,0,scale=0);lines.append('3\n');counts['priority']+=1;values[0,0]=38;query(1,1,1,128,[128])
    return ''.join(lines),counts

def main():
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    out=ROOT/'reports'/stamp;out.mkdir(parents=True);archive=out/'executed_inputs';archive.mkdir()
    work=ROOT/'.work'/stamp;work.mkdir(parents=True)
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite';suffix='.exe'if os.name=='nt'else''
    tools={n:suite/'bin'/(n+suffix)for n in['iverilog','vvp']}
    env=dict(os.environ);env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    report=dict(schema='anscore-b36-finite-checks-v1',status='INCOMPLETE',checks=[],profiles=[],source_sha256={},archived_sources={},tools={},hard_seconds_per_child=20,
        synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',hardware='HW_UNVERIFIED')
    stopped=False
    def save():(out/'results.json').write_bytes((json.dumps(report,indent=2)+'\n').encode())
    save()
    try:
        for name in INPUTS:
            source=(ROOT/name).resolve();target=archive/source.relative_to(REPO);target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(source,target);report['source_sha256'][name]=digest(target);report['archived_sources'][name]=target.relative_to(ROOT).as_posix()
        for name,path in tools.items():report['tools'][name]=dict(path=str(path),sha256=digest(path))
        for c,v,t in PROFILES:
            data,counts=vectors(c,v,t);label=f'c{c}_v{v}_t{t}';file=out/(label+'.txt');file.write_bytes(data.encode('ascii'))
            report['profiles'].append(dict(label=label,cols=c,values=v,tag_w=t,counts=counts,vector=file.name,vector_sha256=digest(file)))
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
        marker=b'PASS two_token_attention'if name=='sim_example'else b'PASS int4_key_attention'
        if name.startswith('sim_')and rec['status']=='PASS'and(marker not in stdout or b'$finish'not in stdout):rec['status']='FAIL_NO_MARKER'
        rec.update(seconds=round(time.monotonic()-start,4),stdout_sha256=hashlib.sha256(stdout).hexdigest(),stderr_sha256=hashlib.sha256(stderr).hexdigest())
        (out/(name+'.stdout.txt')).write_bytes(stdout);(out/(name+'.stderr.txt')).write_bytes(stderr)
        if '-o'in rec['argv']:
            image=Path(rec['argv'][rec['argv'].index('-o')+1])
            if image.is_file():rec.update(image=str(image.relative_to(ROOT)),image_sha256=digest(image))
        report['checks'].append(rec);save();print(name,rec['status'],flush=True);stopped=rec['status']!='PASS';return not stopped
    run('syntax_default',[tools['iverilog'],'-g2012','-Wall','-tnull','-s','int4_key_attention','-f','files.f'])
    run('syntax_limit',[tools['iverilog'],'-g2012','-Wall','-tnull','-s','int4_key_attention','-Pint4_key_attention.MAX_COLS=1024','-Pint4_key_attention.MAX_VALUES=32','-Pint4_key_attention.TAG_W=32','-f','files.f'])
    run('syntax_example',[tools['iverilog'],'-g2012','-Wall','-tnull','-s','two_token_attention','-f','example/files.f'])
    for profile in report['profiles']:
        if stopped:break
        label=profile['label'];image=work/(label+'.vvp')
        if run('compile_'+label,[tools['iverilog'],'-g2012','-Wall','-s','tb_int4_key_attention',f'-Ptb_int4_key_attention.C={profile["cols"]}',f'-Ptb_int4_key_attention.V={profile["values"]}',f'-Ptb_int4_key_attention.T={profile["tag_w"]}','-o',image,'-f','files.f','sim/tb_int4_key_attention.sv']):run('sim_'+label,[tools['vvp'],image,'+vectors='+(out/profile['vector']).as_posix()])
    image=work/'example.vvp'
    if run('compile_example',[tools['iverilog'],'-g2012','-Wall','-s','tb_two_token_attention','-o',image,'-f','example/files.f','sim/tb_two_token_attention.sv']):run('sim_example',[tools['vvp'],image])
    unchanged=all(digest(ROOT/name)==sha for name,sha in report['source_sha256'].items())
    ok=not stopped and unchanged and len(report['checks'])==11
    report.update(sources_unchanged=unchanged,status='PASS'if ok else'INCOMPLETE')
    report['maturity']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED']if ok else['RTL_CANDIDATE','HW_UNVERIFIED']
    save();print(out.relative_to(ROOT).as_posix(),flush=True);return 0 if ok else 1
if __name__=='__main__':sys.exit(main())
