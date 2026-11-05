"""Finite deterministic checks. Each HDL child has a hard 20 second limit."""
from pathlib import Path
import argparse, hashlib, itertools, json, os, random, signal, subprocess, sys, time

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
BIN = REPO / "tools/oss-cad-suite/oss-cad-suite/bin"
IV = BIN / "iverilog.exe"
VVP = BIN / "vvp.exe"
PROFILES = [(2, 1), (3, 5), (5, 4), (16, 16), (64, 64)]

def oracle(a, w, h):
    # Reference uses complete path tuples and min() ordering, unlike RTL's
    # ping-pong scalar RAM and predecessor machine. Reverse path ordering
    # gives the specified terminal-first, then predecessor tie rule.
    energy = []
    for y in range(h):
        row = []
        for x in range(w):
            row.append(abs(a[y*w+max(0,x-1)]-a[y*w+min(w-1,x+1)]) +
                       abs(a[max(0,y-1)*w+x]-a[min(h-1,y+1)*w+x]))
        energy.append(row)
    paths = [(energy[0][x], (x,)) for x in range(w)]
    for y in range(1,h):
        paths = [(lambda p: (p[0]+energy[y][x],(x,)+p[1]))(
            min(paths[p] for p in range(max(0,x-1),min(w,x+2)))) for x in range(w)]
    cost, rev_path = min(paths)
    seam = list(reversed(rev_path))
    if w <= 5 and h <= 5:
        # A separate complete path enumeration checks the reference recurrence.
        possible = [p for p in itertools.product(range(w),repeat=h)
                    if all(abs(p[y]-p[y-1])<=1 for y in range(1,h))]
        check = min((sum(energy[y][p[y]] for y in range(h)), tuple(reversed(p))) for p in possible)
        assert (cost,rev_path) == check
    out = [a[y*w+x] for y in range(h) for x in range(w) if x != seam[y]]
    return out,seam,cost

def write_hex(path, values, digits=2):
    path.write_text("".join(f"{v:0{digits}x}\n" for v in values),encoding="ascii")

def run_child(name, args, cwd, env, work):
    """Record launch failures and kill the compiler's whole tree on deadline.

    This helper performs no numerical preparation and can be probed directly.
    A non-PASS result must stop the caller before any subsequent child launch.
    """
    argv=[str(s) for s in args]
    start=time.monotonic()
    cleanup=[]
    out=err=b""
    code=None
    options={"creationflags":subprocess.CREATE_NO_WINDOW} if os.name=="nt" else {"start_new_session":True}
    try:
        process=subprocess.Popen(argv,cwd=cwd,env=env,stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE,**options)
    except OSError as exc:
        status="NOT_RUN"
        err=(type(exc).__name__+": "+str(exc)+"\n").encode("utf-8")
    else:
        try:
            out,err=process.communicate(timeout=20)
            code=process.returncode
            status="PASS" if code==0 else "FAIL"
        except subprocess.TimeoutExpired as exc:
            status="TIMEOUT"
            out,err=exc.stdout or b"",exc.stderr or b""
            if os.name=="nt":
                kill_argv=[str(Path(os.environ.get("SystemRoot",r"C:\Windows"))/"System32/taskkill.exe"),
                           "/PID",str(process.pid),"/T","/F"]
                try:
                    killed=subprocess.run(kill_argv,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                                          timeout=5,check=False,creationflags=subprocess.CREATE_NO_WINDOW)
                    cleanup.append(dict(argv=kill_argv,returncode=killed.returncode,
                                        stdout=killed.stdout.decode(errors="replace"),
                                        stderr=killed.stderr.decode(errors="replace")))
                except (OSError,subprocess.TimeoutExpired) as kill_error:
                    cleanup.append(dict(argv=kill_argv,error=repr(kill_error)))
            else:
                try:
                    os.killpg(process.pid,signal.SIGKILL)
                    cleanup.append(dict(action="kill_process_group",pid=process.pid))
                except OSError as kill_error:
                    cleanup.append(dict(action="kill_process_group",error=repr(kill_error)))
            # Parent kill is a fallback if the platform tree kill failed or the
            # process disappeared between timeout observation and cleanup.
            try:
                if process.poll() is None:
                    process.kill()
            except OSError as kill_error:
                cleanup.append(dict(action="kill_parent",error=repr(kill_error)))
            try:
                out,err=process.communicate(timeout=2)
            except subprocess.TimeoutExpired as drain_error:
                out,err=drain_error.stdout or out,drain_error.stderr or err
                cleanup.append(dict(action="drain_pipes",error=repr(drain_error)))
            except OSError as drain_error:
                cleanup.append(dict(action="drain_pipes",error=repr(drain_error)))
            code=process.poll()
    (work/(name+".stdout.txt")).write_bytes(out)
    (work/(name+".stderr.txt")).write_bytes(err)
    return dict(name=name,argv=argv,cwd=str(cwd),status=status,returncode=code,
                seconds=round(time.monotonic()-start,3),hard_timeout_seconds=20,
                cleanup_deadline_seconds=7,cleanup=cleanup,
                stdout_sha256=hashlib.sha256(out).hexdigest(),stderr_sha256=hashlib.sha256(err).hexdigest())

