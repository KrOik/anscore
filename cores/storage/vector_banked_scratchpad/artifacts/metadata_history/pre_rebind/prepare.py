"""One-shot expansion and independent scalar reference; requires root approval.

This module is authored only. Do not run it to discover/fix failures without a
new explicit root approval. It refuses an existing output directory.
"""
import argparse
import hashlib
import json
from pathlib import Path

from oracle import WordModel


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def packed(values, width):
    return sum(value << (i * width) for i, value in enumerate(values))


def build(raw, profile):
    p = profile
    lanes, banks, words = p["lanes"], p["banks"], p["words"]
    capacity, all_lanes = banks * words, (1 << lanes) - 1
    data_mask, tag_mask = (1 << p["data_w"]) - 1, (1 << p["tag_w"]) - 1
    model, vectors = WordModel(p), []
    rng = raw["seed"]

    def random32():
        nonlocal rng
        rng = (rng * raw["lcg_multiplier"] + raw["lcg_increment"]) & 0xffffffff
        return rng

    def word():
        return ((random32() << 32) | random32()) & data_mask

    def add(label, mask, write, addresses, data=None, kind=0):
        index = len(vectors)
        v = {"id": index, "label": label, "kind": kind, "mask": mask,
             "write": write, "addresses": list(addresses),
             "data": [word() for _ in range(lanes)] if data is None else list(data),
             "tag": random32() & tag_mask,
             "hold": raw["held_response_cycles"] + index % 4, "gap": index % 3}
        if kind in (1, 2):
            model.cancel(v, kind)
            v["expected"] = None
        elif kind == 4:
            v["expected"] = None  # reset changes control only, never this RAM image
        else:
            v["expected"] = model.apply(v)
        vectors.append(v)

    def probe(label, addresses):
        for start in range(0, len(addresses), lanes):
            chunk = addresses[start:start + lanes]
            add(label, (1 << len(chunk)) - 1, 0,
                chunk + [0xffffffff] * (lanes - len(chunk)))

    add("uninitialized_read", 1, 0, [0] * lanes)
    for base in range(0, capacity, lanes):
        active = min(lanes, capacity - base)
        addresses = [base + i if i < active else 0xffffffff for i in range(lanes)]
        data = [((base + i) * raw["initial_word_multiplier"] ^
                 raw["initial_word_xor"]) & data_mask for i in range(lanes)]
        add("initialize", (1 << active) - 1, (1 << active) - 1, addresses, data)
    addresses = [i % capacity for i in range(lanes)]
    add("parallel_write", all_lanes, all_lanes, addresses)
    add("parallel_read", all_lanes, 0, addresses)
    addresses = [(i % words) * banks for i in range(lanes)]
    add("one_bank_rows_write", all_lanes, all_lanes, addresses)
    add("one_bank_rows_read", all_lanes, 0, addresses)
    for selector in raw["alias_write_masks"]:
        write = {"ALL": all_lanes, "NONE": 0,
                 "EVEN": sum(1 << i for i in range(0, lanes, 2)),
                 "ODD": sum(1 << i for i in range(1, lanes, 2))}[selector]
        add("alias_" + selector, all_lanes, write, [0] * lanes)
    for bad in raw["invalid_addresses"]:
        bad = capacity if bad == "CAPACITY" else bad
        addresses = [0] * lanes
        addresses[-1] = bad
        add("atomic_reject_" + str(bad), all_lanes, all_lanes, addresses)
        probe("after_reject", [0, capacity - 1])
    add("all_masked_invalid", 0, all_lanes, [0xffffffff] * lanes)
    addresses = [i % capacity for i in range(lanes)]
    addresses[-1] = 0xffffffff
    add("masked_bad_last", all_lanes & ~(1 << (lanes - 1)), all_lanes, addresses)
    for i in range(raw["mixed_vectors_per_profile"]):
        mask = random32() & all_lanes
        write = random32() & all_lanes
        addresses = [random32() % capacity for _ in range(lanes)]
        if i % 7 == 0:
            addresses = [0] * lanes
        if i % 11 == 0:
            addresses[-1] = 0xffffffff
        add("mixed_" + str(i), mask, write, addresses)
    for key, kind in [("preflight", 1), ("after_first_issue", 2), ("held_response", 3)]:
        data = [(raw["reset_write_bases"][key] + i) & data_mask for i in range(lanes)]
        add("cancel_" + key, all_lanes, all_lanes, [0] * lanes, data, kind)
        probe("after_" + key, [0, capacity - 1])
    add("idle_reset", 0, 0, [0] * lanes, kind=4)
    probe("after_idle_reset", [0, capacity - 1])
    probe("final_full_readback", list(range(capacity)))
    return vectors


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--raw", required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    raw_path, destination = root / args.raw, root / args.out
    destination = destination.resolve()
    if not destination.is_relative_to(root / "prepared"):
        raise ValueError("output must stay under this package's prepared directory")
    if destination.exists():
        raise FileExistsError("one-shot prepare refuses an existing output path")
    raw = json.loads(raw_path.read_text(encoding="utf-8"))
    if raw["schema"] != "vector-banked-raw-recipes-v1":
        raise ValueError("raw input schema")
    destination.mkdir(parents=True, exist_ok=False)
    expected = {}
    outputs = {}
    for profile in raw["profiles"]:
        vectors = build(raw, profile)
        expected[profile["name"]] = {"profile": profile, "vectors": vectors}
        lines = [str(len(vectors))]
        for v in vectors:
            e = v["expected"] or {"status": 0, "error_mask": 0, "data": [0] * profile["lanes"],
                                   "known_mask": 0, "accesses": 0, "rounds": 0}
            fields = [str(v["id"]), str(v["kind"]), format(v["mask"], "x"),
                      format(v["write"], "x"), format(packed(v["addresses"], 32), "x"),
                      format(packed(v["data"], profile["data_w"]), "x"), format(v["tag"], "x"),
                      str(e["status"]), format(e["error_mask"], "x"),
                      format(packed(e["data"], profile["data_w"]), "x"),
                      format(e["known_mask"], "x"), str(e["accesses"]), str(e["rounds"]),
                      str(v["hold"]), str(v["gap"])]
            lines.append(" ".join(fields))
        target = destination / (profile["name"] + ".vec")
        target.write_text("\n".join(lines) + "\n", encoding="ascii", newline="\n")
        outputs[target.name] = {"sha256": digest(target), "vectors": len(vectors)}
    oracle_path = destination / "oracle_expected.json"
    oracle_path.write_text(json.dumps(expected, indent=2) + "\n", encoding="utf-8", newline="\n")
    manifest = {"schema": "vector-banked-prepared-v1", "status": "PREPARED_ONLY_NOT_HDL_PASS",
                "raw_input_sha256": digest(raw_path),
                "source_seal_sha256": digest(root / "SOURCE_SEAL.json"),
                "oracle_expected_sha256": digest(oracle_path), "vectors": outputs,
                "hdl_invocations": 0, "preparation_invocations": 1}
    (destination / "prepared_manifest.json").write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8", newline="\n")
    print(json.dumps({"status": manifest["status"], "profiles": len(outputs),
                      "manifest": str((destination / "prepared_manifest.json").relative_to(root)),
                      "manifest_sha256": digest(destination / "prepared_manifest.json")}))


if __name__ == "__main__":
    main()
