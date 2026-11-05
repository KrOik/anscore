"""Finite B32 deblock checks. Original Apache-2.0, standard-library only."""
from pathlib import Path
import datetime, hashlib, json, os, random, signal, subprocess, sys, time

ROOT=Path(__file__).resolve().parent
BIN=ROOT.parents[2]/"tools/oss-cad-suite/oss-cad-suite/bin"
IV=BIN/"iverilog.exe"
VVP=BIN/"vvp.exe"
EXECUTED=["run_tests.py","rtl/h264_luma_deblock_edge.sv","sim/tb_deblock_edge.sv",
          "files.f","example/deblock_edge_example.sv","example/files.f"]

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def child(name,argv,cwd,env,report,completion_marker=None):
    argv=list(map(str,argv));start=time.monotonic();out=err=b"";code=None;cleanup=[];reason=None
    options={"creationflags":subprocess.CREATE_NO_WINDOW} if os.name=="nt" else {"start_new_session":True}
    try:
        process=subprocess.Popen(argv,cwd=cwd,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**options)
    except OSError as exc:
        status="NOT_RUN";err=(repr(exc)+"\n").encode()
    else:
        try:
            out,err=process.communicate(timeout=20);code=process.returncode
            status="PASS" if code==0 else "FAIL"
        except subprocess.TimeoutExpired as exc:
            status="TIMEOUT";out=exc.stdout or b"";err=exc.stderr or b""
            if os.name=="nt":
                kill=[str(Path(os.environ.get("SystemRoot",r"C:\Windows"))/"System32/taskkill.exe"),"/PID",str(process.pid),"/T","/F"]
                try:
                    k=subprocess.run(kill,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=5,
                                     check=False,creationflags=subprocess.CREATE_NO_WINDOW)
                    cleanup.append(dict(argv=kill,returncode=k.returncode,stdout=k.stdout.decode(errors="replace"),stderr=k.stderr.decode(errors="replace")))
                except (OSError,subprocess.TimeoutExpired) as exc:
                    cleanup.append(dict(argv=kill,error=repr(exc)))
            else:
                try: os.killpg(process.pid,signal.SIGKILL)
                except OSError as exc: cleanup.append(dict(action="kill_group",error=repr(exc)))
            try:
                if process.poll() is None: process.kill()
            except OSError as exc: cleanup.append(dict(action="kill_parent",error=repr(exc)))
            try: out,err=process.communicate(timeout=2)
            except subprocess.TimeoutExpired as exc:
                out=exc.stdout or out;err=exc.stderr or err;cleanup.append(dict(action="drain",error=repr(exc)))
            except OSError as exc: cleanup.append(dict(action="drain",error=repr(exc)))
            code=process.poll()
    if status=="PASS" and name.startswith("sim_"):
        if completion_marker is None or not any(line.startswith(completion_marker) for line in out.splitlines()):
            status="FAIL";reason="Missing required simulator completion marker"
    (report/(name+".stdout.txt")).write_bytes(out)
    (report/(name+".stderr.txt")).write_bytes(err)
    return dict(name=name,argv=argv,cwd=str(cwd),status=status,returncode=code,
                execution_deadline_seconds=20,cleanup_budget_seconds=7,cleanup=cleanup,
                completion_marker=completion_marker.decode() if completion_marker is not None else None,reason=reason,
                seconds=round(time.monotonic()-start,3),stdout_sha256=hashlib.sha256(out).hexdigest(),stderr_sha256=hashlib.sha256(err).hexdigest())

