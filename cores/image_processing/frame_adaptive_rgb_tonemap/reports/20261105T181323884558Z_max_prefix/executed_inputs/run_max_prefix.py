"""Original Apache-2.0 one-shot directed continuation using saved exact vectors.

The original maximum-frame TIMEOUT remains immutable and is never promoted.
This checks complete capture/statistics plus 64 output pixels then explicit abort.
"""
from pathlib import Path
import datetime,json,os,sys,traceback
from run_tests import ROOT,BIN,IV,VVP,execute,sha,SOURCES as ORIGINAL_SOURCES

SOURCES=ORIGINAL_SOURCES+["run_max_prefix.py","sim/tb_max_prefix.sv"]
BASE_CHECKS=["lint_default","lint_example","compile_1x1_t1","sim_1x1_t1","compile_7x5_t8","sim_7x5_t8",
    "compile_128x1_t32","sim_128x1_t32","compile_1x128_t8","sim_1x128_t8","compile_128x128_t32"]
VECTORS=["pixels.hex","golden.hex","keys.hex","exposures.hex","sums.hex"]

def main():
    if len(sys.argv)!=2: raise SystemExit("usage: python -B run_max_prefix.py reports/<original-receipt-directory>")
    base=(ROOT/sys.argv[1]).resolve();base_file=base/"results.json"
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")+"_max_prefix"
    report=ROOT/"reports"/stamp;report.mkdir(parents=True,exist_ok=False)
    build=ROOT/".build"/stamp;build.mkdir(parents=True,exist_ok=False)
    hashes={s:sha(ROOT/s) for s in SOURCES}
    for source in SOURCES:
        target=report/"executed_inputs"/source;target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes((ROOT/source).read_bytes())
    env=os.environ.copy();env["PATH"]=str(BIN)+os.pathsep+str(BIN.parent/"lib")+os.pathsep+env.get("PATH","")
    records=[];preparation_attempts=0;preparation_complete=False;suite_complete=False;base_evidence=None;vectors={};exception=None
    expected=["compile_max_prefix","sim_max_prefix"]
    def run(name,argv,cwd=ROOT,marker=None):
        record=execute(name,argv,cwd,env,report,marker);records.append(record);print(name,record["status"],flush=True)
        return record["status"]=="PASS"
    try:
        preparation_attempts+=1
        original=json.loads(base_file.read_text(encoding="utf-8"));base_hash=sha(base_file)
        assert original["status"]=="TIMEOUT" and original["sources_unchanged"] and original["vectors_unchanged"]
        assert original["preparation_complete"] and not original["suite_complete"]
        assert [r["name"] for r in original["records"]]==BASE_CHECKS+["sim_128x128_t32"]
        assert all(r["status"]=="PASS" for r in original["records"][:-1]) and original["records"][-1]["status"]=="TIMEOUT"
        assert all(hashes[s]==h and sha(base/"executed_inputs"/s)==h for s,h in original["source_sha256"].items())
        raw={}
        for record in original["records"]:
            for stream in ["stdout","stderr"]:
                name=record["name"]+"."+stream+".txt";assert sha(base/name)==record[stream+"_sha256"];raw[name]=sha(base/name)
        for profile in original["profiles"]:
            assert all(sha(base/profile["name"]/n)==h for n,h in profile["vectors_sha256"].items())
        p=next(p for p in original["profiles"] if p["name"]=="128x128_t32")
        dest=report/"vectors";dest.mkdir()
        for name in VECTORS:
            data=(base/p["name"]/name).read_bytes();(dest/name).write_bytes(data)
            vectors[name]=sha(dest/name);assert vectors[name]==p["vectors_sha256"][name]
        base_evidence=dict(receipt=str(base_file.relative_to(ROOT)),sha256=base_hash,status="TIMEOUT",
            exact_source_match=True,raw_sha256=raw,accepted_pass_checks=BASE_CHECKS,
            excluded_from_pass=["sim_128x128_t32"],note="Completion marker and returncode0 in TIMEOUT raw output do not override the 20-second deadline.")
        preparation_complete=True
        image=build/"max_prefix.vvp"
        if not run("compile_max_prefix",[IV,"-g2012","-Wall","-s","tb_max_prefix","-o",image,"-f","files.f","sim/tb_max_prefix.sv"]): return 1
        if not run("sim_max_prefix",[VVP,image],dest,b"PASS MAX_PREFIX captured=16384 checked=64 aborted=1 "): return 1
        suite_complete=True;return 0
    except Exception:
        exception=traceback.format_exc();(report/"exception.txt").write_text(exception,encoding="utf-8");return 1
    finally:
        unchanged=all(sha(ROOT/s)==h for s,h in hashes.items())
        vectors_unchanged=all(sha(report/"vectors"/n)==h for n,h in vectors.items())
        base_unchanged=base_evidence is not None and sha(base_file)==base_evidence["sha256"]
        complete=preparation_complete and suite_complete and [r["name"] for r in records]==expected and all(r["status"]=="PASS" for r in records)
        status="SOURCE_CHANGED" if not unchanged or not vectors_unchanged else "PASS" if complete and base_unchanged else next((r["status"] for r in records if r["status"]!="PASS"),"INCOMPLETE")
        result=dict(schema="anscore-b34-tonemap-directed-continuation-v1",status=status,scope="complete max-frame capture/statistics,64-pixel output prefix,explicit abort",
            source_sha256=hashes,sources_unchanged=unchanged,vectors_sha256=vectors,vectors_unchanged=vectors_unchanged,base_receipt_unchanged=base_unchanged,
            preparation_attempts=preparation_attempts,preparation_complete=preparation_complete,suite_complete=suite_complete,
            expected_checks=expected,records=records,base_evidence=base_evidence,automatic_retry=False,exception=exception,
            tools={str(p):sha(p) for p in [IV,VVP] if p.is_file()},full_maximum_output="TIMEOUT_NOT_QUALIFIED",synthesis="NOT_RUN",pnr="NOT_RUN",sta="NOT_RUN",board="NOT_RUN",hardware="HW_UNVERIFIED")
        (report/"results.json").write_text(json.dumps(result,indent=2)+"\n",encoding="utf-8",newline="\n")
        if not unchanged or not vectors_unchanged or not base_unchanged: raise RuntimeError("Executed inputs or base receipt changed")

if __name__=="__main__": sys.exit(main())
