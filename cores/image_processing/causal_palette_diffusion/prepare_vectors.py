# SPDX-License-Identifier: Apache-2.0
"""Sole reviewed isolated preparation child; no HDL or older model imports."""
import hashlib
import json
from pathlib import Path
import random
import runpy
import sys

root = Path(__file__).resolve().parent
out = Path(sys.argv[1]).resolve()
out.mkdir(exist_ok=False)
oracle = runpy.run_path(str(root / "reference_model.py"))["diffuse"]
profiles = json.loads((root / "PRECHECK_PLAN.json").read_text())["profiles"]
receipt = {"oracle_imports": 1, "oracle_preparations": 1, "profiles": [], "files": []}
for p in profiles:
    w, h, b = p["w"], p["h"], p["b"]
    n, m = w * h, (1 << b) - 1
    rng = random.Random(4300 + w * 19 + h * 3 + b)
    inputs, expect, levels, audits = [], [], [], []
    palettes = [(0, m), (m // 4, 3 * m // 4), (1, 2), (m - 1, m),
                (0, 1), (0, m - 1), (m // 2 - 1, m // 2 + 1),
                (2, m - 2), (0, m), (m // 3, 2 * m // 3)]
    for epoch, (low, high) in enumerate(palettes):
        raw = []
        for i in range(n):
            if epoch == 0: value = 0
            elif epoch == 1: value = m
            elif epoch == 2: value = m // 2
            elif epoch == 3: value = (i * m) // max(1, n - 1)
            elif epoch == 4: value = m if (i + i // w) % 2 else 0
            elif epoch == 5: value = (low + high) // 2
            elif epoch == 6: value = m // 2
            else: value = rng.randrange(m + 1)
            if p["wrap"]:
                if epoch < 7: rgb = (value << 16) | (value << 8) | value
                else: rgb = rng.randrange(1 << 24)
                inputs.append(rgb)
                value = (77 * (rgb >> 16) + 150 * ((rgb >> 8) & 255) + 29 * (rgb & 255)) // 256
            else: inputs.append(value)
            raw.append(value)
        expected, audit = oracle(raw, w, h, b, low, high)
        expect.extend(level | (code << b) for level, code in expected)
        levels.append(low | (high << b))
        audits.append(audit)
    folder = out / p["name"]
    folder.mkdir()
    for name, values in (("input.hex", inputs), ("expected.hex", expect), ("palette.hex", levels)):
        path = folder / name
        path.write_text("".join(f"{v:x}\n" for v in values), encoding="ascii", newline="\n")
        receipt["files"].append({"path": str(path.relative_to(out)), "bytes": path.stat().st_size,
                                 "sha256": hashlib.sha256(path.read_bytes()).hexdigest()})
    receipt["profiles"].append({"name": p["name"], "pixels": n * 10, "audits": audits})
(out / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n", encoding="utf-8")
print("B43_C_PREP_PASS profiles=4 oracle_imports=1 oracle_preparations=1", flush=True)
