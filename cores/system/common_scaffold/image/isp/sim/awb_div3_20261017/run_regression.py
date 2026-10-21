#!/usr/bin/env python3
"""Isolated exact /3 candidate proof. Never synthesize, route, or program.

The helper suite passes before the candidate is first created. Subsequent
runs verify the candidate against the exact permitted v95 source transform.
Only owned temporary reference RTL and VVP files are removed in finally.
"""
from __future__ import annotations

import argparse
import datetime as dt
import difflib
import hashlib
import json
import re
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[5]
ISP = HERE.parents[1]
PRODUCTION = ISP / "img_isp_awb_autogain.v"
STATS = ISP / "img_isp_awb_stats.v"
FROZEN = (ROOT / "cores/system/common_scaffold/board/tang25k/build/"
          "image_awb48_selftest_25k_20261017_v95_borrowprefix/rtl/img_isp_awb_autogain.v")
REFERENCE_SHA = "98715b6e6937575bfca1121c8b20029b1f59c8a715b4b6c17639a07e7178bb98"
STATS_SHA = "26aa23144444042085860068275b0bb4388d3e5785633e8213358ce29c3d5cc0"
CANDIDATE = HERE / "img_isp_awb_autogain_div3_candidate.v"
HELPER = HERE / "awb_constant_div3_radix4.v"
OLD_DIVIDER_COMMENT = '''// The number of active 16-bit groups follows the divisor's highest set bit;
// this keeps division by the constant 3 short while full-width AWB divides
// remain under the inherited 800-cycle solver watchdog.'''
NEW_DIVIDER_COMMENT = '''// The number of active 16-bit groups follows the channel divisor's highest
// set bit. This unchanged variable divider handles channel gain quotients;
// the target mean uses the separate constant-three helper above.'''


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def renamed(source: str, prefix: str) -> str:
    for name in ("img_isp_awb_autogain", "img_isp_awb_byte_divider", "img_awb_sub_prefix16"):
        source = source.replace(name, prefix+name)
    return source


def replace_once(source: str, before: str, after: str) -> str:
    if source.count(before) != 1:
        raise RuntimeError(f"candidate transform boundary absent/ambiguous: {before[:72]!r}")
    return source.replace(before, after)


def candidate_from_v95(source: str) -> str:
    source = source.replace("img_isp_awb_autogain", "img_isp_awb_autogain_div3_candidate")
    source = source.replace("img_isp_awb_byte_divider", "awb_div3_candidate_byte_divider")
    source = source.replace("img_awb_sub_prefix16", "awb_div3_candidate_sub_prefix16")
    source = replace_once(source, '''wire [NUM_W-1:0] divider_numerator =
    (state==DIV_TARGET) ? {{8{1'b0}},total_q} : {target,8'b0};
wire [TOTAL_WIDTH-1:0] divider_denominator = (state==DIV_TARGET) ?
    {{(TOTAL_WIDTH-2){1'b0}},2'd3} : {{2{1'b0}},sums[channel]};
wire divider_start = clk_en &&
    ((state==DIV_TARGET || state==DIVIDE) && !divider_busy && !divider_done);''',
    '''// Only channel divisions use the unchanged v95 variable divider.
wire [NUM_W-1:0] divider_numerator={target,8'b0};
wire [TOTAL_WIDTH-1:0] divider_denominator={{2{1'b0}},sums[channel]};
wire divider_start=clk_en && state==DIVIDE && !divider_busy && !divider_done;
wire target_busy,target_valid,target_start_ready;
wire [TOTAL_WIDTH-1:0] target_quotient;
wire [1:0] target_remainder;
wire target_start=clk_en && state==DIV_TARGET && !target_busy && !target_valid;
awb_constant_div3_radix4 #(.WIDTH(TOTAL_WIDTH)) u_target_div3 (
    .clk(clk),.rst_n(rst_n),.clk_en(clk_en),
    .start(target_start),.start_ready(target_start_ready),.numerator_in(total_q),
    .busy(target_busy),.result_valid(target_valid),.result_ready(state==DIV_TARGET),
    .quotient_out(target_quotient),.remainder_out(target_remainder)
);''')
    source = replace_once(source, '''          DIV_TARGET: if(divider_done) begin
              if(divider_zero) begin
                  gain_valid<=1;state<=IDLE;gain_error[7]<=1;
              end else if(total_q==0) begin
                  // A completely black frame is valid: preserve neutral gains.
                  gain_valid<=1;state<=IDLE;
              end else begin
                  target<=divider_quotient[TOTAL_WIDTH-1:0];
                  state<=PREPARE;
              end
          end''', '''          DIV_TARGET: if(target_valid) begin
              // The constant denominator is 3, so no divide-by-zero path exists.
              if(total_q==0) begin
                  // A completely black frame is valid: preserve neutral gains.
                  gain_valid<=1;state<=IDLE;
              end else begin
                  target<=target_quotient;
                  state<=PREPARE;
              end
          end''')
    source = replace_once(source, OLD_DIVIDER_COMMENT, NEW_DIVIDER_COMMENT)
    return "// ISOLATED CANDIDATE: v95 target /3 replacement only; not board-qualified.\n"+source


