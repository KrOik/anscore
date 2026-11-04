#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
"""Bounded finite source and unit checks for cached-vector sparse matrix rows."""
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


def vectors(width, length, capacity, tag_width):
    rng=random.Random(0x53504D56+width+length)
    mask=(1<<width)-1
    acc_width=2*width+(capacity-1).bit_length()
    max_index=(1<<max(1,(length-1).bit_length()))-1
    output=[]
    row_count=term_count=0

    def record(kind,value=0,index=0,keep=0,last=0,tag=0,total=0,n=0,error=0,overflow=0,result_tag=0):
        output.append(f"{kind} {value&mask:x} {index:x} {keep} {last} {tag:x} {total&((1<<acc_width)-1):x} {n} {error} {overflow} {result_tag:x}\n")

    for epoch in range(3):
        if epoch:
            record(2)
        if epoch==0:
            vector=[-(1<<(width-1)) if i%2==0 else (1<<(width-1))-1 for i in range(length)]
        elif epoch==1:
            vector=[rng.randrange(-(1<<(width-1)),1<<(width-1)) for _ in range(length)]
        else:
            vector=[-1]*length
        for value in vector:
            record(0,value)
        rows=[[(0,0,0)]]  # empty, represented by one excluded final beat
        rows += [[(i,1,1)] for i in range(length)]
        rows += [[(i%length,-(1<<(width-1)),1) for i in range(capacity)],
                 [(0,(1<<(width-1))-1,1) for _ in range(capacity+3)],
                 [(max_index,-1,1),(0,-1,0),(0,1,1)]]
        for _ in range(12):
            rows.append([(rng.randrange(max_index+1),rng.randrange(-(1<<(width-1)),1<<(width-1)),rng.randrange(3)!=0)
                         for _ in range(rng.randrange(1,capacity+5))])
        # The final row in epochs 0/1 requests a reload while still open. The
        # hardware must finish it and hold its response before accepting reload.
        rows.append([(0,-1,1),(length-1,1,1)])
        for row_index,row in enumerate(rows):
            selected=[entry for entry in row if entry[2]]
            prefix=selected[:capacity]
            total=sum(value*vector[index] for index,value,_ in prefix if index<length)
            error=int(any(index>=length for index,_,_ in selected))
            overflow=int(len(selected)>capacity)
            row_tag=(row_count*13+epoch)&((1<<tag_width)-1)
            for j,(index,value,keep) in enumerate(row):
                tag=row_tag if j==0 else (~row_tag)&((1<<tag_width)-1)
                record(1,value,index,int(keep),int(j==len(row)-1),tag,total,len(prefix),error,overflow,row_tag)
                term_count+=1
                if row_index==len(rows)-1 and epoch<2 and j==0:
                    record(4)
            row_count+=1
    return "".join(output),row_count,term_count