def reference(pixels,bs,alpha,beta,tc0):
    """Integer equations; tuple dot-products, floor division and list updates.

    Uses original neighbors throughout; no serial store changes a later term.
    """
    p3,p2,p1,p0,q0,q1,q2,q3=pixels
    out=list(pixels)
    info=[]
    if bs>4: return out,1,["invalid"]
    if bs==0: return out,0,["disabled"]
    if not(abs(p0-q0)<alpha and abs(p1-p0)<beta and abs(q1-q0)<beta):
        return out,0,["gate_reject"]
    ap=abs(p2-p0)<beta;aq=abs(q2-q0)<beta
    info.append(f"sides_{int(ap)}{int(aq)}")
    if bs==4:
        near=abs(p0-q0)<alpha//4+2
        for reverse,active in [(False,ap),(True,aq)]:
            v=list(reversed(pixels)) if reverse else pixels
            a3,a2,a1,a0,b0,b1,b2,b3=v
            side=[a3,a2,a1,a0]
            if near and active:
                side[3]=(sum(a*b for a,b in zip([a2,a1,a0,b0,b1],[1,2,2,2,1]))+4)//8
                side[2]=(sum([a2,a1,a0,b0])+2)//4
                side[1]=(sum(a*b for a,b in zip([a3,a2,a1,a0,b0],[2,3,1,1,1]))+4)//8
                info.append("strong_wide")
            else:
                side[3]=(2*a1+a0+b1+2)//4;info.append("strong_fallback")
            if reverse: out[4:]=reversed(side)
            else: out[:4]=side
    else:
        limit=tc0+ap+aq
        correction=((q0-p0)*4+p1-q1+4)//8
        delta=max(-limit,min(limit,correction))
        info.append("normal_positive" if delta>0 else "normal_negative" if delta<0 else "normal_zero")
        if delta!=correction: info.append("delta_limited")
        a,b=p0+delta,q0-delta
        if min(a,b)<0 or max(a,b)>255: info.append("pixel_clipped")
        out[3]=max(0,min(255,a));out[4]=max(0,min(255,b))
        average=(p0+q0+1)//2
        if ap: out[2]=max(0,min(255,p1+max(-tc0,min(tc0,(p2+average-2*p1)//2))))
        if aq: out[5]=max(0,min(255,q1+max(-tc0,min(tc0,(q2+average-2*q1)//2))))
    return out,0,info

def prepare():
    cases=[]
    def add(v,bs,a,b,t): cases.append((v,bs,a,b,t))
    for bs in range(8):
        for tc in [0,1,25,31]:
            for a,b in [(0,0),(16,8),(255,255)]:
                add([100,100,100,100,104,104,104,104],bs,a,b,tc)
    # Strict threshold equality, side gates, asymmetric strong modes and rails.
    base=[80,100,100,100,104,104,104,120]
    for bs in [1,2,3,4]:
        for a in [3,4,5,8,16,255]:
            for b in [0,1,4,5,20,255]: add(base,bs,a,b,2)
        for ap in [False,True]:
            for aq in [False,True]:
                add([80,100 if ap else 150,100,100,104,104,104 if aq else 150,120],bs,64,10,31)
        add([0,0,0,0,1,255,1,0],bs,255,255,31)
        add([255,255,255,255,254,0,254,255],bs,255,255,31)
        add([100,100,100,100,120,120,120,120],bs,64,32,2)
    rng=random.Random(320031)
    for i in range(384):
        if i%2:
            center=rng.randrange(20,236)
            v=[max(0,min(255,center+rng.randrange(-20,21))) for _ in range(8)]
        else: v=[rng.randrange(256) for _ in range(8)]
        add(v,i%8,rng.choice([0,4,16,64,255]),rng.choice([0,4,16,64,255]),rng.choice([0,1,2,25,31]))
    vectors=[];golden=[];coverage={}
    for pixels,bs,a,b,t in cases:
        out,error,info=reference(pixels,bs,a,b,t)
        for item in info: coverage[item]=coverage.get(item,0)+1
        packed=sum(p<<(8*i) for i,p in enumerate(pixels))
        result=sum(p<<(8*i) for i,p in enumerate(out))
        vectors.append((a<<80)|(b<<72)|(t<<67)|(bs<<64)|packed)
        golden.append((int(out!=pixels)<<65)|(error<<64)|result)
    for required in ["invalid","disabled","gate_reject","sides_00","sides_01","sides_10","sides_11","normal_positive","normal_negative","normal_zero","delta_limited","pixel_clipped","strong_wide","strong_fallback"]:
        assert coverage.get(required,0)>0,required
    # Hand-derived independent anchor checks on disabled/error and normal modes.
    assert reference([100]*4+[104]*4,1,16,8,2)[0]==[100,100,101,102,102,103,104,104]
    assert reference([100]*4+[104]*4,4,16,8,2)[0]==[100,101,101,102,103,103,104,104]
    return vectors,golden,coverage

def main():
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    report=ROOT/"reports"/stamp;report.mkdir(parents=True,exist_ok=False)
    build=ROOT/".build"/stamp;build.mkdir(parents=True,exist_ok=False)
    sources={f:digest(ROOT/f) for f in EXECUTED}
    for f in EXECUTED:
        dest=report/"executed_inputs"/f;dest.parent.mkdir(parents=True,exist_ok=True)
        dest.write_bytes((ROOT/f).read_bytes())
    env=os.environ.copy();env["PATH"]=str(BIN)+os.pathsep+str(BIN.parent/"lib")+os.pathsep+env.get("PATH","")
    records=[];coverage={};vector_hashes={};count=0;preparation_complete=False;suite_complete=False
    expected_checks=["lint_default","lint_example"]+[name for tag in [1,8,32] for name in [f"compile_tag{tag}",f"sim_tag{tag}"]]
    def run(name,argv,cwd=ROOT):
        marker=(f"PASS TAG_W={name[len('sim_tag'):]} vectors={count} checked={2*count} ".encode()
                if name.startswith("sim_tag") else None)
        r=child(name,argv,cwd,env,report,marker);records.append(r);print(name,r["status"],flush=True)
        return r["status"]=="PASS"
    try:
        if not run("lint_default",[IV,"-g2012","-Wall","-tnull","-s","h264_luma_deblock_edge","-f","files.f"]): return 1
        if not run("lint_example",[IV,"-g2012","-Wall","-tnull","-s","deblock_edge_example","-f","example/files.f"]): return 1
        vectors,golden,coverage=prepare();count=len(vectors)
        for name,values,digits in [("vectors.hex",vectors,22),("golden.hex",golden,17)]:
            f=report/name;f.write_text("".join(f"{v:0{digits}x}\n" for v in values),encoding="ascii",newline="\n")
            vector_hashes[name]=digest(f)
        preparation_complete=True
        for tag in [1,8,32]:
            image=build/f"tag{tag}.vvp"
            if not run(f"compile_tag{tag}",[IV,"-g2012","-Wall","-s","tb_deblock_edge",f"-Ptb_deblock_edge.TAG_W={tag}",f"-Ptb_deblock_edge.N={count}","-o",image,"-f","files.f","sim/tb_deblock_edge.sv"]): return 1
            if not run(f"sim_tag{tag}",[VVP,image],report): return 1
        suite_complete=True
        return 0
    finally:
        unchanged=all(digest(ROOT/f)==h for f,h in sources.items())
        all_checks_complete=([r["name"] for r in records]==expected_checks)
        passed=preparation_complete and suite_complete and all_checks_complete and all(r["status"]=="PASS" for r in records)
        status="SOURCE_CHANGED" if not unchanged else ("PASS" if passed else
                next((r["status"] for r in records if r["status"]!="PASS"),"INCOMPLETE"))
        result=dict(schema="anscore-b32-finite-checks-v1",status=status,records=records,source_sha256=sources,sources_unchanged=unchanged,
                    preparation_complete=preparation_complete,suite_complete=suite_complete,expected_checks=expected_checks,
                    vector_sha256=vector_hashes,vectors=count,reference_branch_coverage=coverage,automatic_retry=False,
                    tools={str(t):digest(t) for t in [IV,VVP] if t.is_file()},hardware="HW_UNVERIFIED",synthesis="NOT_RUN",pnr="NOT_RUN",sta="NOT_RUN",board="NOT_RUN")
        (report/"results.json").write_text(json.dumps(result,indent=2)+"\n",encoding="utf-8",newline="\n")
        if not unchanged: raise RuntimeError("Executable inputs changed during checks")

if __name__=="__main__": sys.exit(main())
