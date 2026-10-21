"""Record three independent, gated SRAM/UART checks of a frozen stitch design."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--attempt", required=True)
    args = parser.parse_args()
    board = Path(__file__).resolve().parent
    base = args.candidate.resolve()
    base.relative_to((board / "build").resolve())
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,48}", args.attempt):
        raise RuntimeError("Invalid route attempt name")
    source = base / f"build_{args.attempt}_summary.json"
    qualified = base / "build_qualified_scope_summary.json"
    final = base / "board_validation_summary.json"
    if qualified.exists() or final.exists():
        raise RuntimeError("Existing qualification evidence must not be overwritten")
    summary = json.loads(source.read_text())
    if (summary.get("status") != "BUILD_PASS_NOT_BOARD" or
            not summary.get("gates") or not all(summary["gates"].values()) or
            min(summary.get("fmax_mhz", []), default=0) < 50):
        raise RuntimeError("Actual 50 MHz setup/hold/resource gates have not passed")
    expected = (base / "expected_uart.txt").read_bytes()
    if expected != b"STC PASS F=20 I=003E A=004B O=012C E=0000 D=64FB8FCF C=F\r\n":
        raise RuntimeError("Frozen 58-byte UART contract differs")
    top = (base / "image_autostitch_frame_selftest_25k.v").read_text()
    if "wireclk_en=cycle_count[1:0]==0;" not in re.sub(r"\s+", "", top):
        raise RuntimeError("Actual CE1/4 top expression was not found")
    summary.update(
        original_build_summary=source.name,
        original_build_summary_sha256=sha(source),
        qualification_script_sha256=sha(Path(__file__)),
        functional_clk_mhz=50,
        core_enable_divisor="1 of 4 physical edges; no timing exception",
        clock_checks=dict(actual_clock_mhz=50, setup_50mhz=True, hold=True,
                          multicycle_exception=False),
        scope=("Isolated RGB888 4x3 registration/stitch chain, shift1, two ROI "
               "samples and nine ordered trials; 6x5 output canvas. 32 commands, "
               "62 main/75 auxiliary inputs, 300 outputs and 14 expected errors. "
               "Luma SAD, first-min ties, confidence rejection, weighted composition, "
               "manual homography, framing errors and recovery. Actual 50MHz/CE1/4; "
               "no larger-frame timing or continuous-video throughput signoff."))
    qualified.write_text(json.dumps(summary, indent=2) + "\n")
    loads = []
    for _ in range(3):
        before = set(base.glob("board_uart_*.json"))
        process = subprocess.run(
            [sys.executable, "-B", str(board / "validate_candidate_uart.py"),
             str(base), "--summary", qualified.name],
            text=True, capture_output=True)
        print(process.stdout, end="", flush=True)
        if process.stderr:
            print(process.stderr, file=sys.stderr, flush=True)
        records = set(base.glob("board_uart_*.json")) - before
        if len(records) != 1:
            raise RuntimeError("Expected one new board capture record")
        record = records.pop()
        data = json.loads(record.read_text())
        if (process.returncode or data.get("status") != "PASS" or
                data.get("jtag_detected_idcode") != "0x1281b" or
                data.get("uart_bytes") != len(expected)):
            raise RuntimeError(f"SRAM/UART verification failed: {record}")
        loads.append(dict(record=record.name, sha256=sha(record),
                          uart_bytes=len(expected), idcode="0x1281b"))
    result = dict(status="PASS", candidate=base.name, programming="SRAM_ONLY",
                  independent_sram_loads=3, uart_bytes_per_load=len(expected),
                  expected_uart=expected.decode("ascii"),
                  bitstream_sha256=summary["bitstream_sha256"],
                  functional_clk_mhz=50, clock_enable="1/4; no timing exception",
                  fmax_mhz=summary["fmax_mhz"], resources=summary["util"],
                  scope=summary["scope"], loads=loads,
                  qualification_script_sha256=sha(Path(__file__)))
    final.write_text(json.dumps(result, indent=2) + "\n")
    print("THREE_INDEPENDENT_SRAM_LOADS_PASS")


if __name__ == "__main__":
    main()
