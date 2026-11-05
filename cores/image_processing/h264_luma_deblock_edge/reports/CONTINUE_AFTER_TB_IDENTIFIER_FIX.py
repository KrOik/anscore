"""Explicit one-time HDL-only continuation; do not rerun numerical preparation."""
from pathlib import Path
import datetime, hashlib, importlib.util, json, os

ROOT=Path(__file__).resolve().parents[1]
ORIGINAL=ROOT/"reports/20261105T171218124639Z"

def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    prior=json.loads((ORIGINAL/"results.json").read_text())
    assert [r["status"] for r in prior["records"]]==["PASS","PASS","FAIL"]
    for path,value in prior["source_sha256"].items():
        if path!="sim/tb_deblock_edge.sv": assert digest(ROOT/path)==value,path
    oldtb=(ORIGINAL/"executed_inputs/sim/tb_deblock_edge.sv").read_bytes()
    assert digest(ORIGINAL/"executed_inputs/sim/tb_deblock_edge.sv")==prior["source_sha256"]["sim/tb_deblock_edge.sv"]
    assert (ROOT/"sim/tb_deblock_edge.sv").read_bytes()==oldtb.replace(b"sequence(",b"run_stream(")
    spec=importlib.util.spec_from_file_location("fixed_b32_deblock_runner",ROOT/"run_tests.py")
    helper=importlib.util.module_from_spec(spec);spec.loader.exec_module(helper)
    stamp=datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    report=ROOT/"reports"/stamp;report.mkdir(exist_ok=False)
    build=ROOT/".build"/stamp;build.mkdir(parents=True,exist_ok=False)
    sources={f:digest(ROOT/f) for f in helper.EXECUTED}
    for f in helper.EXECUTED:
        target=report/"executed_inputs"/f;target.parent.mkdir(parents=True,exist_ok=True)
        target.write_bytes((ROOT/f).read_bytes())
    (report/"executed_inputs/continue_hdl.py").write_bytes(Path(__file__).read_bytes())
    for name,value in prior["vector_sha256"].items():
        assert digest(ORIGINAL/name)==value
        (report/name).write_bytes((ORIGINAL/name).read_bytes())
    env=os.environ.copy();env["PATH"]=str(helper.BIN)+os.pathsep+str(helper.BIN.parent/"lib")+os.pathsep+env.get("PATH","")
    records=[];suite_complete=False
    expected_checks=[name for tag in [1,8,32] for name in [f"compile_tag{tag}",f"sim_tag{tag}"]]
    def run(name,argv,cwd=ROOT):
        marker=(f"PASS TAG_W={name[len('sim_tag'):]} vectors={prior['vectors']} checked={2*prior['vectors']} ".encode()
                if name.startswith("sim_tag") else None)
        record=helper.child(name,argv,cwd,env,report,marker);records.append(record)
        print(name,record["status"],flush=True)
        return record["status"]=="PASS"
    try:
        for tag in [1,8,32]:
            image=build/f"tag{tag}.vvp"
            if not run(f"compile_tag{tag}",[helper.IV,"-g2012","-Wall","-s","tb_deblock_edge",f"-Ptb_deblock_edge.TAG_W={tag}",f"-Ptb_deblock_edge.N={prior['vectors']}","-o",image,"-f","files.f","sim/tb_deblock_edge.sv"]): return 1
            if not run(f"sim_tag{tag}",[helper.VVP,image],report): return 1
        suite_complete=True
        return 0
    finally:
        unchanged=all(digest(ROOT/f)==value for f,value in sources.items())
        all_checks_complete=([r["name"] for r in records]==expected_checks)
        passed=suite_complete and all_checks_complete and all(r["status"]=="PASS" for r in records)
        status="SOURCE_CHANGED" if not unchanged else ("PASS" if passed else
                next((r["status"] for r in records if r["status"]!="PASS"),"INCOMPLETE"))
        result=dict(schema="anscore-b32-hdl-continuation-v1",status=status,records=records,source_sha256=sources,sources_unchanged=unchanged,
                    suite_complete=suite_complete,expected_checks=expected_checks,preparation_reuse_verified=True,
                    continuation_sha256=digest(Path(__file__)),preparation_receipt="reports/20261105T171218124639Z/results.json",
                    vector_sha256=prior["vector_sha256"],vectors=prior["vectors"],reference_branch_coverage=prior["reference_branch_coverage"],
                    tb_fix="Rename reserved task identifier sequence to run_stream; no data, checks, expected values, timing or production RTL changed.",
                    old_tb_sha256=prior["source_sha256"]["sim/tb_deblock_edge.sv"],new_tb_sha256=sources["sim/tb_deblock_edge.sv"],
                    numerical_preparation_repeated=False,automatic_retry=False,
                    tools={str(t):digest(t) for t in [helper.IV,helper.VVP]},hardware="HW_UNVERIFIED",synthesis="NOT_RUN",pnr="NOT_RUN",sta="NOT_RUN",board="NOT_RUN")
        (report/"results.json").write_text(json.dumps(result,indent=2)+"\n",encoding="utf-8",newline="\n")
        if not unchanged: raise RuntimeError("Inputs changed during checks")

if __name__=="__main__": raise SystemExit(main())
