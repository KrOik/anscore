#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Finite partition-oracle checks; no synthesis or hardware tool invocation."""
import hashlib
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import sys
import tempfile

ROOT=Path(__file__).resolve().parents[1]
REPO=ROOT.parents[2]


def make_vectors(n,tag_width):
    # Components are explicit Python sets: no parent pointers or RAM schedule.
    components=[({i},i,0) for i in range(n)]
    rng=random.Random(0x445355+n)
    max_id=(1<<max(1,(n-1).bit_length()))-1
    lines=[]

    def component(node):
        return next(c for c in components if node in c[0])

    def command(op,a=0,b=0):
        root=same=merged=error=0
        if op==3:
            components[:]=[({i},i,0) for i in range(n)]
        elif a>=n or (op!=0 and b>=n):
            error=1
        else:
            ca=component(a)
            root=ca[1]
            if op==0:
                same=1
            else:
                cb=component(b)
                same=int(ca is cb)
                if op==1 and not same:
                    winner,loser=sorted([ca,cb],key=lambda c:(-c[2],c[1]))
                    components.remove(ca)
                    components.remove(cb)
                    components.append((ca[0]|cb[0],winner[1],winner[2]+int(ca[2]==cb[2])))
                    root=winner[1]
                    same=merged=1
        tag=(len(lines)*17+3)&((1<<tag_width)-1)
        lines.append(f"{op} {a} {b} {tag:x} {root} {same} {merged} {error} {len(components)}\n")

    for i in range(n):
        command(0,i,max_id)
    # Balanced merges produce maximum-depth rank trees and both rank/tie cases.
    stride=1
    while stride<n:
        for a in range(0,n,2*stride):
            b=a+stride
            if b<n:
                command(1,b,a)
                command(2,a,b)
        stride*=2
    for i in reversed(range(n)):
        command(0,i)
        command(1,i,(i+1)%n)
    command(3,max_id,max_id)
    for _ in range(300):
        command(rng.choices([0,1,2,3],[35,40,24,1])[0],rng.randrange(max_id+1),rng.randrange(max_id+1))
    command(1,0,0)
    command(2,0,0)
    command(3)
    command(0,n-1,max_id)
    return "".join(lines),len(lines)


def main():
    suite=REPO/"tools/oss-cad-suite/oss-cad-suite"
    env=os.environ.copy()
    env["PATH"]=os.pathsep.join([str(suite/"bin"),str(suite/"lib"),env.get("PATH","")])
    iv=os.environ.get("IVERILOG") or shutil.which("iverilog",path=env["PATH"])
    vvp=os.environ.get("VVP") or shutil.which("vvp",path=env["PATH"])
    report={"date":"2026-11-04","status":["NOT_RUN","HW_UNVERIFIED"],"commands":[],"cases":[],
            "not_run":["synthesis","place_and_route","STA","hardware"]}
    temporary=""

    def run(args,reject=False):
        completed=subprocess.run(args,cwd=ROOT,env=env,text=True,capture_output=True,timeout=15)
        report["commands"].append({"argv":[str(x) for x in args],"returncode":completed.returncode,
                                   "stdout":completed.stdout,"stderr":completed.stderr,"expected_failure":reject})
        if reject:
            if completed.returncode==0 or "disjoint_set_union_invalid_parameters__see_README" not in completed.stderr:
                raise RuntimeError("invalid parameter not explicitly rejected")
        elif completed.returncode:
            raise RuntimeError(completed.stdout+completed.stderr)
        return completed.stdout

    try:
        if not iv or not vvp:
            raise RuntimeError("NOT_RUN: Icarus and vvp required")
        report["tool"]=run([iv,"-V"]).splitlines()[0]
        run([iv,"-g2012","-Wall","-tnull","-s","disjoint_set_union","-f","files.f"])
        run([iv,"-g2012","-Wall","-tnull","-s","disjoint_set_example","-f","files.f","examples/disjoint_set_example.sv"])
        with tempfile.TemporaryDirectory(prefix="anscore_dsu_") as temporary:
            work=Path(temporary)
            for n,tags in [(1,1),(2,8),(3,4),(8,8),(17,8),(64,8),(256,32)]:
                content,count=make_vectors(n,tags)
                vectors,image=work/"vectors.txt",work/"sim.vvp"
                vectors.write_bytes(content.encode("ascii"))
                run([iv,"-g2012","-Wall","-s","tb_disjoint_set_union","-o",str(image),
                     f"-Ptb_disjoint_set_union.NUM_NODES={n}",f"-Ptb_disjoint_set_union.TAG_W={tags}",
                     "-f","files.f","sim/tb_disjoint_set_union.sv"])
                output=run([vvp,str(image),f"+VECTORS={vectors.as_posix()}"])
                marker=f"PASS commands={count} reset_cancellation_cases=14"
                if marker not in output:
                    raise RuntimeError("missing simulation completion marker")
                report["cases"].append({"NUM_NODES":n,"TAG_W":tags,"commands":count,
                                         "status":"PASS","output":output.strip(),
                                         "vectors_sha256":hashlib.sha256(content.encode("ascii")).hexdigest()})
                print(n,tags,marker,flush=True)
            run([iv,"-g2012","-Wall","-tnull","-s","disjoint_set_union",
                 "-Pdisjoint_set_union.NUM_NODES=4096","-Pdisjoint_set_union.TAG_W=32","-f","files.f"])
            for parameter,value in [("NUM_NODES",0),("NUM_NODES",4097),("TAG_W",0),("TAG_W",33)]:
                run([iv,"-g2012","-tnull","-s","disjoint_set_union",f"-Pdisjoint_set_union.{parameter}={value}",
                     "-f","files.f"],reject=True)
        report["status"]=["LINT_PASS","UNIT_SIM_PASS","HW_UNVERIFIED"]
    except (RuntimeError,OSError,subprocess.TimeoutExpired) as exc:
        report["status"]=["NOT_RUN_TIMEOUT" if isinstance(exc,subprocess.TimeoutExpired) else "FAILED_OR_NOT_RUN","HW_UNVERIFIED"]
        report["detail"]=str(exc)
        raise
    finally:
        for record in report["commands"]:
            if temporary:
                record["argv"]=[x.replace(temporary,"<temporary>").replace(temporary.replace("\\","/"),"<temporary>") for x in record["argv"]]
        paths=[".gitattributes","files.f","rtl/disjoint_set_union.sv","examples/disjoint_set_example.sv",
               "sim/tb_disjoint_set_union.sv","sim/run.py"]
        report["source_sha256"]={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in paths}
        (ROOT/"verification.json").write_bytes((json.dumps(report,indent=2)+"\n").encode())


if __name__=="__main__":
    try:
        main()
    except (RuntimeError,OSError,subprocess.TimeoutExpired) as exc:
        print(exc,file=sys.stderr)
        sys.exit(1)