def main():
    report_path=ROOT/"verification.json"
    suite=REPO/"tools/oss-cad-suite/oss-cad-suite"
    env=os.environ.copy()
    env["PATH"]=os.pathsep.join([str(suite/"bin"),str(suite/"lib"),env.get("PATH","")])
    iv=os.environ.get("IVERILOG") or shutil.which("iverilog",path=env["PATH"])
    vvp=os.environ.get("VVP") or shutil.which("vvp",path=env["PATH"])
    commands,cases=[],[]
    report={"date":"2026-11-04","status":["NOT_RUN","HW_UNVERIFIED"],"commands":commands,"cases":cases,
            "not_run":["synthesis","place_and_route","STA","hardware"]}
    temporary=""

    def run(args,expected_failure=False):
        result=subprocess.run(args,cwd=ROOT,env=env,text=True,capture_output=True,timeout=15)
        commands.append({"argv":[str(a) for a in args],"returncode":result.returncode,
                         "stdout":result.stdout,"stderr":result.stderr,"expected_failure":expected_failure})
        if expected_failure:
            if result.returncode==0 or "sparse_matvec_invalid_parameter__see_README" not in result.stderr:
                raise RuntimeError("invalid parameter was not explicitly rejected")
        elif result.returncode:
            raise RuntimeError(result.stdout+result.stderr)
        return result.stdout

    try:
        if not iv or not vvp:
            raise RuntimeError("NOT_RUN: Icarus and vvp required")
        report["tool"]=run([iv,"-V"]).splitlines()[0]
        run([iv,"-g2012","-Wall","-tnull","-s","stream_sparse_matvec","-f","files.f"])
        run([iv,"-g2012","-Wall","-tnull","-s","sparse_matvec_example","-f","files.f","examples/sparse_matvec_example.sv"])
        with tempfile.TemporaryDirectory(prefix="anscore_spmv_") as temporary:
            work=Path(temporary)
            for width,length,capacity,tag_width in [(2,1,1,1),(3,3,5,4),(8,5,8,8),(16,64,64,8),(24,3,17,32)]:
                config=dict(DATA_W=width,VECTOR_LEN=length,MAX_TERMS=capacity,TAG_W=tag_width)
                content,nrows,nterms=vectors(width,length,capacity,tag_width)
                vector_file,image=work/"vectors.txt",work/"sim.vvp"
                vector_file.write_bytes(content.encode("ascii"))
                run([iv,"-g2012","-Wall","-s","tb_stream_sparse_matvec","-o",str(image),
                     *[f"-Ptb_stream_sparse_matvec.{k}={v}" for k,v in config.items()],
                     "-f","files.f","sim/tb_stream_sparse_matvec.sv"])
                output=run([vvp,str(image),f"+VECTORS={vector_file.as_posix()}"])
                marker=f"PASS rows={nrows} supplied_terms={nterms} reset_load_compute_output=3"
                if marker not in output:
                    raise RuntimeError("missing complete simulation marker")
                cases.append({"parameters":config,"rows":nrows,"supplied_terms":nterms,
                              "vectors_sha256":hashlib.sha256(content.encode("ascii")).hexdigest(),
                              "status":"PASS","output":output.strip()})
                print(config,marker,flush=True)
            run([iv,"-g2012","-Wall","-tnull","-s","stream_sparse_matvec",
                 "-Pstream_sparse_matvec.DATA_W=24","-Pstream_sparse_matvec.VECTOR_LEN=4096",
                 "-Pstream_sparse_matvec.MAX_TERMS=65535","-Pstream_sparse_matvec.TAG_W=32","-f","files.f"])
            for parameter,value in [("DATA_W",1),("VECTOR_LEN",4097),("MAX_TERMS",65536),("TAG_W",33)]:
                run([iv,"-g2012","-tnull","-s","stream_sparse_matvec",f"-Pstream_sparse_matvec.{parameter}={value}",
                     "-f","files.f"],expected_failure=True)
        report["status"]=["LINT_PASS","UNIT_SIM_PASS","HW_UNVERIFIED"]
    except (RuntimeError,subprocess.TimeoutExpired,OSError) as exc:
        report["status"]=["NOT_RUN_TIMEOUT" if isinstance(exc,subprocess.TimeoutExpired) else "FAILED_OR_NOT_RUN","HW_UNVERIFIED"]
        report["detail"]=str(exc)
        raise
    finally:
        for command in commands:
            command["argv"]=[arg.replace(str(temporary),"<temporary>").replace(str(temporary).replace("\\","/"),"<temporary>")
                             if temporary else arg for arg in command["argv"]]
        paths=[".gitattributes","files.f","rtl/stream_sparse_matvec.sv","examples/sparse_matvec_example.sv",
               "sim/tb_stream_sparse_matvec.sv","sim/run.py"]
        report["source_sha256"]={p:hashlib.sha256((ROOT/p).read_bytes()).hexdigest() for p in paths}
        report_path.write_bytes((json.dumps(report,indent=2)+"\n").encode("utf-8"))


if __name__=="__main__":
    try:
        main()
    except (RuntimeError,subprocess.TimeoutExpired,OSError) as exc:
        print(exc,file=sys.stderr)
        sys.exit(1)
