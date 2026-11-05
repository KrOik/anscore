"""Original Apache-2.0 finite checks. No synthesis, automatic retries or network."""
from pathlib import Path
from fractions import Fraction
import datetime,hashlib,json,os,random,signal,subprocess,sys,time,traceback

ROOT=Path(__file__).resolve().parent
BIN=ROOT.parents[2]/"tools/oss-cad-suite/oss-cad-suite/bin"
IV=BIN/"iverilog.exe";VVP=BIN/"vvp.exe"
PROFILES=[(1,1,1,14,1),(7,5,8,14,1),(128,1,32,8,0),(1,128,8,8,0),(128,128,32,1,0)]
SOURCES=["run_tests.py","rtl/frame_adaptive_rgb_tonemap.sv","sim/tb_tonemap.sv","files.f","example/hdr32_example.sv","example/files.f"]

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

def nearest(value):
    assert value>=0
    return (2*value.numerator+value.denominator)//(2*value.denominator)

def oracle(pixels,key):
    # Exact rational formulas, no restoring-divider or RTL-state model.
    maxima=[max(rgb) for rgb in pixels];total=sum(maxima)
    exposure=max(1,nearest(Fraction(256*total,len(pixels)*key)))
    assert 1<=exposure<=16776960
    result=[tuple(nearest(Fraction(255*c,max(rgb)+exposure)) for c in rgb) for rgb in pixels]
    assert all(0<=c<=255 for rgb in result for c in rgb)
    return result,exposure,total

