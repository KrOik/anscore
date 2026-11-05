"""Original Apache-2.0 finite fragment-store checks; no synthesis/retry/network."""
from pathlib import Path
import datetime,hashlib,json,os,random,signal,subprocess,sys,time,traceback
ROOT=Path(__file__).resolve().parent
BIN=ROOT.parents[2]/"tools/oss-cad-suite/oss-cad-suite/bin"
IV=BIN/"iverilog.exe";VVP=BIN/"vvp.exe"
SOURCES=["run_tests.py","rtl/fragment_rgb_depth_store.sv","sim/tb_fragment_store.sv","sim/tb_triangle_depth.sv","files.f","example/triangle_depth64.sv","example/files.f","../triangle_rgb_raster/rtl/triangle_rgb_raster.sv"]
PROFILES=[(1,1,1,1),(7,5,8,1),(128,128,32,0)]
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()

def execute(name,argv,cwd,env,report,marker=None):
    argv=list(map(str,argv));start=time.monotonic();code=None;out=err=b"";cleanup=[];reason=None
    options={"creationflags":subprocess.CREATE_NO_WINDOW} if os.name=="nt" else {"start_new_session":True}
    try: child=subprocess.Popen(argv,cwd=cwd,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**options)
    except OSError as exc: status="NOT_RUN";err=(repr(exc)+"\n").encode()
    else:
        try:
            out,err=child.communicate(timeout=20);code=child.returncode;status="PASS" if code==0 else "FAIL"
        except subprocess.TimeoutExpired as exc:
            status="TIMEOUT";out=exc.stdout or b"";err=exc.stderr or b""
            if os.name=="nt":
                kill=[str(Path(os.environ.get("SystemRoot",r"C:\Windows"))/"System32/taskkill.exe"),"/PID",str(child.pid),"/T","/F"]
                try:
                    k=subprocess.run(kill,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=5,check=False,creationflags=subprocess.CREATE_NO_WINDOW)
                    cleanup.append(dict(argv=kill,returncode=k.returncode,stdout=k.stdout.decode(errors="replace"),stderr=k.stderr.decode(errors="replace")))
                except (OSError,subprocess.TimeoutExpired) as exc: cleanup.append(dict(action="tree_kill",error=repr(exc)))
            else:
                try: os.killpg(child.pid,signal.SIGKILL)
                except OSError as exc: cleanup.append(dict(action="group_kill",error=repr(exc)))
            try:
                if child.poll() is None: child.kill()
            except OSError as exc: cleanup.append(dict(action="parent_kill",error=repr(exc)))
            try: out,err=child.communicate(timeout=2)
            except subprocess.TimeoutExpired as exc:
                out=exc.stdout or out;err=exc.stderr or err;cleanup.append(dict(action="drain",error=repr(exc)))
            except OSError as exc: cleanup.append(dict(action="drain",error=repr(exc)))
            code=child.poll()
    if status=="PASS" and name.startswith("sim_") and (marker is None or not any(line.startswith(marker) for line in out.splitlines())):
        status="FAIL";reason="required exact simulation completion prefix absent"
    (report/(name+".stdout.txt")).write_bytes(out);(report/(name+".stderr.txt")).write_bytes(err)
    return dict(name=name,argv=argv,cwd=str(cwd),status=status,returncode=code,reason=reason,
                marker=marker.decode() if marker else None,execution_deadline_seconds=20,cleanup_budget_seconds=7,
                cleanup=cleanup,seconds=round(time.monotonic()-start,3),stdout_sha256=hashlib.sha256(out).hexdigest(),stderr_sha256=hashlib.sha256(err).hexdigest())


def pack(rgb):return (rgb[0]<<16)|(rgb[1]<<8)|rgb[2]
def channels(rgb):return [(rgb>>16)&255,(rgb>>8)&255,rgb&255]
def fragment(x,y,z=100,rgb=0xabcdef,a=255,func=0,zw=1,cw=7):
    return (x,y,z,rgb,a,func,zw,cw)
