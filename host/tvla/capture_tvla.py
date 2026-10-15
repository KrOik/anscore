#!/usr/bin/env python3
"""Capture-manifest harness for fixed-vs-random TVLA runs.

This script records TVLA metadata and raw trace file locations. It can drive an
external trace acquisition command, or generate explicit synthetic fixtures for
offline harness tests. Synthetic output is never physical TVLA evidence.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import random
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, List, Optional, Sequence


FIXED_GROUP = "fixed"
RANDOM_GROUP = "random"
PASS_LINE_RE = re.compile(r"^\s*([A-Z0-9_]+)\s+PASS\b(.*)$")
HEX_FIELD_RE = re.compile(r"\b([A-Z][A-Z0-9_]*)=([0-9A-Fa-f]+)\b")


def utc_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def safe_stamp() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")


def parse_seed(value: str) -> int:
    return int(value, 0)


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8", errors="replace")).hexdigest()


def extract_uart_digest(text: str) -> Optional[str]:
    parts: List[str] = []
    for line in text.splitlines():
        match = PASS_LINE_RE.match(line)
        if not match:
            continue
        tag = match.group(1)
        fields = HEX_FIELD_RE.findall(match.group(2))
        if fields:
            rendered = ",".join(f"{key}={value.upper()}" for key, value in fields)
            parts.append(f"{tag}:{rendered}")
    if parts:
        return ";".join(parts)

    fields = HEX_FIELD_RE.findall(text)
    if fields:
        return ",".join(f"{key}={value.upper()}" for key, value in fields)
    return None


def render_command(template: str, context: Dict[str, str]) -> str:
    try:
        return template.format(**context)
    except KeyError as exc:
        raise ValueError(f"unknown command placeholder {{{exc.args[0]}}}") from exc


def run_command(
    template: str,
    context: Dict[str, str],
    timeout: float,
    cwd: Path,
) -> subprocess.CompletedProcess[str]:
    command = render_command(template, context)
    return subprocess.run(
        command,
        shell=True,
        cwd=str(cwd),
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )


def choose_groups(count: int, mode: str, seed: int) -> List[str]:
    if count < 4:
        raise ValueError("TVLA capture needs at least four samples, two per group")
    if mode == "alternating":
        return [FIXED_GROUP if idx % 2 == 0 else RANDOM_GROUP for idx in range(count)]
    if mode == "balanced-random":
        groups = [FIXED_GROUP] * (count // 2) + [RANDOM_GROUP] * (count - count // 2)
        rng = random.Random(seed)
        rng.shuffle(groups)
        return groups
    if mode == "random":
        rng = random.Random(seed)
        groups = [rng.choice([FIXED_GROUP, RANDOM_GROUP]) for _ in range(count)]
        while groups.count(FIXED_GROUP) < 2:
            groups[groups.index(RANDOM_GROUP)] = FIXED_GROUP
        while groups.count(RANDOM_GROUP) < 2:
            groups[groups.index(FIXED_GROUP)] = RANDOM_GROUP
        return groups
    raise ValueError(f"unsupported group mode: {mode}")


def write_synthetic_trace(
    path: Path,
    sample_index: int,
    group: str,
    seed: int,
    length: int,
    leakage_index: int,
    leakage_amplitude: float,
) -> None:
    rng = random.Random(seed ^ (sample_index * 0x9E3779B1))
    values = []
    for idx in range(length):
        baseline = math.sin(idx * 0.071) * 0.05
        noise = 0.0 if leakage_amplitude == 0.0 else (rng.random() - 0.5) * 0.01
        value = baseline + noise
        if (
            leakage_amplitude != 0.0
            and group == FIXED_GROUP
            and idx == leakage_index
        ):
            value += leakage_amplitude
        values.append(value)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(f"{value:.9f}" for value in values) + "\n", encoding="utf-8")


def relative_to_manifest(path: Path, manifest_path: Path) -> str:
    try:
        return str(path.resolve().relative_to(manifest_path.parent.resolve()))
    except ValueError:
        return str(path.resolve())


def build_context(
    sample_index: int,
    group: str,
    trace_path: Path,
    trigger_time_utc: str,
    seed: int,
    session_label: str,
) -> Dict[str, str]:
    return {
        "sample_index": str(sample_index),
        "group": group,
        "trace_path": str(trace_path),
        "trace_path_posix": trace_path.as_posix(),
        "trigger_time_utc": trigger_time_utc,
        "seed": str(seed),
        "seed_hex": f"0x{seed:08x}",
        "session_label": session_label,
    }


def parse_metadata(values: Sequence[str]) -> Dict[str, str]:
    metadata: Dict[str, str] = {}
    for item in values:
        if "=" not in item:
            raise ValueError(f"metadata must use key=value form: {item!r}")
        key, value = item.split("=", 1)
        key = key.strip()
        if not key:
            raise ValueError(f"metadata key is empty in {item!r}")
        metadata[key] = value.strip()
    return metadata


def default_manifest_path(session_label: str) -> Path:
    return Path("captures") / "tvla" / session_label / "manifest.jsonl"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Record fixed-vs-random TVLA capture metadata and raw trace paths."
    )
    parser.add_argument("--manifest", type=Path, help="output JSONL manifest path")
    parser.add_argument("--trace-dir", type=Path, help="directory for raw trace files")
    parser.add_argument("--count", type=int, default=100)
    parser.add_argument(
        "--group-mode",
        choices=["alternating", "balanced-random", "random"],
        default="balanced-random",
    )
    parser.add_argument("--seed", type=parse_seed, default=parse_seed("0x54564c41"))
    parser.add_argument("--session-label", default=f"tvla_{safe_stamp()}")
    parser.add_argument(
        "--trace-command",
        help=(
            "external acquisition command. Placeholders include {trace_path}, "
            "{sample_index}, {group}, {trigger_time_utc}, {seed_hex}, {session_label}."
        ),
    )
    parser.add_argument(
        "--uart-command",
        help="optional UART command whose PASS/digest output is recorded per sample",
    )
    parser.add_argument("--program-command", help="optional command run once before capture")
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument("--uart-timeout", type=float, default=10.0)
    parser.add_argument("--program-timeout", type=float, default=120.0)
    parser.add_argument("--synthetic-fixture", action="store_true")
    parser.add_argument("--synthetic-length", type=int, default=256)
    parser.add_argument("--synthetic-leakage-index", type=int, default=32)
    parser.add_argument("--synthetic-leakage-amplitude", type=float, default=0.0)
    parser.add_argument("--force", action="store_true", help="overwrite an existing manifest")
    parser.add_argument("--continue-on-error", action="store_true")
    parser.add_argument("--metadata", action="append", default=[], help="extra key=value metadata")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.synthetic_fixture and not args.trace_command:
        raise SystemExit("provide --trace-command or use explicit --synthetic-fixture")
    if args.count < 4:
        raise SystemExit("--count must be at least 4 so both TVLA groups have two traces")
    if args.synthetic_length <= 0:
        raise SystemExit("--synthetic-length must be positive")
    if not 0 <= args.synthetic_leakage_index < args.synthetic_length:
        raise SystemExit("--synthetic-leakage-index must be within the synthetic trace")

    root = Path.cwd().resolve()
    manifest_path = (args.manifest or default_manifest_path(args.session_label)).resolve()
    if manifest_path.exists() and not args.force:
        raise SystemExit(f"manifest already exists; use --force to overwrite: {manifest_path}")
    trace_dir = (args.trace_dir or (manifest_path.parent / "traces")).resolve()
    manifest_path.parent.mkdir(parents=True, exist_ok=True)
    trace_dir.mkdir(parents=True, exist_ok=True)
    metadata = parse_metadata(args.metadata)

    groups = choose_groups(args.count, args.group_mode, args.seed)
    session_record = {
        "record_type": "session",
        "session_label": args.session_label,
        "created_utc": utc_stamp(),
        "count": args.count,
        "group_mode": args.group_mode,
        "seed": args.seed,
        "synthetic_fixture": args.synthetic_fixture,
        "synthetic_fixture_warning": (
            "Synthetic fixture traces are not physical TVLA evidence."
            if args.synthetic_fixture
            else None
        ),
        "metadata": metadata,
    }
    sidecar_path = manifest_path.with_suffix(".session.json")
    sidecar_path.write_text(
        json.dumps(session_record, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )

    if args.program_command:
        context = build_context(
            sample_index=-1,
            group="setup",
            trace_path=trace_dir,
            trigger_time_utc=utc_stamp(),
            seed=args.seed,
            session_label=args.session_label,
        )
        result = run_command(args.program_command, context, args.program_timeout, root)
        if result.returncode != 0:
            sys.stderr.write(result.stdout)
            sys.stderr.write(result.stderr)
            raise SystemExit(f"program command failed with exit code {result.returncode}")

    failures = 0
    with manifest_path.open("w", encoding="utf-8") as manifest:
        for sample_index, group in enumerate(groups):
            trace_path = trace_dir / f"trace_{sample_index:06d}_{group}.csv"
            trigger_time_utc = utc_stamp()
            context = build_context(
                sample_index=sample_index,
                group=group,
                trace_path=trace_path,
                trigger_time_utc=trigger_time_utc,
                seed=args.seed,
                session_label=args.session_label,
            )
            record: Dict[str, object] = {
                "record_type": "sample",
                "sample_index": sample_index,
                "group": group,
                "trigger_time_utc": trigger_time_utc,
                "trigger_monotonic_ns": time.monotonic_ns(),
                "raw_trace_path": relative_to_manifest(trace_path, manifest_path),
                "raw_trace_sha256": None,
                "uart_digest": None,
                "uart_sha256": None,
                "status": "ok",
                "error": None,
                "synthetic_fixture": args.synthetic_fixture,
            }
            try:
                if args.synthetic_fixture:
                    write_synthetic_trace(
                        trace_path,
                        sample_index,
                        group,
                        args.seed,
                        args.synthetic_length,
                        args.synthetic_leakage_index,
                        args.synthetic_leakage_amplitude,
                    )
                else:
                    result = run_command(args.trace_command, context, args.timeout, root)
                    if result.returncode != 0:
                        raise RuntimeError(
                            f"trace command failed with exit code {result.returncode}: "
                            f"{result.stderr.strip() or result.stdout.strip()}"
                        )
                    if not trace_path.exists():
                        raise FileNotFoundError(
                            f"trace command did not create expected file: {trace_path}"
                        )

                record["raw_trace_sha256"] = sha256_file(trace_path)

                if args.uart_command:
                    uart_result = run_command(args.uart_command, context, args.uart_timeout, root)
                    uart_text = (uart_result.stdout or "") + (uart_result.stderr or "")
                    record["uart_sha256"] = sha256_text(uart_text)
                    record["uart_digest"] = extract_uart_digest(uart_text)
                    record["uart_returncode"] = uart_result.returncode
                    if uart_result.returncode != 0:
                        raise RuntimeError(
                            f"UART command failed with exit code {uart_result.returncode}: "
                            f"{uart_text.strip()}"
                        )
            except Exception as exc:  # noqa: BLE001 - manifest must record failures.
                failures += 1
                record["status"] = "error"
                record["error"] = str(exc)
                if not args.continue_on_error:
                    manifest.write(json.dumps(record, sort_keys=True) + "\n")
                    manifest.flush()
                    raise SystemExit(str(exc))

            manifest.write(json.dumps(record, sort_keys=True) + "\n")
            manifest.flush()

    print(
        "TVLA CAPTURE "
        f"manifest={manifest_path} "
        f"sidecar={sidecar_path} "
        f"samples={args.count} "
        f"failures={failures} "
        f"synthetic={args.synthetic_fixture}"
    )
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
