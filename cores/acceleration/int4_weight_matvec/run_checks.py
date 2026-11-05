"""Finite source qualification only; no synthesis, routing, STA or hardware."""
from pathlib import Path
import datetime, hashlib, json, os, random, shutil, subprocess, sys, time

ROOT=Path(__file__).resolve().parent
REPO=ROOT.parents[2]
PROFILES=[(1,1,1),(3,9,8),(8,64,16)]
INPUTS=['rtl/int4_weight_matvec.sv','rtl/deps/stream_requantize.v',
        'sim/tb_int4_weight_matvec.sv','example/int4_dense_layer.sv',
        'files.f','example/files.f','run_checks.py']
def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()

def vectors(nr,nc,tw):
    rng=random.Random(330000+nr*nc)
    words=(nc+7)//8
    weights={};meta={};records=[];counts=dict(frames=0,outputs=0,configs=0,live_resets=0)
    def cfg(op,row=0,word=0,data=0,bias=0,scale=1,shift=0,zero=0):
        error=0
        if op==0:
            if row>=nr or word>=words:error=1
            else:weights[row,word]=data
        elif op==1:
            if row>=nr:error=1
            else:meta[row]=(bias,scale,shift,zero)
        elif op==2:weights.clear();meta.clear()
        else:error=2
        records.append(f'0 {op} {row} {word} {data} {bias} {scale} {shift} {zero} {error}\n')
        counts['configs']+=1
    def frame(rows,cols,z=0,values=None,lasts=None):
        tag=counts['frames']%2**tw
        if not (1<=rows<=nr and 1<=cols<=nc):err=1
        elif any(r not in meta or any((r,w) not in weights for w in range((cols+7)//8)) for r in range(rows)):err=2
        else:err=0
        if values is None:values=[] if err else [rng.randrange(256) for _ in range(cols)]
        if lasts is None:lasts=[int(i==cols-1) for i in range(len(values))]
        if not err and any(bool(last)!=(i==cols-1) for i,last in enumerate(lasts)):err=3
        outs=[]
        if err:outs=[(0,0,1,0,0,err,tag)]
        else:
            for r in range(rows):
                bias,scale,shift,zero=meta[r]
                acc=bias
                for col,x in enumerate(values):
                    w=(weights[r,col//8]>>(4*(col%8)))&15
                    if w>=8:w-=16
                    acc+=(x-z)*w
                p=acc*scale
                q,rem=divmod(p,2**shift)
                q+=int(2*rem>2**shift or (2*rem==2**shift and q%2))
                value=q+zero
                outs.append((max(-128,min(127,value)),r,int(r==rows-1),int(not -128<=value<=127),int(rem!=0),0,tag))
        records.append(f'1 {rows} {cols} {z} {tag} {len(values)} {len(outs)}\n')
        records.extend(f'{x} {last}\n' for x,last in zip(values,lasts))
        records.extend(' '.join(map(str,item))+'\n' for item in outs)
        counts['frames']+=1;counts['outputs']+=len(outs)
    def setup():
        for r in range(nr):
            for w in range(words):
                # Full nibble range and packed-word boundaries; padding is deliberately nonzero.
                data=sum(((r*7+w*3+i)%16)<<(4*i) for i in range(8))
                cfg(0,r,w,data)
            cfg(1,r,bias=r*13-17,scale=r+1,shift=3+r%5,zero=r-2)
    frame(0,1);frame(nr+1,nc);frame(nr,0);frame(nr,nc+1);frame(65535,65535)
    frame(nr,nc)
    cfg(0,65535);cfg(0,0,65535);cfg(1,65535);cfg(3)
    # Metadata without a complete weight image is rejected before vector loading.
    cfg(1,0);frame(1,nc)
    if words>1:
        cfg(0,0,0,0x87654321);frame(1,nc);frame(1,1)
    setup()
    frame(nr,nc,123,[(i*53)%256 for i in range(nc)])
    for cols in sorted(set([1,min(7,nc),min(8,nc),min(9,nc),nc])):
        frame(nr,cols,255);frame(1,cols,0)
    if nc>1:frame(nr,nc,values=[19],lasts=[1])
    frame(nr,nc,values=[33]*nc,lasts=[0]*nc)
    # Ties followed by odd zero offsets distinguish rounding/offset ordering.
    for bias,scale,shift,zero in [(1,1,1,1),(3,1,1,1),(-1,1,1,-1),(-3,1,1,-1),
        (253,1,1,1),(-257,1,1,1),(255,1,1,-1),(2**31-1,65535,0,-128),
        (-2**31,65535,0,127),(2**31-1,65535,31,-128),(-2**31,65535,31,127),
        (77,0,31,-128),(0,1,0,127),(12345,37,17,13)]:
        cfg(1,0,bias=bias,scale=scale,shift=shift,zero=zero)
        frame(1,nc,91,[91]*nc)
    for _ in range(20):
        r=rng.randrange(nr)
        cfg(1,r,bias=rng.randrange(-3000,3001),scale=rng.randrange(1,512),shift=rng.randrange(1,20),zero=rng.randrange(-128,128))
        if _%3==0:cfg(0,r,rng.randrange(words),rng.getrandbits(32))
        frame(rng.randrange(1,nr+1),rng.randrange(1,nc+1),rng.randrange(256))
    cfg(2);frame(nr,nc)
    for phase in range(4):
        setup();records.append(f'3 {phase}\n');counts['live_resets']+=1
        weights.clear();meta.clear();frame(nr,nc)
    setup();frame(nr,nc,128)
    records.append('4\n')
    return ''.join(records),counts

def main():
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    out=ROOT/'reports'/stamp;out.mkdir(parents=True)
    archive=out/'executed_inputs';archive.mkdir()
    work=ROOT/'.work'/stamp;work.mkdir(parents=True)
    suite=REPO/'tools/oss-cad-suite/oss-cad-suite'
    suffix='.exe' if os.name=='nt' else ''
    tools={name:suite/'bin'/(name+suffix) for name in ['iverilog','vvp']}
    env=dict(os.environ);env['PATH']=os.pathsep.join([str(suite/'bin'),str(suite/'lib'),env.get('PATH','')])
    report=dict(schema='anscore-b33-finite-checks-v1',status='INCOMPLETE',checks=[],profiles=[],
      source_sha256={},tools={},hard_seconds_per_child=20,hardware_status='HW_UNVERIFIED',
      synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN')
    stopped=False
    def save():(out/'results.json').write_text(json.dumps(report,indent=2)+'\n',encoding='utf-8')
    save()
    try:
        for p in INPUTS:
            target=archive/p;target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(ROOT/p,target);report['source_sha256'][p]=digest(target)
        for name,path in tools.items():report['tools'][name]=dict(path=str(path),sha256=digest(path))
        for nr,nc,tw in PROFILES:
            data,counts=vectors(nr,nc,tw);label=f'r{nr}_c{nc}_t{tw}'
            file=out/(label+'.txt');file.write_text(data,encoding='ascii')
            report['profiles'].append(dict(label=label,rows=nr,cols=nc,tag_w=tw,counts=counts,
              vector=file.name,vector_sha256=digest(file)))
    except Exception as exc:
        report.update(status='NOT_RUN',preparation_error=repr(exc));save();return 1
    save()
    def run(name,argv):
        nonlocal stopped
        if stopped:return False
        record=dict(name=name,argv=list(map(str,argv)),cwd=str(ROOT));start=time.monotonic()
        stdout=stderr=b''
        try:
            child=subprocess.Popen(record['argv'],cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
              start_new_session=os.name!='nt')
            try:
                stdout,stderr=child.communicate(timeout=20)
                record.update(status='PASS' if child.returncode==0 else 'FAIL',returncode=child.returncode)
            except subprocess.TimeoutExpired as exc:
                stdout,stderr=exc.stdout or b'',exc.stderr or b'';record.update(status='TIMEOUT',returncode=None)
                try:
                    if os.name=='nt':subprocess.run(['taskkill','/PID',str(child.pid),'/T','/F'],capture_output=True,timeout=5)
                    else:
                        import signal
                        os.killpg(child.pid,signal.SIGKILL)
                except (OSError,subprocess.SubprocessError) as cleanup:stderr+=str(cleanup).encode()
                try:
                    if child.poll() is None:child.kill()
                    stdout,stderr=child.communicate(timeout=2)
                except (OSError,subprocess.SubprocessError) as cleanup:stderr+=str(cleanup).encode()
        except OSError as exc:record.update(status='NOT_RUN',returncode=None);stderr=str(exc).encode()
        if name.startswith('sim_') and record['status']=='PASS' and (b'PASS int4_weight_matvec' not in stdout or b'$finish' not in stdout):record['status']='FAIL_NO_MARKER'
        record.update(seconds=round(time.monotonic()-start,4),stdout_sha256=hashlib.sha256(stdout).hexdigest(),stderr_sha256=hashlib.sha256(stderr).hexdigest())
        (out/(name+'.stdout.txt')).write_bytes(stdout);(out/(name+'.stderr.txt')).write_bytes(stderr)
        if '-o' in record['argv']:
            image=Path(record['argv'][record['argv'].index('-o')+1])
            if image.is_file():record['image']=str(image.relative_to(ROOT));record['image_sha256']=digest(image)
        report['checks'].append(record);save();print(name,record['status'],flush=True)
        if record['status']!='PASS':stopped=True
        return not stopped
    run('syntax_default',[tools['iverilog'],'-g2012','-Wall','-tnull','-s','int4_weight_matvec','-f','files.f'])
    run('syntax_limit',[tools['iverilog'],'-g2012','-Wall','-tnull','-s','int4_weight_matvec','-Pint4_weight_matvec.MAX_ROWS=64','-Pint4_weight_matvec.MAX_COLS=1024','-f','files.f'])
    run('syntax_example',[tools['iverilog'],'-g2012','-Wall','-tnull','-s','int4_dense_layer','-f','example/files.f'])
    for p in report['profiles']:
        if stopped:break
        label=p['label'];image=work/(label+'.vvp')
        if run('compile_'+label,[tools['iverilog'],'-g2012','-Wall','-s','tb_int4_weight_matvec',
            f'-Ptb_int4_weight_matvec.MAX_ROWS={p["rows"]}',f'-Ptb_int4_weight_matvec.MAX_COLS={p["cols"]}',
            f'-Ptb_int4_weight_matvec.TAG_W={p["tag_w"]}','-o',image,'-f','files.f','sim/tb_int4_weight_matvec.sv']):
            run('sim_'+label,[tools['vvp'],image,'+vectors='+(out/p['vector']).as_posix()])
    expected=['syntax_default','syntax_limit','syntax_example']+[kind+p['label'] for p in report['profiles'] for kind in ['compile_','sim_']]
    unchanged=all(digest(ROOT/p)==h for p,h in report['source_sha256'].items())
    ok=not stopped and unchanged and [c['name'] for c in report['checks']]==expected
    report['sources_unchanged']=unchanged
    report['status']=['LINT_PASS','UNIT_SIM_PASS','INTEGRATION_CANDIDATE','HW_UNVERIFIED'] if ok else ['RTL_CANDIDATE','HW_UNVERIFIED']
    save();print(out.relative_to(ROOT).as_posix(),flush=True);return 0 if ok else 1
if __name__=='__main__':sys.exit(main())