def fixtures(w,h):
    rng=random.Random(350035+w*1000+h)
    f=fragment;clear=(65535<<24)|0x102030
    cases=[(clear,[f(0,0)]),
        (clear,[f(w-1,h-1,z=1),f(w,h-1),f(w-1,h),f(65535,0),f(0,65535),f(65535,65535)]),
        (clear,[f(0,0,z=z,rgb=c,a=a,func=fn,zw=zw,cw=cw) for z,c,a,fn,zw,cw in [
            (65535,0xff0000,255,1,1,7),(65535,0x0000ff,255,2,1,7),
            (100,0xff0000,255,1,1,7),(100,0x00ff00,255,1,1,7),
            (100,0x00ff00,255,2,1,7),(0,0xffffff,255,3,1,7),
            (65535,0xffffff,255,0,0,0),(50,0xffffff,0,1,1,7),(60,0,255,1,1,7)]]),
        (clear,[f(0,0,z=65535-i,rgb=0xfedcba,a=127+i,func=0,zw=i%2,cw=i) for i in range(8)]),
        (0,[f(w-1,h-1,z=65535,rgb=0xffffff,a=255),f(0,0,z=0,rgb=0,a=0,zw=0)]),
        (clear,[f(i%w,(i//w)%h,z=i*257%65536,rgb=(i*0x12345)&0xffffff,a=i%256,func=i%4,zw=i%2,cw=i%8) for i in range(min(w*h*2,257))]),
        (0x123456789a,[f(rng.randrange(w+1),rng.randrange(h+1),z=rng.randrange(65536),rgb=rng.randrange(1<<24),a=rng.randrange(256),func=rng.randrange(4),zw=rng.randrange(2),cw=rng.randrange(8)) for _ in range(128)]),
        (0xabcd2468ac,[])]
    if w==h==1:
        cases += [(clear,[f(0,0,z=1234,rgb=0xe14c29,a=a,func=0,zw=1,cw=7)]) for a in range(256)]
    if w==128 and h==128:
        cases=[cases[0],cases[1],cases[6]]
    return cases

def model(clear,frags,w,h):
    # Ordinary per-coordinate dictionary; direct integer weighted mean.
    canvas={(x,y):clear for y in range(h) for x in range(w)};passed=oob=0
    for x,y,z,rgb,a,func,zw,cw in frags:
        if x>=w or y>=h:oob+=1;continue
        old=canvas[x,y];dz=old>>24
        if not (func==0 or func==1 and z<dz or func==2 and z<=dz):continue
        passed+=1;old_rgb=channels(old&0xffffff);src=channels(rgb);out=[]
        for i,(s,d) in enumerate(zip(src,old_rgb)):
            out.append((s*a+d*(255-a)+127)//255 if cw&(1<<(2-i)) else d)
        canvas[x,y]=((z if zw else dz)<<24)|pack(out)
    return [canvas[x,y] for y in range(h) for x in range(w)],(len(frags)<<64)|(passed<<32)|oob

def write_hex(path,values,digits):path.write_text(''.join(f'{v:0{digits}x}\n' for v in values),encoding='ascii',newline='\n')

def prepare(report):
    assert all(((n+127+1+((n+127)>>8))>>8)==(n+127)//255 for n in range(65026))
    assert all((x*a+x*(255-a)+127)//255==x for x in [0,1,127,128,254,255] for a in range(256))
    profiles=[]
    for w,h,t,protocol in PROFILES:
        name=f'{w}x{h}_t{t}';dest=report/name;dest.mkdir()
        clears=[];frags=[];sizes=[];golden=[];stats=[]
        for clear,fragments in fixtures(w,h):
            result,statistics=model(clear,fragments,w,h)
            clears.append(clear);sizes.append(len(fragments));golden.extend(result);stats.append(statistics)
            for x,y,z,rgb,a,func,zw,cw in fragments:frags.append(x|(y<<16)|(z<<32)|(rgb<<48)|(a<<72)|(func<<80)|(zw<<82)|(cw<<83))
        values={'clears.hex':(clears,10),'fragments.hex':(frags,22),'sizes.hex':(sizes,4),'golden.hex':(golden,10),'stats.hex':(stats,24)}
        for n,(v,d) in values.items():write_hex(dest/n,v,d)
        profiles.append(dict(name=name,w=w,h=h,tag=t,protocol=protocol,cases=len(clears),fragments=len(frags),checked=w*h*(len(clears)+(9 if protocol else 0)),completions=len(clears)+(8 if protocol else 0),resets=9 if protocol else 1,vectors_sha256={n:sha(dest/n) for n in values}))
    # Integration coverage independently evaluates B33 top-left sample positions
    # with direct determinants, then models four overlapping constant triangles.
    dest=report/'integration';dest.mkdir();frame=[(65535<<24)|0x102030]*4096
    def edge(a,b,p):return (b[0]-a[0])*(p[1]-a[1])-(b[1]-a[1])*(p[0]-a[0])
    v=[(0,0),(8,0),(0,8)];covered=[]
    for y in range(64):
        for x in range(64):
            q=(2*x+1,2*y+1);pairs=[(v[1],v[2]),(v[2],v[0]),(v[0],v[1])]
            if all(edge(a,b,q)>0 or edge(a,b,q)==0 and (b[1]<a[1] or b[1]==a[1] and b[0]>a[0]) for a,b in pairs):covered.append((x,y))
    assert len(covered)==6
    fs=[]
    for z,c,a,fn,zw,cw in [(100,0xff0000,255,1,1,7),(200,0x0000ff,255,1,1,7),(50,0x00ff00,128,1,0,7),(100,0xffffff,255,2,0,4)]:
        fs.extend(fragment(x,y,z,c,a,fn,zw,cw) for x,y in covered)
    result,stats=model((65535<<24)|0x102030,fs,64,64)
    assert stats==(24<<64)|(18<<32)
    assert result[0]==(100<<24)|0xff8000
    write_hex(dest/'golden.hex',result,10)
    return profiles,{'golden.hex':sha(dest/'golden.hex')}

def main():
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')
    report=ROOT/'reports'/stamp;report.mkdir(parents=True,exist_ok=False)
    build=ROOT/'.build'/stamp;build.mkdir(parents=True,exist_ok=False)
    hashes={s:sha(ROOT/s) for s in SOURCES};copies={}
    for source in SOURCES:
        # Preserve the unchanged shared triangle source under dependency/, no .. paths.
        name='dependency/triangle_rgb_raster.sv' if source.startswith('..') else source
        target=report/'executed_inputs'/name;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes((ROOT/source).read_bytes());copies[source]=str(target.relative_to(report)).replace('\\','/')
    env=os.environ.copy();env['PATH']=str(BIN)+os.pathsep+str(BIN.parent/'lib')+os.pathsep+env.get('PATH','')
    records=[];profiles=[];integration={};attempts=0;preparation_complete=False;suite_complete=False;exception=None
    expected=['lint_default','lint_example']+[prefix+f'{w}x{h}_t{t}' for w,h,t,_ in PROFILES for prefix in ['compile_','sim_']]+['compile_integration','sim_integration']
    def run(name,argv,cwd=ROOT,marker=None):
        result=execute(name,argv,cwd,env,report,marker);records.append(result);print(name,result['status'],flush=True)
        return result['status']=='PASS'
    try:
        attempts+=1;profiles,integration=prepare(report);preparation_complete=True
        if not run('lint_default',[IV,'-g2012','-Wall','-tnull','-s','fragment_rgb_depth_store','-f','files.f']):return 1
        if not run('lint_example',[IV,'-g2012','-Wall','-tnull','-s','triangle_depth64','-f','example/files.f']):return 1
        for p in profiles:
            name=p['name'];image=build/(name+'.vvp')
            args=[IV,'-g2012','-Wall','-s','tb_fragment_store',f"-Ptb_fragment_store.W={p['w']}",f"-Ptb_fragment_store.H={p['h']}",f"-Ptb_fragment_store.TAG_W={p['tag']}",f"-Ptb_fragment_store.CASES={p['cases']}",f"-Ptb_fragment_store.FRAGS={p['fragments']}",f"-Ptb_fragment_store.PROTOCOL={p['protocol']}",'-o',image,'-f','files.f','sim/tb_fragment_store.sv']
            if not run('compile_'+name,args):return 1
            marker=f"PASS STORE W={p['w']} H={p['h']} TAG={p['tag']} cases={p['cases']} checked={p['checked']} completions={p['completions']} resets={p['resets']} ".encode()
            if not run('sim_'+name,[VVP,image],report/name,marker):return 1
        image=build/'integration.vvp'
        if not run('compile_integration',[IV,'-g2012','-Wall','-s','tb_triangle_depth','-o',image,'-f','example/files.f','sim/tb_triangle_depth.sv']):return 1
        if not run('sim_integration',[VVP,image],report/'integration',b'PASS TRIANGLE_STORE triangles=5 seen=24 passed=18 checked=4096 '):return 1
        suite_complete=True;return 0
    except Exception:
        exception=traceback.format_exc();(report/'exception.txt').write_text(exception,encoding='utf8');return 1
    finally:
        unchanged=all(sha(ROOT/s)==h for s,h in hashes.items())
        vectors_unchanged=all(sha(report/p['name']/n)==h for p in profiles for n,h in p['vectors_sha256'].items()) and all(sha(report/'integration'/n)==h for n,h in integration.items())
        complete=preparation_complete and suite_complete and [r['name'] for r in records]==expected and all(r['status']=='PASS' for r in records)
        status='SOURCE_CHANGED' if not unchanged or not vectors_unchanged else 'PASS' if complete else next((r['status'] for r in records if r['status']!='PASS'),'INCOMPLETE')
        result=dict(schema='anscore-b35-fragment-store-finite-v1',status=status,source_sha256=hashes,exact_checked_copies=copies,sources_unchanged=unchanged,vectors_unchanged=vectors_unchanged,preparation_attempts=attempts,preparation_complete=preparation_complete,suite_complete=suite_complete,expected_checks=expected,records=records,profiles=profiles,integration_vectors_sha256=integration,automatic_retry=False,exception=exception,tools={str(p):sha(p) for p in [IV,VVP] if p.is_file()},synthesis='NOT_RUN',pnr='NOT_RUN',sta='NOT_RUN',board='NOT_RUN',hardware='HW_UNVERIFIED')
        (report/'results.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf8',newline='\n')
        if not unchanged or not vectors_unchanged:raise RuntimeError('Executed inputs changed during checks')
if __name__=='__main__':sys.exit(main())
