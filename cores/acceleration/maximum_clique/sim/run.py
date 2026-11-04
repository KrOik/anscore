#!/usr/bin/env python3
"""Original deterministic subset oracle and one explicitly frozen finite matrix."""
import argparse
from collections import Counter
import hashlib
import itertools
import json
import os
from pathlib import Path
import random
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
REPO = ROOT.parents[2]
BASELINE = "eb16eee7848694a1a1cd50e567b5742352751c93"
PROFILES = [(1, 1), (2, 3), (4, 5), (6, 8), (8, 8), (16, 32)]
REJECTS = [("NUM_NODES", 0), ("NUM_NODES", 17), ("TAG_W", 0), ("TAG_W", 33)]


def digest(data):
    return hashlib.sha256(data).hexdigest()


def text_json(value):
    return json.dumps(value, indent=2) + "\n"


def is_clique(mask, edges, n):
    return all((a, b) in edges for a in range(n) if mask >> a & 1
               for b in range(a + 1, n) if mask >> b & 1)


def oracle(edges, n):
    # Enumerate every vertex subset; no candidate stack or pruning search.
    best = 0
    optimum_count = 0
    for mask in range(1 << n):
        size = mask.bit_count()
        if size >= best and is_clique(mask, edges, n):
            if size > best:
                best, optimum_count = size, 1
            else:
                optimum_count += 1
    if n <= 6:
        missing = set(itertools.combinations(range(n), 2)) - edges
        cover = min(mask.bit_count() for mask in range(1 << n)
                    if all((mask >> a & 1) or (mask >> b & 1) for a, b in missing))
        assert best == n - cover
    return best, optimum_count