def main():
    parser=argparse.ArgumentParser()
    parser.add_argument("--profile",choices=[f"{w}x{h}" for w,h in PROFILES],help="Target one fixed profile without repeating earlier standalone lint/example checks")
    args=parser.parse_args()
    profiles=PROFILES if args.profile is None else [tuple(map(int,args.profile.split("x")))]
    stamp = time.strftime("%Y%m%dT%H%M%SZ",time.gmtime())
    work = ROOT / "evidence" / stamp
    work.mkdir(parents=True,exist_ok=False)
    env = os.environ.copy()
    env["PATH"] = str(BIN)+os.pathsep+str(BIN.parent/"lib")+os.pathsep+env.get("PATH","")
    records=[]
    def child(name,args,cwd):
        r=run_child(name,args,cwd,env,work)
        records.append(r)
        print(name,r["status"])
        if r["status"]!="PASS": raise RuntimeError(name+" "+r["status"])
    try:
        if args.profile is None:
            child("lint",[IV,"-g2012","-Wall","-tnull","-s","grayscale_vertical_seam_carve","-f","files.f"],ROOT)
            child("example",[IV,"-g2012","-Wall","-tnull","-s","seam_carve_example","-f","example/files.f"],ROOT)
        for w,h in profiles:
            pdir=work/f"{w}x{h}"
            (pdir/"vectors").mkdir(parents=True)
            rng=random.Random(310000+w*100+h)
            fixtures=[[0]*(w*h),[255]*(w*h),[x*255//(w-1) for y in range(h) for x in range(w)],
                      [255*((x+y)%2) for y in range(h) for x in range(w)],
                      [rng.randrange(256) for _ in range(w*h)],
                      [min(255,abs(x-(y%w))*41) for y in range(h) for x in range(w)]]
            expected=[oracle(a,w,h) for a in fixtures]
            write_hex(pdir/"vectors/input.hex",sum(fixtures,[]))
            write_hex(pdir/"vectors/output.hex",sum([e[0] for e in expected],[]))
            write_hex(pdir/"vectors/seam.hex",sum([e[1] for e in expected],[]))
            write_hex(pdir/"vectors/cost.hex",[e[2] for e in expected],4)
            image=pdir/"simulation.vvp"
            child(f"compile_{w}x{h}",[IV,"-g2012","-Wall","-s","tb_seam_carve",f"-Ptb_seam_carve.W={w}",f"-Ptb_seam_carve.H={h}","-o",image,ROOT/"rtl/grayscale_vertical_seam_carve.sv",ROOT/"sim/tb_seam_carve.sv"],ROOT)
            child(f"sim_{w}x{h}",[VVP,image],pdir)
            image.unlink() # Small raw/vector evidence is retained; generated VVP is reproducible.
    finally:
        sources={str(p.relative_to(ROOT)).replace("\\","/"):hashlib.sha256(p.read_bytes()).hexdigest()
                 for p in ROOT.rglob("*") if p.is_file() and "evidence" not in p.relative_to(ROOT).parts}
        result=dict(schema="anscore-b31-finite-checks-v1",records=records,sources_sha256=sources,
                    profiles=profiles,status=("PASS" if records and all(r["status"]=="PASS" for r in records)
                                              else (records[-1]["status"] if records else "NOT_RUN")),
                    hardware="HW_UNVERIFIED",synthesis="NOT_RUN",pnr="NOT_RUN",sta="NOT_RUN",board="NOT_RUN")
        (work/"results.json").write_text(json.dumps(result,indent=2)+"\n",encoding="utf-8")
    return 0 if all(r["status"]=="PASS" for r in records) else 1

if __name__ == "__main__":
    sys.exit(main())
