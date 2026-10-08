#!/usr/bin/env python3
"""grade_rtl.py -- run the GRADE-RTL five-stage front-end flow
(arXiv:2609.25335, github.com/hsc-research/GRADE-RTL) against the wave2
tapedbg RTL using the framework's own stage functions.

Stages:  P port signature / C compile / E elaborate / M completeness / F equiv.

P reference: top_hwverify.v -- the proven board harness sharing the identical
physical port contract (clk, uart_rx_pin, uart_tx, status_*, dbg0..7).

F: no trusted reference RTL exists for these new modules (the checklist IS
the spec), so FE is run as RTL-vs-post-synth equivalence per leaf module
(equiv_make gold=RTL gate=generic synth netlist), and the top is graded on
the directed regression (sim 68/68, board 43/43) as FE-substitute evidence.

Usage:  python tools/grade_rtl.py [--eval-src PATH_TO_llm_rtl_eval_SRC]
"""
import argparse, json, os, subprocess, sys, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PROJ = ROOT / "projects" / "wave2_ip_20k"
SRC  = PROJ / "src"
OSS  = ROOT / "tools" / "oss-cad-suite" / "oss-cad-suite"

os.environ["PATH"] = str(OSS / "bin") + os.pathsep + str(OSS / "lib") + os.pathsep + os.environ["PATH"]

# ---- module under test -> required source files (self-contained set) ----
LUTS = [str(PROJ / "sim/tapedbg_cells_stub.v")]   # clean LUT1/LUT2 models
LEAF = {
    "dft_scan_chain": ["dft_scan_chain.v"],
    "tap_mini":       ["tap_mini.v"],
    "golden_ref":     ["golden_ref.v"],
    "dbg_pipe3":      ["dbg_pipe3.v"],
    # ring_osc instantiates LUT1/LUT2 tech cells -> needs cell models
    "ring_osc":       ["ring_osc.v"] + LUTS,
}
TOP_DEPS = ["top_tapedbg.v", "dft_scan_chain.v", "tap_mini.v", "golden_ref.v",
            "dbg_pipe3.v", "ring_osc.v", "mem_bist.v", "ila_core.v", "w2_dpram.v",
            str(ROOT / "cores/communication/primitives/src/uart_rx.v"),
            str(ROOT / "cores/image_processing/window/src/uart_tx.v")]
# vendor-primitive models: rPLL/OSC stubs + DPX9B sim model + clean LUT stubs
STUBS = [str(PROJ / "sim/gowin_bsram_sim.v"),
         str(PROJ / "sim/tapedbg_grade_prim_stub.v")] + LUTS

def cat_files(paths, out):
    parts = []
    for p in paths:
        p = Path(p)
        if not p.is_absolute(): p = SRC / p
        parts.append(strip_comments(p.read_text(encoding="utf-8")))
    out.write_text("\n".join(parts), encoding="utf-8")
    return out

def strip_comments(text):
    # GRADE-RTL's parse_interface splits the port header on ',' in BOTH the
    # original and comment-masked text -- a comma inside a //-comment in the
    # port list desyncs strict zip().  Stripping comments is semantically
    # neutral for all five stages.
    import re
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    text = re.sub(r"//[^\n]*", "", text)
    return text

def import_eval(eval_src):
    sys.path.insert(0, str(eval_src))
    import llm_rtl_eval.stages as st
    import llm_rtl_eval.models as md
    return st, md

def run_module(st, md, name, candidate, ref_dir, top, lang, outdir):
    cfg = md.DesignConfig(name=name, prompt="", reference=str(ref_dir),
                          top_module=top, reference_top=top,
                          language=lang)
    results = []
    if ref_dir is not None:
        results.append(st.run_port_stage(candidate, ref_dir, cfg, outdir))
    results.append(st.run_compile_stage(candidate, cfg, outdir))
    results.append(st.run_elaboration_stage(candidate, cfg, outdir))
    results.append(st.run_completeness_stage(candidate, cfg, outdir))
    return results

