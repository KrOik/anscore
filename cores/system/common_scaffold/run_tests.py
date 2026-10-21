"""Run independent common-IP scaffold suites and a cross-group integration test."""
import argparse
from concurrent.futures import ThreadPoolExecutor, as_completed
import hashlib
import json
from pathlib import Path
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE / "integration"))
from tooling import evidence_dir, execute, sim, write_json, ROOT

GROUPS = ["stream_bus", "memory", "peripherals", "cdc", "signal_video", "image", "dsp"]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--groups", nargs="+", choices=GROUPS, default=GROUPS)
    parser.add_argument("--jobs", type=int, default=3)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    evidence = evidence_dir("all")
    results = []
    sources = []
    for group in ["common", *GROUPS]:
        for sub in ["rtl", "src"]:
            sources.extend(sorted((HERE / group / sub).glob("*.v")))
    for group in ["isp", "dehaze", "multiframe", "window", "pipelines"]:
        sources.extend(sorted(p for p in (HERE / "image" / group).glob("*.v")
                              if not p.name.startswith("tb_")))
    for group in ["filters", "histogram", "geometry"]:
        sources.extend(sorted((HERE / "image" / group / "rtl").glob("*.v")))
    hashes = {p.relative_to(HERE).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources}

    def run_group(group):
        try:
            entry = HERE / group / ("run_groups.py" if group == "image" else "run_tests.py")
            output = execute([sys.executable, entry], ROOT,
                             evidence / f"{group}.log", timeout=2400 if group == "signal_video" else 300)
            if "PASS" not in output:
                raise RuntimeError("no explicit PASS marker")
            return {"group": group, "status": "PASS", "log": f"{group}.log"}
        except Exception as exc:
            return {"group": group, "status": "FAIL", "error": str(exc)}

    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = [pool.submit(run_group, group) for group in args.groups]
        for future in as_completed(futures):
            row = future.result()
            results.append(row)
            print(f"{row['group']}: {row['status']}", flush=True)
            if row["status"] == "FAIL": print(row["error"], flush=True)
    if "stream_bus" in args.groups and "memory" in args.groups and all(r["status"] == "PASS" for r in results):
        try:
            chain_sources = [HERE / "integration/cip_stream_fifo_demo.v", HERE / "integration/tb_cip_stream_fifo_demo.sv",
                HERE / "stream_bus/rtl/sb_stream_elastic.v", HERE / "stream_bus/rtl/sb_stream_register_slice.v",
                HERE / "memory/src/cip_sync_fifo.v"]
            sim("tb_cip_stream_fifo_demo", chain_sources, evidence, "INTEGRATION PASS")
            results.append({"group": "integration", "status": "PASS"})
            memory_sources = [HERE / "integration/tb_cip_dma_ce_memory.sv",
                HERE / "common/rtl/cip_native_ce_adapter.v", HERE / "common/rtl/cip_native_byte_ram.v",
                HERE / "memory/src/cip_dma_stream_native.v"]
            sim("tb_cip_dma_ce_memory", memory_sources, evidence, "DMA_CE_MEMORY PASS")
            results.append({"group": "dma_ce_memory_integration", "status": "PASS"})
        except Exception as exc:
            results.append({"group": "integration", "status": "FAIL", "error": str(exc)})
            print(str(exc))
    status = "PASS" if all(r["status"] == "PASS" for r in results) else "FAIL"
    changed = [str(p) for p in sources if hashlib.sha256(p.read_bytes()).hexdigest() != hashes[p.relative_to(HERE).as_posix()]]
    if changed:
        status = "FAIL"
        results.append({"group": "source_stability", "status": "FAIL", "files": changed})
    legacy_modules = json.loads((HERE / "signal_video/manifest.json").read_text(encoding="utf-8"))["modules"]
    legacy_counts = {kind: sum(row["status"] == kind for row in legacy_modules)
                     for kind in ["functional", "placeholder"]}
    report = {"status": status, "suites": results, "rtl_sha256": hashes,
              "board": "not_run", "synthesis": "not_run",
              "image_algorithms": "bounded functional image groups; see image group result",
              "legacy_signal_video": {"manifest_counts": legacy_counts,
                  "scope": "Counts describe current entry implementations; functional verification scope is in each suite result, not inferred from counts."}}
    write_json(evidence / "summary.json", report)
    print(f"COMMON_IP_SCAFFOLD {status} evidence={evidence}")
    raise SystemExit(0 if status == "PASS" else 1)


if __name__ == "__main__":
    main()
