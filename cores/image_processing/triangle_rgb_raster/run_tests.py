"""Original Apache-2.0 finite triangle checks; no synthesis or automatic retry."""
from pathlib import Path
from fractions import Fraction
import datetime,hashlib,json,os,random,signal,subprocess,sys,time

ROOT=Path(__file__).resolve().parent
BIN=ROOT.parents[2]/"tools/oss-cad-suite/oss-cad-suite/bin"
IV=BIN/"iverilog.exe";VVP=BIN/"vvp.exe"
PROFILES=[(1,1,1),(16,12,8),(256,256,32)]
SOURCES=["run_tests.py","rtl/triangle_rgb_raster.sv","sim/tb_triangle_rgb.sv","files.f","example/triangle64_example.sv","example/files.f"]

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

def cross(a,b,c): return (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])

def reference(vertices,colors,w,h):
    # Direct determinants at every viewport sample, with exact Fraction colors.
    # No RTL bounding-box scan, edge recurrence, multiplier schedule or divider.
    vertices=list(vertices);colors=list(colors)
    determinant=cross(*vertices)
    if determinant==0: return [],1
    if determinant<0:
        vertices[1],vertices[2]=vertices[2],vertices[1]
        colors[1],colors[2]=colors[2],colors[1]
        determinant=-determinant
    if max(v[0] for v in vertices)<=0 or max(v[1] for v in vertices)<=0 or min(v[0] for v in vertices)>=w or min(v[1] for v in vertices)>=h: return [],2
    doubled=[(2*x,2*y) for x,y in vertices]
    inclusive=[]
    for a,b in [(doubled[1],doubled[2]),(doubled[2],doubled[0]),(doubled[0],doubled[1])]:
        inclusive.append(b[1]<a[1] or (b[1]==a[1] and b[0]>a[0]))
    out=[]
    for y in range(h):
        for x in range(w):
            point=(2*x+1,2*y+1)
            weights=[cross(doubled[1],doubled[2],point),cross(doubled[2],doubled[0],point),cross(doubled[0],doubled[1],point)]
            if not all(v>0 or (v==0 and inc) for v,inc in zip(weights,inclusive)): continue
            assert sum(weights)==4*determinant
            rgb=0
            for lane in range(3):
                value=Fraction(sum(v*((c>>(8*lane))&255) for v,c in zip(weights,colors)),4*determinant)
                byte=(2*value.numerator+value.denominator)//(2*value.denominator)
                assert 0<=byte<=255
                rgb|=byte<<(8*lane)
            out.append(x|(y<<8)|(rgb<<16))
    return out,0

def fixtures(w,h):
    a=[(0,0),(4,0),(0,4)];rgb=[0xff0000,0x00ff00,0x0000ff]
    cases=[(a,rgb),([a[0],a[2],a[1]],[rgb[0],rgb[2],rgb[1]]),
        ([(4,0),(4,4),(0,4)],[0x00ff00,0xffffff,0x0000ff]),
        ([(0,0),(2,2),(4,4)],rgb),([(0,0),(0,0),(4,4)],rgb),
        ([(-10,-10),(-8,-10),(-10,-8)],rgb),([(w+1,0),(w+4,0),(w+1,4)],rgb),
        ([(-2,-1),(5,0),(1,6)],[0,0xffffff,0x137fda]),
        ([(0,0),(1,0),(0,1)],rgb),([(-512,-512),(511,-512),(-512,511)],rgb),
        ([(-512,0),(511,0),(0,511)],[0x0000ff,0xffffff,0xff0000]),
        ([(0,0),(8,0),(0,8)],[0x808080]*3),([(-512,511),(0,511),(511,511)],rgb),
        ([(0,0),(2,0),(0,2)],[0,0x020202,0])]
    rng=random.Random(330033)
    for _ in range(4):
        cases.append(([(rng.randrange(-5,24),rng.randrange(-5,20)) for _ in range(3)],[rng.randrange(1<<24) for _ in range(3)]))
    return cases