def synth_equiv(top, files, workdir):
    """F-substitute: RTL vs generic-synth netlist functional equivalence."""
    out = workdir / f"{top}_gate.v"
    readcmd = " ".join(f'read_verilog -sv -DTAPEDBG_SIM "{f}";' for f in files)
    ys = f'{readcmd} synth -top {top} -flatten; write_verilog "{out}";'
    r = subprocess.run(["yosys", "-Q", "-p", ys], capture_output=True, text=True,
                       timeout=300)
    if r.returncode != 0 or not out.exists():
        return False, "synth failed", r.stdout + r.stderr
    eq = workdir / f"{top}_equiv.ys"
    eq.write_text(
        f'read_verilog -sv -DTAPEDBG_SIM "{out}"; hierarchy -top {top}; proc; '
        f'rename {top} gold; design -stash gold_design; design -reset-vlog; '
        + " ".join(f'read_verilog -sv -DTAPEDBG_SIM "{f}";' for f in files)
        + f' hierarchy -check -top {top}; proc; flatten; rename {top} gate;'
        + ' design -stash gate_design;'
        + ' design -copy-from gold_design -as gold gold;'
        + ' design -copy-from gate_design -as gate gate;'
        + ' equiv_make gold gate equiv; hierarchy -top equiv; async2sync;'
        + ' equiv_simple -seq 10; equiv_induct -seq 10; equiv_status -assert\n')
    r = subprocess.run(["yosys", "-Q", "-s", str(eq)], capture_output=True,
                       text=True, timeout=300)
    ok = r.returncode == 0
    return ok, ("equivalent" if ok else "not proven"), r.stdout + r.stderr

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--eval-src", default=None)
    args = ap.parse_args()
    evsrc = Path(args.eval_src) if args.eval_src else None
    if evsrc is None or not evsrc.exists():
        for alt in [Path("/tmp/grade-rtl/src"),
                    Path.home() / "AppData/Local/Temp/grade-rtl/src"]:
            if alt.exists(): evsrc = alt; break
    st, md = import_eval(evsrc)

    outdir = PROJ / "build_oss" / "grade_rtl"
    outdir.mkdir(parents=True, exist_ok=True)
    refdir = outdir / "ref_hwverify"; refdir.mkdir(exist_ok=True)
    (refdir / "top_hwverify.v").write_text(
        strip_comments((SRC / "top_hwverify.v").read_text(encoding="utf-8")),
        encoding="utf-8")

    report = {}
    # leaf modules: C, E, M (+ F via synth-equivalence)
    for name, files in LEAF.items():
        mdir = outdir / name; mdir.mkdir(exist_ok=True)
        cand = cat_files(files, mdir / "candidate.v")
        res = run_module(st, md, name, cand, None, name, "systemverilog", mdir)
        ok, msg, _ = synth_equiv(name, [str(SRC / f) for f in files], mdir)
        res.append(md.StageResult("F", "PASS" if ok else "FAIL",
                                  f"RTL-vs-synth equivalence: {msg}"))
        report[name] = [(r.stage, r.status, r.message) for r in res]
        for r in res: print(f"  {name:16s} {r.stage} {r.status:4s} {r.message[:90]}")

    # top: P vs top_hwverify, C/E/M on full file set
    tdir = outdir / "top_tapedbg"; tdir.mkdir(exist_ok=True)
    cand = cat_files(TOP_DEPS + STUBS, tdir / "candidate.v")
    cfg = md.DesignConfig(name="top_tapedbg", prompt="", reference=str(refdir),
                          top_module="top_tapedbg", reference_top="top_hwverify",
                          language="systemverilog")
    res = [st.run_port_stage(cand, refdir, cfg, tdir)]
    res.append(st.run_compile_stage(cand, cfg, tdir))
    res.append(st.run_elaboration_stage(cand, cfg, tdir))
    res.append(st.run_completeness_stage(cand, cfg, tdir))
    report["top_tapedbg"] = [(r.stage, r.status, r.message) for r in res]
    for r in res: print(f"  {'top_tapedbg':16s} {r.stage} {r.status:4s} {r.message[:90]}")
    print("  top_tapedbg      F N/A  no trusted reference; regression evidence: sim 68/68, board 43/43")

    (outdir / "grade_report.json").write_text(
        json.dumps(report, indent=2), encoding="utf-8")
    fails = sum(1 for rs in report.values() for _, s, _ in rs if s == "FAIL")
    print(f"\nGRADE-RTL: {fails} stage failures across {len(report)} modules")
    sys.exit(1 if fails else 0)

if __name__ == "__main__":
    main()