def fixtures(n):
    rng=random.Random(340034+n)
    primaries=[(65535,0,0),(0,65535,0),(0,0,65535),(0,0,0),(65535,32768,1)]
    random_pixels=lambda:[tuple(rng.randrange(65536) for _ in range(3)) for _ in range(n)]
    return [([primaries[i%len(primaries)] for i in range(n)],256),
        ([(0,0,0)]*n,1), ([(65535,65535,65535)]*n,1),
        ([(65535,65535,65535)]*n,4095), ([(65535,65535,65535)]*n,256),
        ([(1,1,1)]*n,256), ([(3,2,1)]*n,512),
        ([(65535,32768,1) if i%2 else (0,0,0) for i in range(n)],18),
        ([(i*65535//max(1,n-1),i*32768//max(1,n-1),65535-i*65535//max(1,n-1)) for i in range(n)],64),
        (random_pixels(),4095),(random_pixels(),1),(random_pixels(),257),
        ([(65535,17,0) if i==n//2 else (1,1,1) for i in range(n)],256),
        (random_pixels(),1024)]

def prepare(report):
    assert oracle([(0,0,0)],1)==([(0,0,0)],1,0)
    assert oracle([(65535,65535,65535)],1)==([(1,1,1)],16776960,65535)
    assert oracle([(65535,65535,65535)],256)[0]==[(128,128,128)]
    assert oracle([(3,2,1)],512)==([(153,102,51)],2,3)
    assert 65535+16776960==16842495
    # Every possible channel code is checked for the output-range proof at
    # the tightest A=1. This is an oracle invariant, not 65536 RTL samples.
    assert all(0<=nearest(Fraction(c*255,c+1))<=255 for c in range(65536))
    prepared=[]
    for w,h,tag,cases,protocol in PROFILES:
        name=f"{w}x{h}_t{tag}";dest=report/name;dest.mkdir()
        pixels=[];golden=[];keys=[];exposures=[];sums=[]
        for frame,key in fixtures(w*h)[:cases]:
            result,exposure,total=oracle(frame,key)
            pixels.extend((r<<32)|(g<<16)|b for r,g,b in frame)
            golden.extend((r<<16)|(g<<8)|b for r,g,b in result)
            keys.append(key);exposures.append(exposure);sums.append(total)
        values={"pixels.hex":(pixels,12),"golden.hex":(golden,6),"keys.hex":(keys,3),"exposures.hex":(exposures,6),"sums.hex":(sums,8)}
        for filename,(data,digits) in values.items():
            (dest/filename).write_text("".join(f"{v:0{digits}x}\n" for v in data),encoding="ascii",newline="\n")
        prepared.append(dict(name=name,w=w,h=h,tag=tag,cases=cases,protocol=protocol,
            checked=w*h*(cases+(24 if protocol else 0)),completions=cases+(37 if protocol else 0),
            resets=11 if protocol else 1,aborts=10 if protocol else 0,errors=4 if protocol else 0,
            vectors_sha256={n:sha(dest/n) for n in values}))
    return prepared

def main():
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    report=ROOT/"reports"/stamp;report.mkdir(parents=True,exist_ok=False)
    build=ROOT/".build"/stamp;build.mkdir(parents=True,exist_ok=False)
    hashes={s:sha(ROOT/s) for s in SOURCES}
    for source in SOURCES:
        target=report/"executed_inputs"/source;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes((ROOT/source).read_bytes())
    env=os.environ.copy();env["PATH"]=str(BIN)+os.pathsep+str(BIN.parent/"lib")+os.pathsep+env.get("PATH","")
    records=[];profiles=[];preparation_complete=False;suite_complete=False;preparation_attempts=0;exception=None
    expected=["lint_default","lint_example"]+[prefix+f"{w}x{h}_t{t}" for w,h,t,_,_ in PROFILES for prefix in ["compile_","sim_"]]
    def run(name,argv,cwd=ROOT,marker=None):
        result=execute(name,argv,cwd,env,report,marker);records.append(result);print(name,result["status"],flush=True)
        return result["status"]=="PASS"
    try:
        # Preparation is counted on entry, even if an invariant fails.
        preparation_attempts+=1;profiles=prepare(report);preparation_complete=True
        if not run("lint_default",[IV,"-g2012","-Wall","-tnull","-s","frame_adaptive_rgb_tonemap","-f","files.f"]): return 1
        if not run("lint_example",[IV,"-g2012","-Wall","-tnull","-s","hdr32_example","-f","example/files.f"]): return 1
        for p in profiles:
            name=p["name"];image=build/(name+".vvp")
            args=[IV,"-g2012","-Wall","-s","tb_tonemap",f"-Ptb_tonemap.W={p['w']}",f"-Ptb_tonemap.H={p['h']}",f"-Ptb_tonemap.TAG_W={p['tag']}",f"-Ptb_tonemap.CASES={p['cases']}",f"-Ptb_tonemap.PROTOCOL={p['protocol']}","-o",image,"-f","files.f","sim/tb_tonemap.sv"]
            if not run("compile_"+name,args): return 1
            marker=f"PASS W={p['w']} H={p['h']} TAG_W={p['tag']} cases={p['cases']} checked={p['checked']} completions={p['completions']} ".encode()
            if not run("sim_"+name,[VVP,image],report/name,marker): return 1
        suite_complete=True;return 0
    except Exception:
        exception=traceback.format_exc();(report/"exception.txt").write_text(exception,encoding="utf-8");return 1
    finally:
        unchanged=all(sha(ROOT/source)==value for source,value in hashes.items())
        vectors_unchanged=all(sha(report/p["name"]/name)==digest for p in profiles for name,digest in p["vectors_sha256"].items())
        complete=preparation_complete and suite_complete and [r["name"] for r in records]==expected and all(r["status"]=="PASS" for r in records)
        status="SOURCE_CHANGED" if not unchanged or not vectors_unchanged else "PASS" if complete else next((r["status"] for r in records if r["status"]!="PASS"),"INCOMPLETE")
        result=dict(schema="anscore-b34-tonemap-finite-v1",status=status,source_sha256=hashes,sources_unchanged=unchanged,vectors_unchanged=vectors_unchanged,
            preparation_complete=preparation_complete,suite_complete=suite_complete,expected_checks=expected,records=records,profiles=profiles,
            preparation_attempts=preparation_attempts,preparation_completed_calls=1 if preparation_complete else 0,automatic_retry=False,exception=exception,
            tools={str(p):sha(p) for p in [IV,VVP] if p.is_file()},synthesis="NOT_RUN",pnr="NOT_RUN",sta="NOT_RUN",board="NOT_RUN",hardware="HW_UNVERIFIED")
        (report/"results.json").write_text(json.dumps(result,indent=2)+"\n",encoding="utf-8",newline="\n")
        if not unchanged or not vectors_unchanged: raise RuntimeError("Executed inputs changed during checks")

if __name__=="__main__": sys.exit(main())
