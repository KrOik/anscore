"""Read the six already-produced text logs; never rerun an oracle or HDL child."""
import argparse
import hashlib
import json
import re
from pathlib import Path


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--prepared", required=True)
    parser.add_argument("--artifacts", required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    prepared, artifacts = root / args.prepared, root / args.artifacts
    manifest = json.loads((prepared / "prepared_manifest.json").read_text())
    expected_path = prepared / "oracle_expected.json"
    if sha(expected_path) != manifest["oracle_expected_sha256"]:
        raise ValueError("oracle expected bytes changed")
    expected = json.loads(expected_path.read_text())
    summary = {}
    for name, item in expected.items():
        profile, vectors = item["profile"], item["vectors"]
        text_path = artifacts / ("sim_" + name + ".stdout.log")
        text = text_path.read_text(encoding="utf-8")
        responses, held, cancellations, accepted, banks = {}, {}, {}, set(), {}
        passes = [];finishes = 0;idle = set();accepted_kinds = {}
        patterns = {
            'ACCEPT':r'ACCEPT \d+ \d+ \d+',
            'BANK':r'BANK \d+ \d+ \d+ \d+ \d+ [01] [0-9a-f]+',
            'RESP':r'RESP \d+ \d+ [0-9a-f]+ [0-9a-f]+ [0-9a-fxz]+ [0-9a-f]+ \d+ \d+',
            'HELD':r'HELD \d+ \d+ [0-9a-f]+ [0-9a-f]+ [0-9a-fxz]+ [0-9a-f]+ \d+ \d+',
            'CANCEL':r'CANCEL \d+ \d+ \d+',
            'IDLE_RESET':r'IDLE_RESET \d+',
            'PASS':r'PASS vectors=\d+ responses=\d+ cancellations=\d+ requests=\d+ held=\d+ cycles=\d+'
        }
        for line in text.splitlines():
            if re.fullmatch(r'sim[/\\]tb_vector_banked_scratchpad\.sv:\d+: \$finish called at \d+ \(1ps\)',line):
                finishes += 1
                continue
            fields = line.split()
            if not fields or fields[0] not in patterns or not re.fullmatch(patterns[fields[0]],line):
                raise ValueError('malformed or unexpected simulator log line: '+line)
            key = fields[0]
            if key == "ACCEPT":
                idx = int(fields[1])
                if idx in accepted:
                    raise ValueError("duplicate accept")
                accepted.add(idx)
                accepted_kinds[idx] = int(fields[2])
            elif key in ("RESP", "HELD"):
                dest = responses if key == "RESP" else held
                idx = int(fields[1])
                if idx in dest:
                    raise ValueError("duplicate completion")
                dest[idx] = fields
            elif key == "CANCEL":
                idx = int(fields[1])
                if idx in cancellations:
                    raise ValueError("duplicate cancellation")
                cancellations[idx] = [int(x) for x in fields[2:]]
            elif key == "BANK":
                banks.setdefault(int(fields[1]), []).append(fields)
            elif key == "PASS":
                passes.append({k: int(v) for k, v in (x.split("=") for x in fields[1:])})
            elif key == 'IDLE_RESET':
                idx = int(fields[1])
                if idx in idle: raise ValueError('duplicate idle reset')
                idle.add(idx)
        if finishes != 1 or len(passes) != 1 or passes[0]["cancellations"] != 3:
            raise ValueError("missing final PASS or cancellation coverage")
        normal = {v["id"] for v in vectors if v["kind"] == 0}
        if set(responses) != normal or set(held) != {v["id"] for v in vectors if v["kind"] == 3}:
            raise ValueError("response inventory mismatch")
        if accepted != {v["id"] for v in vectors if v["kind"] != 4}:
            raise ValueError("accepted inventory mismatch")
        if accepted_kinds != {v['id']:v['kind'] for v in vectors if v['kind'] != 4} or idle != {v['id'] for v in vectors if v['kind'] == 4}:
            raise ValueError('accepted-kind or idle-reset inventory mismatch')
        if set(cancellations) != {v["id"] for v in vectors if v["kind"] in (1, 2, 3)}:
            raise ValueError("cancellation inventory mismatch")
        for v in vectors:
            idx, e = v["id"], v["expected"]
            if v["kind"] in (0, 3):
                if v['kind'] == 3 and cancellations[idx] != [3,e['accesses']]:
                    raise ValueError('held cancellation request count mismatch')
                fields = (responses if v["kind"] == 0 else held)[idx]
                numeric = [int(fields[2]), int(fields[3], 16), int(fields[4], 16),
                           int(fields[6], 16), int(fields[7]), int(fields[8])]
                if numeric != [e["status"], e["mask"], e["error_mask"], e["tag"], e["accesses"], e["rounds"]]:
                    raise ValueError("completion field mismatch " + name + ":" + str(idx))
                width = profile["data_w"] // 4
                hex_data = fields[5].lower().rjust(width * profile["lanes"], "0")
                for lane in range(profile["lanes"]):
                    if e["known_mask"] & (1 << lane):
                        end = len(hex_data) - lane * width
                        if int(hex_data[end - width:end], 16) != e["data"][lane]:
                            raise ValueError("known data mismatch")
                if len(banks.get(idx, [])) != e["accesses"]:
                    raise ValueError("physical request count mismatch")
            elif v["kind"] in (1, 2):
                count = 0 if v["kind"] == 1 else 1
                if cancellations[idx] != [v["kind"], count] or len(banks.get(idx, [])) != count:
                    raise ValueError("canceled request count mismatch")
            elif v["kind"] == 4 and idx in banks:
                raise ValueError("idle reset accessed memory")
        final = passes[0]
        if final["vectors"] != len(accepted) or final["responses"] != len(normal) or final["held"] <= 0:
            raise ValueError("summary mismatch")
        if final["requests"] != sum(len(x) for x in banks.values()):
            raise ValueError("summary physical request total")
        summary[name] = {**final, "stdout_sha256": sha(text_path)}
    result = {"status": "FINITE_LOG_AUDIT_PASS", "profiles": summary,
              "oracle_reexecuted": False, "hdl_invocations": 0,
              "prepared_manifest_sha256": sha(prepared / "prepared_manifest.json"),
              "hardware": "HW_UNVERIFIED"}
    target = artifacts / "finite_log_audit.json"
    with target.open("x", encoding="utf-8", newline="\n") as stream:
        json.dump(result, stream, indent=2)
        stream.write("\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
