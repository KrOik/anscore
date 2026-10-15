import argparse
import csv
import math
from pathlib import Path

import numpy as np


MIC_NAMES = ["mic0", "mic1", "mic2", "mic3", "mic4", "mic5", "mic_center"]
PAIR_DEFS = [
    ("p03", 0, 3),
    ("p14", 1, 4),
    ("p25", 2, 5),
]


def load_capture(path: Path):
    with path.open(newline="", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        rows = list(reader)
    data = np.zeros((len(rows), len(MIC_NAMES)), dtype=np.float64)
    seq = np.zeros(len(rows), dtype=np.uint16)
    for i, row in enumerate(rows):
        seq[i] = int(row["seq"])
        for j, name in enumerate(MIC_NAMES):
            data[i, j] = int(row[name])
    return seq, data


def highpass(x):
    return x - np.mean(x)


def best_lag(a, b, max_lag):
    a = highpass(a)
    b = highpass(b)
    best_score = None
    best = 0
    scores = []
    for lag in range(-max_lag, max_lag + 1):
        if lag < 0:
            aa = a[-lag:]
            bb = b[: len(aa)]
        elif lag > 0:
            aa = a[: len(a) - lag]
            bb = b[lag:]
        else:
            aa = a
            bb = b
        denom = math.sqrt(float(np.dot(aa, aa) * np.dot(bb, bb))) + 1e-9
        score = float(np.dot(aa, bb) / denom)
        scores.append(score)
        if best_score is None or score > best_score:
            best_score = score
            best = lag
    ranked = sorted(scores, reverse=True)
    gap = ranked[0] - ranked[1] if len(ranked) > 1 else 0.0
    return best, float(best_score), float(gap)


def sector_from_vector(vx, vy, led_offset=0):
    angle = math.atan2(vy, vx)
    sector = int(round(angle / (2.0 * math.pi / 12.0))) % 12
    return (sector + led_offset) % 12


def analyze(data, sample_rate, window, hop, max_lag, led_offset, energy_gate, corr_gap_gate):
    results = []
    for start in range(0, data.shape[0] - window + 1, hop):
        frame = data[start : start + window, :]
        outer = frame[:, :6]
        energy = float(np.mean(np.abs(outer - np.mean(outer, axis=0))))
        delays = []
        corr_scores = []
        corr_gaps = []
        for _, a_idx, b_idx in PAIR_DEFS:
            lag, score, gap = best_lag(outer[:, a_idx], outer[:, b_idx], max_lag)
            delays.append(lag)
            corr_scores.append(score)
            corr_gaps.append(gap)

        d03, d14, d25 = delays
        # Same provisional geometry as the FPGA core; LED offset handles board rotation.
        vx = d03 + d14 - d25
        vy = 2 * (d14 + d25)
        led = sector_from_vector(vx, vy, led_offset)
        valid = energy >= energy_gate and min(corr_gaps) >= corr_gap_gate and (abs(vx) + abs(vy)) > 0
        results.append(
            {
                "time": start / sample_rate,
                "energy": energy,
                "d03": d03,
                "d14": d14,
                "d25": d25,
                "c03": corr_scores[0],
                "c14": corr_scores[1],
                "c25": corr_scores[2],
                "g03": corr_gaps[0],
                "g14": corr_gaps[1],
                "g25": corr_gaps[2],
                "vx": vx,
                "vy": vy,
                "led": led,
                "valid": valid,
            }
        )
    return results


def write_results(results, out_path: Path):
    out_path.parent.mkdir(parents=True, exist_ok=True)
    fields = [
        "time",
        "energy",
        "d03",
        "d14",
        "d25",
        "c03",
        "c14",
        "c25",
        "g03",
        "g14",
        "g25",
        "vx",
        "vy",
        "led",
        "valid",
    ]
    with out_path.open("w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fields)
        writer.writeheader()
        for row in results:
            writer.writerow(row)


def print_summary(results):
    valid = [r for r in results if r["valid"]]
    print(f"frames={len(results)} valid={len(valid)}")
    if not valid:
        return
    counts = {i: 0 for i in range(12)}
    for row in valid:
        counts[row["led"]] += 1
    print("led_hist=" + " ".join(f"{i}:{counts[i]}" for i in range(12)))
    print("first_valid:")
    for row in valid[:20]:
        print(
            f"t={row['time']:.3f}s led={row['led']:02d} "
            f"d=({row['d03']:+d},{row['d14']:+d},{row['d25']:+d}) "
            f"v=({row['vx']:+d},{row['vy']:+d}) "
            f"e={row['energy']:.1f} g=({row['g03']:.3f},{row['g14']:.3f},{row['g25']:.3f})"
        )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("csv", type=Path)
    parser.add_argument("--sample-rate", type=float, default=0)
    parser.add_argument("--window", type=int, default=256)
    parser.add_argument("--hop", type=int, default=64)
    parser.add_argument("--max-lag", type=int, default=8)
    parser.add_argument("--led-offset", type=int, default=0)
    parser.add_argument("--energy-gate", type=float, default=40.0)
    parser.add_argument("--corr-gap-gate", type=float, default=0.005)
    parser.add_argument("--out", type=Path, default=None)
    args = parser.parse_args()

    seq, data = load_capture(args.csv)
    sample_rate = args.sample_rate
    if sample_rate <= 0:
        report = args.csv.parent / "report.txt"
        if report.exists():
            for line in report.read_text(encoding="utf-8").splitlines():
                if line.startswith("sample_rate="):
                    sample_rate = float(line.split("=", 1)[1])
                    break
    if sample_rate <= 0:
        raise SystemExit("sample rate missing; pass --sample-rate")

    results = analyze(
        data,
        sample_rate,
        args.window,
        args.hop,
        args.max_lag,
        args.led_offset,
        args.energy_gate,
        args.corr_gap_gate,
    )
    out_path = args.out or (args.csv.parent / "offline_doa.csv")
    write_results(results, out_path)
    print(f"out={out_path}")
    print_summary(results)


if __name__ == "__main__":
    main()
