#!/usr/bin/env python3
"""Welch t-test analysis for fixed-vs-random TVLA trace manifests.

The script is intentionally dependency-free so fixture checks can run on a
fresh host before any oscilloscope or board software is installed.
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Sequence, Tuple


FIXED_GROUP = "fixed"
RANDOM_GROUP = "random"
DEFAULT_THRESHOLD = 4.5


@dataclass
class TraceRecord:
    sample_index: int
    group: str
    raw_trace_path: Path
    uart_digest: Optional[str]


class RunningStats:
    def __init__(self) -> None:
        self.n = 0
        self.sums: List[float] = []
        self.sums_sq: List[float] = []

    def add(self, values: Sequence[float]) -> None:
        if not values:
            raise ValueError("trace contains no numeric samples")
        if not self.sums:
            self.sums = [0.0] * len(values)
            self.sums_sq = [0.0] * len(values)
        if len(values) != len(self.sums):
            raise ValueError(
                f"trace length mismatch: expected {len(self.sums)}, got {len(values)}"
            )
        self.n += 1
        for idx, value in enumerate(values):
            self.sums[idx] += value
            self.sums_sq[idx] += value * value

    def mean(self, idx: int) -> float:
        return self.sums[idx] / self.n

    def variance(self, idx: int) -> float:
        if self.n < 2:
            return 0.0
        mean = self.mean(idx)
        numerator = self.sums_sq[idx] - (self.n * mean * mean)
        return max(0.0, numerator / (self.n - 1))


def normalize_group(value: str) -> str:
    label = value.strip().lower()
    if label in {"fixed", "f", "0"}:
        return FIXED_GROUP
    if label in {"random", "rand", "r", "1"}:
        return RANDOM_GROUP
    raise ValueError(f"unsupported TVLA group label: {value!r}")


def load_manifest(manifest_path: Path) -> List[TraceRecord]:
    manifest_path = manifest_path.resolve()
    if not manifest_path.exists():
        raise FileNotFoundError(f"manifest not found: {manifest_path}")

    records: List[Dict[str, object]]
    suffix = manifest_path.suffix.lower()
    if suffix == ".jsonl":
        records = []
        with manifest_path.open("r", encoding="utf-8") as handle:
            for line_no, line in enumerate(handle, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    item = json.loads(line)
                except json.JSONDecodeError as exc:
                    raise ValueError(
                        f"{manifest_path}:{line_no}: invalid JSONL record"
                    ) from exc
                if item.get("record_type", "sample") == "sample":
                    records.append(item)
    elif suffix == ".json":
        data = json.loads(manifest_path.read_text(encoding="utf-8"))
        if isinstance(data, dict):
            records = list(data.get("records", []))
        elif isinstance(data, list):
            records = data
        else:
            raise ValueError("JSON manifest must be a list or an object with records")
    elif suffix == ".csv":
        with manifest_path.open("r", newline="", encoding="utf-8") as handle:
            records = list(csv.DictReader(handle))
    else:
        raise ValueError(
            "manifest must be .jsonl, .json, or .csv; "
            f"got {manifest_path.suffix or '<none>'}"
        )

    parsed: List[TraceRecord] = []
    base_dir = manifest_path.parent
    for row_no, item in enumerate(records, 1):
        try:
            status = str(item.get("status", "ok")).lower()
            if status != "ok":
                raise ValueError(f"sample status is {status!r}, not 'ok'")
            group = normalize_group(str(item.get("group", "")))
            sample_index = int(item.get("sample_index", row_no - 1))
            raw_path_value = item.get("raw_trace_path") or item.get("trace_path")
            if not raw_path_value:
                raise ValueError("missing raw_trace_path")
            raw_path = Path(str(raw_path_value))
            if not raw_path.is_absolute():
                raw_path = base_dir / raw_path
            parsed.append(
                TraceRecord(
                    sample_index=sample_index,
                    group=group,
                    raw_trace_path=raw_path.resolve(),
                    uart_digest=(
                        str(item["uart_digest"])
                        if item.get("uart_digest") not in {None, ""}
                        else None
                    ),
                )
            )
        except (TypeError, ValueError) as exc:
            raise ValueError(f"invalid manifest sample record {row_no}: {exc}") from exc

    if not parsed:
        raise ValueError("manifest contains no sample records")
    return parsed


def parse_text_trace(path: Path) -> List[float]:
    values: List[float] = []
    for token in path.read_text(encoding="utf-8").replace(",", " ").split():
        try:
            values.append(float(token))
        except ValueError:
            continue
    return values


def parse_csv_trace_column(path: Path, trace_column: str) -> List[float]:
    values: List[float] = []
    with path.open("r", newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        if reader.fieldnames is None or trace_column not in reader.fieldnames:
            raise ValueError(f"{path} does not contain CSV column {trace_column!r}")
        for row_no, row in enumerate(reader, 2):
            try:
                values.append(float(row[trace_column]))
            except (TypeError, ValueError) as exc:
                raise ValueError(
                    f"{path}:{row_no}: non-numeric value in {trace_column!r}"
                ) from exc
    return values


def load_trace(path: Path, trace_column: Optional[str] = None) -> List[float]:
    if not path.exists():
        raise FileNotFoundError(f"trace file not found: {path}")
    suffix = path.suffix.lower()
    if trace_column:
        return parse_csv_trace_column(path, trace_column)
    if suffix == ".json":
        data = json.loads(path.read_text(encoding="utf-8"))
        if isinstance(data, dict):
            data = data.get("samples")
        if not isinstance(data, list):
            raise ValueError(f"{path} JSON trace must be a list or samples object")
        return [float(value) for value in data]
    return parse_text_trace(path)


def finite_or_none(value: float) -> Optional[float]:
    return value if math.isfinite(value) else None


def t_to_text(value: float) -> str:
    if math.isfinite(value):
        return f"{value:.12g}"
    if value > 0:
        return "inf"
    return "-inf"


def compute_welch_rows(
    records: Sequence[TraceRecord],
    trace_column: Optional[str] = None,
) -> Tuple[Dict[str, object], List[Dict[str, object]]]:
    fixed = RunningStats()
    random = RunningStats()

    for record in records:
        values = load_trace(record.raw_trace_path, trace_column=trace_column)
        if record.group == FIXED_GROUP:
            fixed.add(values)
        elif record.group == RANDOM_GROUP:
            random.add(values)
        else:
            raise ValueError(f"unsupported group after normalization: {record.group}")

    if fixed.n < 2 or random.n < 2:
        raise ValueError(
            f"Welch t-test requires at least two traces per group; "
            f"fixed={fixed.n} random={random.n}"
        )
    if len(fixed.sums) != len(random.sums):
        raise ValueError(
            f"fixed/random trace length mismatch: {len(fixed.sums)} vs {len(random.sums)}"
        )

    rows: List[Dict[str, object]] = []
    max_abs_t = -1.0
    max_abs_t_index = -1
    nonfinite_t = False
    for idx in range(len(fixed.sums)):
        mean_fixed = fixed.mean(idx)
        mean_random = random.mean(idx)
        var_fixed = fixed.variance(idx)
        var_random = random.variance(idx)
        denominator = math.sqrt((var_fixed / fixed.n) + (var_random / random.n))
        if denominator == 0.0:
            if mean_fixed == mean_random:
                t_value = 0.0
            else:
                t_value = math.copysign(math.inf, mean_fixed - mean_random)
        else:
            t_value = (mean_fixed - mean_random) / denominator

        abs_t = abs(t_value)
        if not math.isfinite(abs_t):
            nonfinite_t = True
            rank_value = math.inf
        else:
            rank_value = abs_t
        if rank_value > max_abs_t:
            max_abs_t = rank_value
            max_abs_t_index = idx

        rows.append(
            {
                "sample": idx,
                "n_fixed": fixed.n,
                "n_random": random.n,
                "mean_fixed": mean_fixed,
                "mean_random": mean_random,
                "variance_fixed": var_fixed,
                "variance_random": var_random,
                "t_value": t_value,
                "abs_t": abs_t,
            }
        )

    summary = {
        "trace_count_fixed": fixed.n,
        "trace_count_random": random.n,
        "trace_length": len(fixed.sums),
        "max_abs_t": finite_or_none(max_abs_t),
        "max_abs_t_text": t_to_text(max_abs_t),
        "max_abs_t_nonfinite": nonfinite_t,
        "max_abs_t_index": max_abs_t_index,
    }
    return summary, rows


def write_json_summary(path: Path, summary: Dict[str, object]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def write_csv_rows(path: Path, rows: Sequence[Dict[str, object]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fieldnames = [
        "sample",
        "n_fixed",
        "n_random",
        "mean_fixed",
        "mean_random",
        "variance_fixed",
        "variance_random",
        "t_value",
        "abs_t",
    ]
    with path.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        for row in rows:
            safe_row = dict(row)
            safe_row["t_value"] = t_to_text(float(row["t_value"]))
            safe_row["abs_t"] = t_to_text(float(row["abs_t"]))
            writer.writerow(safe_row)


def analyze_manifest(
    manifest_path: Path,
    threshold: float,
    trace_column: Optional[str],
) -> Tuple[Dict[str, object], List[Dict[str, object]]]:
    records = load_manifest(manifest_path)
    summary, rows = compute_welch_rows(records, trace_column=trace_column)
    max_abs_t = float("inf") if summary["max_abs_t_nonfinite"] else float(summary["max_abs_t"])
    threshold_exceeded = max_abs_t >= threshold
    summary.update(
        {
            "manifest": str(manifest_path.resolve()),
            "threshold": threshold,
            "threshold_exceeded": threshold_exceeded,
            "claim_boundary": (
                "This is a statistical summary only. Do not claim TVLA has passed "
                "until real fixed-vs-random traces from the target setup are captured, "
                "reviewed, and archived."
            ),
        }
    )
    return summary, rows


def write_fixture_trace(path: Path, values: Iterable[float]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(f"{value:.9f}" for value in values) + "\n", encoding="utf-8")


def build_fixture(root: Path, leaking: bool) -> Path:
    manifest_path = root / ("leaking.jsonl" if leaking else "balanced.jsonl")
    trace_dir = root / ("leaking_traces" if leaking else "balanced_traces")
    records = []
    trace_len = 64
    leakage_index = 17
    for idx in range(24):
        for group in (FIXED_GROUP, RANDOM_GROUP):
            values = []
            for sample in range(trace_len):
                base = ((idx * 11 + sample * 7) % 29) / 29.0
                ripple = ((idx + sample * 3) % 5) * 0.01
                value = base + ripple
                if leaking and group == FIXED_GROUP and sample == leakage_index:
                    value += 1.75
                values.append(value)
            trace_path = trace_dir / f"trace_{idx:03d}_{group}.csv"
            write_fixture_trace(trace_path, values)
            records.append(
                {
                    "sample_index": len(records),
                    "group": group,
                    "trigger_time_utc": "2026-01-01T00:00:00.000000Z",
                    "uart_digest": "fixture",
                    "raw_trace_path": str(trace_path.relative_to(manifest_path.parent)),
                }
            )
    with manifest_path.open("w", encoding="utf-8") as handle:
        for record in records:
            handle.write(json.dumps(record, sort_keys=True) + "\n")
    return manifest_path


def run_self_test() -> int:
    with tempfile.TemporaryDirectory(prefix="tvla_self_test_") as tmp:
        root = Path(tmp)
        balanced_manifest = build_fixture(root, leaking=False)
        leaking_manifest = build_fixture(root, leaking=True)

        balanced_summary, balanced_rows = analyze_manifest(
            balanced_manifest, DEFAULT_THRESHOLD, trace_column=None
        )
        leaking_summary, leaking_rows = analyze_manifest(
            leaking_manifest, DEFAULT_THRESHOLD, trace_column=None
        )

        if balanced_summary["threshold_exceeded"]:
            raise AssertionError(f"balanced fixture unexpectedly exceeded threshold: {balanced_summary}")
        if not leaking_summary["threshold_exceeded"]:
            raise AssertionError(f"leaking fixture did not exceed threshold: {leaking_summary}")
        if leaking_summary["max_abs_t_index"] != 17:
            raise AssertionError(f"leaking fixture peak index mismatch: {leaking_summary}")
        if len(balanced_rows) != 64 or len(leaking_rows) != 64:
            raise AssertionError("fixture analysis row count mismatch")

    print(
        "SELFTEST PASS "
        f"balanced_max={balanced_summary['max_abs_t_text']} "
        f"leaking_max={leaking_summary['max_abs_t_text']} "
        f"leaking_index={leaking_summary['max_abs_t_index']}"
    )
    return 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Analyze fixed-vs-random TVLA trace manifests with Welch t-tests."
    )
    parser.add_argument("manifest", nargs="?", type=Path, help="capture manifest (.jsonl/.json/.csv)")
    parser.add_argument("--self-test", action="store_true", help="run generated fixture tests")
    parser.add_argument("--threshold", type=float, default=DEFAULT_THRESHOLD)
    parser.add_argument("--trace-column", help="CSV column containing sample amplitudes")
    parser.add_argument("--json-out", type=Path, help="write JSON summary")
    parser.add_argument("--csv-out", type=Path, help="write per-sample CSV summary")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.self_test:
        return run_self_test()
    if args.threshold <= 0.0:
        raise SystemExit("--threshold must be positive")
    if args.manifest is None:
        raise SystemExit("manifest is required unless --self-test is used")

    try:
        summary, rows = analyze_manifest(args.manifest, args.threshold, args.trace_column)
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        raise SystemExit(str(exc)) from exc
    if args.json_out:
        write_json_summary(args.json_out, summary)
    if args.csv_out:
        write_csv_rows(args.csv_out, rows)

    print(
        "TVLA SUMMARY "
        f"fixed={summary['trace_count_fixed']} "
        f"random={summary['trace_count_random']} "
        f"len={summary['trace_length']} "
        f"max_abs_t={summary['max_abs_t_text']} "
        f"index={summary['max_abs_t_index']} "
        f"threshold={summary['threshold']} "
        f"exceeded={summary['threshold_exceeded']}"
    )
    return 1 if summary["threshold_exceeded"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