def run(command: list[str], log: Path, env: dict[str, str]) -> str:
    result = subprocess.run(command, cwd=HERE, env=env, capture_output=True,
                            text=True, timeout=180, check=False)
    output = result.stdout+result.stderr
    log.write_text(f"$ {shlex.join(command)}\nexit_code={result.returncode}\n{output}", encoding="utf-8")
    if result.returncode:
        raise RuntimeError(f"{log.name}: exit={result.returncode}\n{output}")
    return output


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--helper-only", action="store_true")
    args = parser.parse_args()
    report: dict[str, object] = {"status": "FAIL", "scope": "isolated AWB exact constant /3 candidate",
        "synthesis": "NOT_RUN", "place_and_route": "NOT_RUN", "board": "NOT_RUN",
        "latency_definition": "CE-enabled positive edges from accepted input to first valid output, inclusive of acceptance; CE-disabled edges excluded",
        "helper": [], "autogain": []}
    temporary_path = None
    try:
        if sha(PRODUCTION) != REFERENCE_SHA or sha(STATS) != STATS_SHA:
            raise RuntimeError("production baseline changed; do not silently rebase this isolated candidate")
        if not FROZEN.is_file() or sha(FROZEN) != REFERENCE_SHA:
            raise RuntimeError("frozen v95 reference not found or changed")
        reference_source = PRODUCTION.read_text()
        report["read_only_sources"] = {
            "production_autogain": {"path": PRODUCTION.relative_to(ROOT).as_posix(), "sha256": sha(PRODUCTION)},
            "production_stats": {"path": STATS.relative_to(ROOT).as_posix(), "sha256": sha(STATS)},
            "frozen_v95": {"path": FROZEN.relative_to(ROOT).as_posix(), "sha256": sha(FROZEN)}}
        import generate_vectors
        manifest = generate_vectors.generate()
        sys.path.insert(0, str(ROOT / "cores/signal_processing/dsp_isp_library/board/tang25k"))
        import device_flow
        compiler = device_flow.resolve("iverilog")
        runtime = device_flow.resolve("vvp")
        env = device_flow.tool_env()
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        report["tools"] = {"iverilog": compiler, "vvp": runtime}
        with tempfile.TemporaryDirectory(prefix="_tmp_awb_div3_", dir=HERE) as temp_name:
            temp = Path(temp_name).resolve()
            if temp.parent != HERE:
                raise RuntimeError("unexpected temporary directory boundary")
            temporary_path = temp
            for vector in manifest["helper"]:
                width, count = vector["width"], vector["vectors"]
                tag = f"helper_w{width}"
                image = temp / f"{tag}.vvp"
                run([compiler, "-g2012", "-Wall", "-s", "tb_awb_constant_div3_radix4",
                     f"-Ptb_awb_constant_div3_radix4.WIDTH={width}",
                     f"-Ptb_awb_constant_div3_radix4.VECTORS={count}",
                     "-o", str(image), str(HELPER), str(HERE / "tb_awb_constant_div3_radix4.sv")],
                    HERE / f"compile_{tag}.log", env)
                output = run([runtime, str(image), f"+VECTORS_FILE={vector['file']}"],
                             HERE / f"simulation_{tag}.log", env)
                match = re.search(r"DIV3_RADIX4_PASS WIDTH=(\d+) vectors=(\d+) checked=(\d+) acceptance_inclusive_ce_latency=(\d+) ce_pause_edges=(\d+) busy_poison_edges=(\d+) blocked_start_edges=(\d+) reset_cancellations=(\d+) same_edge_retire_start=(\d+) async_reset_ce0_cancellations=(\d+)", output)
                if not match or tuple(map(int, match.groups()[:2])) != (width, count):
                    raise RuntimeError(f"missing/wrong helper PASS: {tag}")
                keys = ("width", "vectors", "checked", "acceptance_inclusive_ce_latency",
                        "ce_pause_edges", "busy_poison_edges", "blocked_start_edges",
                        "reset_cancellations", "same_edge_retire_start", "async_reset_ce0_cancellations")
                record = dict(zip(keys, map(int, match.groups())))
                record.update(status="PASS", compile_log=f"compile_{tag}.log", simulation_log=f"simulation_{tag}.log")
                report["helper"].append(record)
                print(f"{tag}: PASS vectors={count}", flush=True)
            report["helper_50bit_passed_before_candidate_creation"] = any(
                row["width"] == 50 and row["status"] == "PASS" for row in report["helper"])
            if not args.helper_only:
                # No autogain candidate is constructed until the actual RTL
                # helper, including its 50-bit case, has passed simulation.
                expected_candidate = candidate_from_v95(reference_source)
                if not CANDIDATE.exists():
                    CANDIDATE.write_text(expected_candidate, encoding="utf-8")
                    report["candidate_created_after_helper_proof"] = True
                elif CANDIDATE.read_text() != expected_candidate:
                    raise RuntimeError("candidate differs from narrowly permitted source transform")
                else:
                    report["candidate_created_after_helper_proof"] = "already_exists_exact_scope_verified"
                # Prove unchanged variable-divider and borrow-prefix text after
                # undoing module-name changes, rather than assuming equivalence.
                separator = "// Unsigned restoring divider"
                tail = CANDIDATE.read_text().split(separator, 1)[1]
                tail = tail.replace("awb_div3_candidate_byte_divider", "img_isp_awb_byte_divider")
                tail = tail.replace("awb_div3_candidate_sub_prefix16", "img_awb_sub_prefix16")
                tail = replace_once(tail, NEW_DIVIDER_COMMENT, OLD_DIVIDER_COMMENT)
                if tail != reference_source.split(separator, 1)[1]:
                    raise RuntimeError("variable-divider or prefix body changed")
                report["variable_divider_and_prefix_unchanged_except_module_names_and_header_comment"] = True
                (HERE / "candidate_vs_v95.diff").write_text("".join(difflib.unified_diff(
                    reference_source.splitlines(True), expected_candidate.splitlines(True),
                    fromfile="read_only_production_v95", tofile=CANDIDATE.name)), encoding="utf-8")
                reference = temp / "read_only_v95_reference_renamed.v"
                reference.write_text(renamed(reference_source, "ref_"), encoding="utf-8")
                for vector in manifest["autogain"]:
                    width, count = vector["width"], vector["vectors"]
                    tag = f"autogain_w{width}"
                    image = temp / f"{tag}.vvp"
                    run([compiler, "-g2012", "-Wall", "-s", "tb_awb_autogain_div3_compare",
                         f"-Ptb_awb_autogain_div3_compare.WIDTH={width}",
                         f"-Ptb_awb_autogain_div3_compare.VECTORS={count}",
                         "-o", str(image), str(HELPER), str(CANDIDATE), str(reference),
                         str(HERE / "tb_awb_autogain_div3_compare.sv")],
                        HERE / f"compile_{tag}.log", env)
                    output = run([runtime, str(image), f"+VECTORS_FILE={vector['file']}"],
                                 HERE / f"simulation_{tag}.log", env)
                    rows = [{key: int(value) for key, value in zip(
                        ("width", "case", "candidate_ce", "v95_ce", "saved_ce", "metadata_error"), match.groups())}
                        for match in re.finditer(r"AWB_DIV3_CASE WIDTH=(\d+) case=(\d+) candidate_ce=(\d+) v95_ce=(\d+) saved_ce=(\d+) metadata_error=(\d+)", output)]
                    match = re.search(r"AWB_DIV3_COMPARE_PASS WIDTH=(\d+) vectors=(\d+) checked=(\d+) c_min=(\d+) c_max=(\d+) c_sum=(\d+) v95_min=(\d+) v95_max=(\d+) v95_sum=(\d+) ce_freezes=(\d+) poison_cycles=(\d+) pause_sum=(\d+) pause_target=(\d+) pause_divide=(\d+) reset_cancellations=(\d+) async_reset_ce0_cancellations=(\d+)", output)
                    if not match or len(rows) != count+1:
                        raise RuntimeError(f"autogain PASS or per-case records missing: {tag}")
                    keys = ("width", "vectors", "checked", "candidate_min_ce", "candidate_max_ce", "candidate_sum_ce",
                            "v95_min_ce", "v95_max_ce", "v95_sum_ce", "ce_freezes", "poison_cycles",
                            "pause_sum", "pause_target", "pause_divide", "reset_cancellations", "async_reset_ce0_cancellations")
                    record = dict(zip(keys, map(int, match.groups())))
                    record.update(status="PASS", compile_log=f"compile_{tag}.log", simulation_log=f"simulation_{tag}.log", cases=rows)
                    if width == 48:
                        record["legacy_first17"] = rows[:17]
                        old_ce = [250,598,772,190,67,1,1,1,306,67,67,130,130,190,190,250,250]
                        if [row["v95_ce"] for row in rows[:17]] != old_ce:
                            raise RuntimeError("untouched v95 first17 latency contract did not replay")
                    report["autogain"].append(record)
                    print(f"{tag}: PASS vectors={count} max_ce={record['candidate_max_ce']} vs {record['v95_max_ce']}", flush=True)
        # Recheck source immutability and actual cleanup, not just intent.
        if sha(PRODUCTION) != REFERENCE_SHA or sha(STATS) != STATS_SHA or sha(FROZEN) != REFERENCE_SHA:
            raise RuntimeError("read-only production/frozen source changed during regression")
        if temporary_path is None or temporary_path.exists():
            raise RuntimeError("temporary artifacts were not removed")
        report["status"] = "PASS"
        report["owned_sources"] = {path.name: sha(path) for path in sorted(HERE.iterdir())
            if path.suffix in (".v", ".sv", ".py")}
        print("AWB_DIV3_ISOLATED_REGRESSION_PASS no_synthesis=1 no_pnr=1 no_board=1 temporary_artifacts_removed=1")
        return 0
    except Exception as exc:
        report["error"] = str(exc)
        print(f"AWB_DIV3_ISOLATED_REGRESSION_FAIL: {exc}", file=sys.stderr)
        raise
    finally:
        report["temporary_artifacts"] = {"path": str(temporary_path) if temporary_path else None,
            "removed": temporary_path is not None and not temporary_path.exists(),
            "retained_vvp": [path.relative_to(HERE).as_posix() for path in HERE.rglob("*.vvp")],
            "retained_pyc": [path.relative_to(HERE).as_posix() for path in HERE.rglob("*.pyc")]}
        report["completed_utc"] = dt.datetime.now(dt.timezone.utc).isoformat()
        (HERE / "regression_summary.json").write_text(json.dumps(report, indent=2)+"\n", encoding="utf-8")


if __name__ == "__main__":
    raise SystemExit(main())