def prepare(report):
    # Shared-edge partition and exact color anchors are independent invariants.
    cases=fixtures(4,4)
    a,_=reference(*cases[0],4,4);b,_=reference(*cases[2],4,4)
    pa={v&65535 for v in a};pb={v&65535 for v in b}
    assert len(pa)==6 and len(pb)==10 and not pa&pb and pa|pb=={x+(y<<8) for y in range(4) for x in range(4)}
    assert a[0]>>16==0xbf2020
    assert reference(*cases[13],2,2)[0]==[0x010101<<16]
    prepared=[]
    for w,h,tag in PROFILES:
        name=f"{w}x{h}_t{tag}";dest=report/name;dest.mkdir()
        commands=[];golden=[];counts=[];statuses=[]
        cases=fixtures(w,h)
        for vertices,colors in cases:
            coords=[p for vertex in vertices for p in vertex]
            command=sum((value&1023)<<(10*i) for i,value in enumerate(coords))
            command|=sum(color<<(60+24*i) for i,color in enumerate(colors))
            commands.append(command)
            fragments,status=reference(vertices,colors,w,h)
            counts.append(len(fragments));statuses.append(status);golden.extend(fragments)
        assert reference(*cases[0],w,h)==reference(*cases[1],w,h)
        values={"commands.hex":(commands,33),"golden.hex":(golden,10),"sizes.hex":(counts,5),"statuses.hex":(statuses,1)}
        for filename,(data,digits) in values.items():
            (dest/filename).write_text("".join(f"{v:0{digits}x}\n" for v in data),encoding="ascii",newline="\n")
        prepared.append(dict(name=name,w=w,h=h,tag=tag,cases=len(cases),total=len(golden),checked=len(golden)+3*counts[0],counts=counts,statuses=statuses,
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
    records=[];profiles=[];preparation_complete=False;suite_complete=False
    expected=["lint_default","lint_example"]+[prefix+f"{w}x{h}_t{t}" for w,h,t in PROFILES for prefix in ["compile_","sim_"]]
    def run(name,argv,cwd=ROOT,marker=None):
        result=execute(name,argv,cwd,env,report,marker);records.append(result);print(name,result["status"],flush=True)
        return result["status"]=="PASS"
    try:
        if not run("lint_default",[IV,"-g2012","-Wall","-tnull","-s","triangle_rgb_raster","-f","files.f"]): return 1
        if not run("lint_example",[IV,"-g2012","-Wall","-tnull","-s","triangle64_example","-f","example/files.f"]): return 1
        profiles=prepare(report);preparation_complete=True
        for p in profiles:
            name=p["name"];image=build/(name+".vvp")
            args=[IV,"-g2012","-Wall","-s","tb_triangle_rgb",f"-Ptb_triangle_rgb.W={p['w']}",f"-Ptb_triangle_rgb.H={p['h']}",f"-Ptb_triangle_rgb.TAG_W={p['tag']}",f"-Ptb_triangle_rgb.CASES={p['cases']}",f"-Ptb_triangle_rgb.TOTAL={p['total']}","-o",image,"-f","files.f","sim/tb_triangle_rgb.sv"]
            if not run("compile_"+name,args): return 1
            marker=f"PASS W={p['w']} H={p['h']} TAG_W={p['tag']} cases={p['cases']} checked={p['checked']} completions={p['cases']+3} ".encode()
            if not run("sim_"+name,[VVP,image],report/name,marker): return 1
        suite_complete=True;return 0
    finally:
        unchanged=all(sha(ROOT/source)==value for source,value in hashes.items())
        complete=preparation_complete and suite_complete and [r["name"] for r in records]==expected and all(r["status"]=="PASS" for r in records)
        status="SOURCE_CHANGED" if not unchanged else "PASS" if complete else next((r["status"] for r in records if r["status"]!="PASS"),"INCOMPLETE")
        result=dict(schema="anscore-b33-triangle-finite-v1",status=status,source_sha256=hashes,sources_unchanged=unchanged,
                    preparation_complete=preparation_complete,suite_complete=suite_complete,expected_checks=expected,records=records,profiles=profiles,
                    preparation_calls=1 if preparation_complete else 0,automatic_retry=False,tools={str(p):sha(p) for p in [IV,VVP] if p.is_file()},
                    synthesis="NOT_RUN",pnr="NOT_RUN",sta="NOT_RUN",board="NOT_RUN",hardware="HW_UNVERIFIED")
        (report/"results.json").write_text(json.dumps(result,indent=2)+"\n",encoding="utf-8",newline="\n")
        if not unchanged: raise RuntimeError("Executed inputs changed during checks")

if __name__=="__main__": sys.exit(main())