def fixtures(n, t):
    rng = random.Random(0xB180CA + 37 * n + t)
    pairs = list(itertools.combinations(range(n), 2))
    cases = []

    def add(edges, kind, *, updates=False, prefix_mask=False, tail_edge=False):
        edges = set(edges)
        tokens = []
        if prefix_mask:
            tokens.append([0xFFFFFFFF, 0x80000000, 1, 0, 1, 0, rng.getrandbits(t)])
        ordered = list(pairs)
        rng.shuffle(ordered)
        for a, b in ordered:
            if updates:
                tokens += [[b, a, int((a, b) not in edges), 1, 0, 0, rng.getrandbits(t)],
                           [a, b, int((a, b) in edges), 1, 0, 0, rng.getrandbits(t)]]
            elif (a, b) in edges:
                tokens.append([b, a, 1, 1, 0, 0, rng.getrandbits(t)])
        # Self-loop removal/addition must never change the simple graph.
        tokens.append([n - 1, n - 1, 1, 1, 0, 0, rng.getrandbits(t)])
        if tail_edge and pairs:
            a, b = pairs[0]
            tokens.append([a, b, int((a, b) in edges), 1, 0, 1, rng.getrandbits(t)])
        else:
            tokens.append([0x80000000, 0xFFFFFFFF, 0, 0, 0, 1, rng.getrandbits(t)])
        tokens[0][4] = 1
        cases.append({"kind": kind, "tokens": tokens})

    add(set(), "empty", prefix_mask=True)
    add(pairs, "complete", tail_edge=True)
    add(((i, i + 1) for i in range(n - 1)), "path", updates=True)
    add(((0, i) for i in range(1, n)), "star", prefix_mask=True)
    add(((a, b) for a, b in pairs if (a % 2) != (b % 2)), "complete_bipartite")
    add(((a, b) for a, b in pairs if a % 3 != b % 3), "complete_tripartite", tail_edge=True)
    add(((a, b) for a, b in pairs if a // 3 == b // 3), "disjoint_complete_blocks", updates=True)
    add(((a, b) for a, b in pairs if b < max(1, n // 2)), "planted_clique")
    for probability in [0.15, 0.35, 0.5, 0.65, 0.85]:
        for repeat in range(3):
            e = {(a, b) for a, b in pairs if rng.random() < probability}
            add(e, "seeded", updates=repeat == 1, prefix_mask=repeat == 2, tail_edge=repeat == 0)
            permutation = list(range(n))
            rng.shuffle(permutation)
            mapped = {tuple(sorted((permutation[a], permutation[b]))) for a, b in e}
            add(mapped, "renumbered", prefix_mask=True)
    if n <= 4:
        for image in range(1 << len(pairs)):
            add((p for i, p in enumerate(pairs) if image >> i & 1), "all_small_graphs")
    # Check all error combinations, full-width endpoint validation, ignored
    # masked geometry, sticky faults, later-FIRST, and first masked ownership.
    for bad in [n, 0x80000000, 0xFFFFFFFF]:
        for first in [0, 1]:
            cases.append({"kind": "bad_endpoint", "tokens": [
                [bad, 0, 1, 1, first, 1, rng.getrandbits(t)]]})
    cases += [
        {"kind": "missing_first", "tokens": [[0, 0, 0, 0, 0, 1, rng.getrandbits(t)]]},
        {"kind": "late_first", "tokens": [[0xFFFFFFFF, 0xFFFFFFFF, 1, 0, 1, 0, rng.getrandbits(t)],
                                             [0, 0, 1, 1, 1, 1, rng.getrandbits(t)]]},
        {"kind": "sticky_both", "tokens": [[0, n, 0, 1, 1, 0, rng.getrandbits(t)],
                                              [0, 0, 0, 0, 1, 1, rng.getrandbits(t)]]},
    ]
    for case in cases:
        e, error = set(), 0
        for i, (a, b, present, keep, first, last, tag) in enumerate(case["tokens"]):
            error |= int(bool(keep and (a >= n or b >= n)))
            error |= int(bool(first != (i == 0))) << 1
            # Only error-free public results expose graph/witness state.
            if keep and a < n and b < n and a != b:
                pair = tuple(sorted((a, b)))
                if present:
                    e.add(pair)
                else:
                    e.discard(pair)
            assert last == (i == len(case["tokens"]) - 1)
        case.update(edges=sorted(e), error=error, tag=case["tokens"][0][-1])
        if error:
            case.update(optimum=0, optimum_count=0)
        else:
            result, choices = oracle(e, n)
            case.update(optimum=result, optimum_count=choices)
    words = []
    for case in cases:
        for a, b, present, keep, first, last, tag in case["tokens"]:
            word = a
            for value, width in [(b, 32), (present, 1), (keep, 1), (first, 1), (last, 1), (tag, t)]:
                word = (word << width) | value
            words.append(format(word, "x"))
    data = ("\n".join(words) + "\n").encode()
    cov = Counter()
    for c in cases:
        cov["error_" + str(c["error"])] += 1
        cov["kind_" + c["kind"]] += 1
        if not c["error"]:
            cov["valid_frames"] += 1
            cov["multiple_optima"] += c["optimum_count"] > 1
            cov["proper_cliques"] += 1 < c["optimum"] < n
            cov["singleton_optima"] += c["optimum"] == 1
            cov["full_cliques"] += c["optimum"] == n
            cov["complement_cover_crosschecks"] += n <= 6
    return cases, data, dict(cov)


def frozen():
    profiles = []
    for n, t in PROFILES:
        cases, data, coverage = fixtures(n, t)
        profiles.append({"NUM_NODES": n, "TAG_W": t, "frames": len(cases),
                         "beats": sum(len(c["tokens"]) for c in cases), "input_sha256": digest(data),
                         "coverage": coverage, "reset_probes": 16, "fresh_checks": 16})
    return {"baseline": BASELINE, "timeout_seconds": 20,
            "timeout_policy": "terminal; never retry, shrink fixtures or increase limit",
            "profiles": profiles, "expected_parameter_rejections": REJECTS,
            "qualified_tool_records": 19, "matrix": "version; core/example lint; six compile+vvp; four parameter rejects",
            "reset_targets": ["clear_first", "clear_middle", "capture_idle", "capture_partial",
                              "up_read_a", "up_write_a", "up_read_b", "up_write_b", "start",
                              "search_root", "adj_read", "descend", "pop_read", "pop_load",
                              "held_success_blocked_source", "held_error_blocked_source"],
            "singleton_aliases": "N1 has no distinct-endpoint edge; four update probes alias START",
            "not_run": ["synthesis", "PnR", "STA", "hardware", "expanded_regression"]}


def check_outputs(n, t, cases, actual, trace):
    lines = actual.splitlines()
    assert len(lines) == len(cases), "response count"
    coverage = Counter()
    for case, line in zip(cases, lines):
        fields = line.split()
        assert len(fields) == n + 3
        result = int(fields[0], 16)
        tag = result & ((1 << t) - 1)
        result >>= t
        error = result & 3
        result >>= 2
        cw = n.bit_length()
        size = result & ((1 << cw) - 1)
        mask = result >> cw
        assert (tag, error, size) == (case["tag"], case["error"], case["optimum"])
        assert mask < 1 << n and mask.bit_count() == size
        assert is_clique(mask, set(map(tuple, case["edges"])), n)
        latency, pushes = map(int, fields[1:3])
        if error:
            assert mask == 0 and latency == 1 and pushes == 0
        else:
            edge_set = set(map(tuple, case["edges"]))
            rows = [sum(1 << b for b in range(n) if tuple(sorted((a, b))) in edge_set)
                    for a in range(n)]
            assert list(map(lambda x: int(x, 16), fields[3:])) == rows
            tail = case["tokens"][-1]
            real_tail = tail[3] and tail[0] != tail[1]
            assert latency == 2 + 6 * pushes + 4 * real_tail and latency <= 6 * (1 << n)
            coverage["witness_vertices"] += size
    for line in trace.splitlines():
        f, cycle, depth, clique, candidates, best, size = line.split()
        frame, depth, size = int(f), int(depth), int(size)
        clique, candidates, best = int(clique, 16), int(candidates, 16), int(best, 16)
        case = cases[frame]
        assert not case["error"]
        edges = set(map(tuple, case["edges"]))
        assert clique.bit_count() == depth and best.bit_count() == size
        assert is_clique(clique, edges, n) and is_clique(best, edges, n)
        assert candidates & clique == 0
        assert not clique or candidates & ((1 << clique.bit_length()) - 1) == 0
        for a in range(n):
            if candidates >> a & 1:
                assert all(tuple(sorted((a, b))) in edges for b in range(n) if clique >> b & 1)
        coverage["search_invariant_checks"] += 1
        coverage["candidate_membership_checks"] += candidates.bit_count() * depth
    return dict(coverage)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--freeze", action="store_true", help="create plan only, no HDL tools")
    parser.add_argument("--repair-reason", help="explicit concrete ordinary failure; preserve prior receipt")
    args = parser.parse_args()
    plan = frozen()
    plan_path = ROOT / "TEST_PLAN.json"
    if args.freeze:
        assert not plan_path.exists(), "frozen plan already exists"
        plan_path.write_text(text_json(plan), encoding="utf-8", newline="\n")
        print("FROZEN", len(plan["profiles"]), "profiles, 19 children; no HDL tools")
        return
    assert json.loads(plan_path.read_text(encoding="utf-8")) == json.loads(text_json(plan)), "frozen matrix changed"
    receipt = ROOT / "verification.json"
    history = []
    if receipt.exists():
        old_bytes = receipt.read_bytes()
        old = json.loads(old_bytes)
        assert not any(c.get("status") == "TIMEOUT" for c in old["commands"]), "terminal timeout: never retry"
        assert args.repair_reason and "UNIT_SIM_PASS" not in old["status"], "no automatic successful rerun"
        history = old.pop("prior_failed_attempts", [])
        old["archived_receipt_sha256"] = digest(old_bytes)
        old["ordinary_repair_reason"] = args.repair_reason
        history.append(old)
    hashes = {p.relative_to(ROOT).as_posix(): digest(p.read_bytes()) for p in sorted(ROOT.rglob("*"))
              if p.is_file() and p != receipt}
    report = {"baseline": BASELINE, "status": ["RTL_CANDIDATE", "HW_UNVERIFIED"],
              "commands": [], "profiles": [], "source_sha256": hashes,
              "prior_failed_attempts": history, "frozen_inputs": plan["profiles"],
              "test_plan_sha256": digest(plan_path.read_bytes()), "totals": {},
              "invalid_parameter_rejections": 0, "timeout_occurred": False,
              "oracle": "exhaustive vertex subsets and pair membership; small complement minimum vertex cover crosscheck",
              "not_run": plan["not_run"]}
    suite = REPO / "tools/oss-cad-suite/oss-cad-suite"
    env = os.environ.copy()
    env["PATH"] = os.pathsep.join([str(suite / "bin"), str(suite / "lib"), env.get("PATH", "")])
    iv, vv = str(suite / "bin/iverilog.exe"), str(suite / "bin/vvp.exe")

    def child(command, reject=False):
        try:
            r = subprocess.run(command, cwd=ROOT, env=env, capture_output=True,
                               text=True, encoding="utf-8", errors="replace", timeout=20)
            combined = r.stdout + r.stderr
            passed = (r.returncode > 0 and "maximum_clique_invalid_parameters" in combined) if reject else r.returncode == 0
            report["commands"].append({"argv": command, "returncode": r.returncode,
                                       "stdout": r.stdout, "stderr": r.stderr,
                                       "timeout_seconds": 20, "status": "PASS" if passed else "FAIL"})
            if not passed:
                raise RuntimeError(combined)
            return combined
        except subprocess.TimeoutExpired as e:
            report["commands"].append({"argv": command, "returncode": None, "stdout": str(e.stdout or ""),
                                       "stderr": str(e.stderr or ""), "timeout_seconds": 20, "status": "TIMEOUT"})
            report["timeout_occurred"] = True
            raise

    try:
        child([iv, "-V"])
        child([iv, "-g2012", "-Wall", "-tnull", "-s", "maximum_clique", "-f", "files.f"])
        child([iv, "-g2012", "-Wall", "-tnull", "-s", "clique8", "-f", "files.f", "example/clique8.sv"])
        report["status"] = ["LINT_PASS", "HW_UNVERIFIED"]
        for n, t in PROFILES:
            cases, data, cov = fixtures(n, t)
            with tempfile.TemporaryDirectory(prefix="anscore_b18_clique_") as temp:
                directory = Path(temp)
                inp, out, trace, exe = [directory / s for s in ["input.hex", "output.txt", "trace.txt", "unit.vvp"]]
                inp.write_bytes(data)
                beats = sum(len(c["tokens"]) for c in cases)
                child([iv, "-g2012", "-Wall", "-s", "tb_maximum_clique",
                       "-Ptb_maximum_clique.N=" + str(n), "-Ptb_maximum_clique.T=" + str(t),
                       "-Ptb_maximum_clique.BEATS=" + str(beats), "-Ptb_maximum_clique.FRAMES=" + str(len(cases)),
                       "-o", str(exe), "-f", "files.f", "sim/tb_maximum_clique.sv"])
                output = child([vv, str(exe), "+INPUT=" + inp.as_posix(), "+OUTPUT=" + out.as_posix(), "+TRACE=" + trace.as_posix()])
                match = re.search(r"PASS maximum_clique (.+)", output)
                assert match, "missing finite completion marker"
                counters = {k: int(v, 16) if k == "states" else int(v) for k, v in re.findall(r"(\w+)=([0-9a-f]+)", match[1])}
                assert counters["frames"] == len(cases) and counters["beats"] == beats
                assert counters["resets"] == counters["fresh"] == 16
                assert counters["pushes"] == counters["pops"]
                checks = check_outputs(n, t, cases, out.read_text(encoding="utf-8"), trace.read_text(encoding="utf-8"))
                report["profiles"].append({"NUM_NODES": n, "TAG_W": t, "status": "PASS", **counters,
                                           "coverage": cov, **checks, "input_sha256": digest(data),
                                           "actual_sha256": digest(out.read_bytes()), "trace_sha256": digest(trace.read_bytes()),
                                           "output": output.strip()})
        for parameter, value in REJECTS:
            child([iv, "-g2012", "-tnull", "-s", "maximum_clique", "-Pmaximum_clique." + parameter + "=" + str(value), "-f", "files.f"], True)
            report["invalid_parameter_rejections"] += 1
        additive = ["frames", "beats", "pushes", "pops", "latency_checks", "held", "blocked", "source_holds",
                    "resets", "fresh", "empty_prunes", "bound_prunes", "witness_vertices",
                    "search_invariant_checks", "candidate_membership_checks"]
        report["totals"] = {k: sum(p[k] for p in report["profiles"]) for k in additive}
        report["status"] = ["LINT_PASS", "UNIT_SIM_PASS", "HW_UNVERIFIED"]
        report["matrix_status"] = "PASS"
    except Exception as error:
        report["matrix_status"] = "TIMEOUT_NOT_RUN" if report["timeout_occurred"] else "FAILED_OR_NOT_RUN"
        report["failure"] = repr(error)
        raise
    finally:
        report["remaining_profiles"] = plan["profiles"][len(report["profiles"]):]
        receipt.write_text(text_json(report), encoding="utf-8", newline="\n")
    print(text_json({"status": report["status"], "totals": report["totals"], "children": len(report["commands"])}))


if __name__ == "__main__":
    main()
