"""One-shot numerical preparation. Execute only after exact-entry approval."""
from __future__ import annotations
import hashlib
import json
from pathlib import Path
from oracle import decode, encode, pack, section, widths_for_codes

ROOT = Path(__file__).resolve().parent
SOURCES = [".gitattributes", "rtl/gif_lzw_decoder.sv", "example/gif_data.sv",
           "files.f", "example/files.f", "README.md", "COST.md", "SOURCES.md",
           "CASE_TABLE.json", "BOUNDARY_CERTIFICATES.json", "LICENSE", "LICENSE.GIFLIB",
           "oracle.py", "prepare.py", "run_tests.py", "sim/tb_gif_lzw_decoder.sv",
           "TEST_PLAN.md"]


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_json(rel: str, value: object) -> None:
    (ROOT / rel).write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8", newline="\n")


def make_case(spec: dict, certificates: dict) -> tuple[bytes, list[int], list[int] | None]:
    kind = spec["kind"]
    if kind == "raw":
        return bytes.fromhex(spec["hex"]), spec.get("bad_positions", []), None
    if kind == "boundary":
        cert = certificates[spec["certificate"]]
        return bytes.fromhex(cert["section_hex"]), [], cert["indices"]
    minimum = spec["minimum"]
    clear = 1 << minimum
    known = None
    if kind == "literal":
        literals = [i % clear for i in range(spec["count"])]
        codes = [clear] + literals + spec.get("tail_codes", [clear + 1])
        known = literals
        if spec.get("tail_codes") == [4095, clear + 1]:
            known += [(4095 - clear - 2) % clear, (4096 - clear - 2) % clear]
        elif spec.get("tail_codes") == [4095, clear, 255, clear + 1]:
            known += [253, 254, 255]
        else:
            assert "tail_codes" not in spec
    elif kind == "kw":
        terms, literal = spec["terms"], spec["literal"]
        codes = [clear, literal] + list(range(clear + 2, clear + terms + 1)) + [clear + 1]
        known = [literal] * (terms * (terms + 1) // 2)
    elif kind in ("encoded_text", "encoded_range"):
        data = spec["text"].encode("ascii") if kind == "encoded_text" else bytes(i % 256 for i in range(spec["count"]))
        codes, known = encode(data, minimum), list(data)
        assert len(codes) < len(data), "fixed ordinary encoder case must actually compress"
    else:
        codes = spec["codes"]
    widths = spec.get("widths") or widths_for_codes(minimum, codes)
    payload = pack(codes, widths, spec.get("pad_high", False))
    post = bytes.fromhex(spec.get("post_eoi_payload_hex", ""))
    packet = section(minimum, payload + post, spec.get("block_sizes"),
                     [bytes.fromhex(s) for s in spec.get("after_eoi_blocks_hex", [])])
    bad = list(spec.get("bad_positions", []))
    if spec.get("bad_post_eoi_payload"):
        assert spec.get("block_sizes") is None and len(payload + post) <= 255
        bad.append(2 + len(payload))
    return packet, bad, known


def vector(rel: str, case: dict) -> None:
    expected, metrics = case["expected"], case["expected"]["metrics"]
    data = bytes.fromhex(case["section_hex"])
    fields = [case["id"], len(data), expected["count"], expected["errors"],
              expected["minimum"], f'{case["tag"]:08x}', expected["latency"],
              metrics["dictionary_reads"], metrics["dictionary_writes"],
              metrics["max_width"], metrics["max_next"], metrics["codes"],
              metrics["kw"], metrics["refill_branches"]]
    lines = [" ".join(map(str, fields))]
    for i, byte in enumerate(data):
        lines.append(f"{byte} {int(i == len(data)-1)} {int(i in case['bad_positions'])} {(case['tag'] if i == 0 else case['tag'] ^ (0xa5a55a5a + i)) & 0xffffffff:08x}")
    lines.extend(str(index) for index in expected["indices"])
    (ROOT / rel).write_text("\n".join(lines) + "\n", encoding="ascii", newline="\n")


def main() -> None:
    assert not (ROOT / "PREPARATION_RECEIPT.json").exists(), "one-shot preparation already exists"
    assert not (ROOT / "fixtures").exists(), "preserve prior preparation; no overwrite"
    assert all((ROOT / s).is_file() for s in SOURCES)
    source_hashes = {s: sha(ROOT / s) for s in SOURCES}
    # Pure static execution description: hash installed entries, launch nothing.
    from run_tests import PYTHON, IVERILOG, VVP, TASKKILL, plan
    tool_hashes = {str(p): sha(p) for p in (PYTHON, IVERILOG, VVP, TASKKILL)}
    child_description = plan(Path("{ARTIFACT}"))
    table = json.loads((ROOT / "CASE_TABLE.json").read_text())
    certs = {c["name"]: c for c in json.loads((ROOT / "BOUNDARY_CERTIFICATES.json").read_text())["certificates"]}
    for cert in certs.values():
        offsets, offset = [], 0
        for width in cert["widths"]:
            offsets.append(offset); offset += width
        assert offsets == cert["least_significant_bit_offsets"]
        payload = pack(cert["codes"], cert["widths"])
        assert payload.hex() == cert["payload_hex"]
        assert int.from_bytes(payload, "little") == int(cert["packed_integer_hex"], 16)
        assert widths_for_codes(cert["minimum"], cert["codes"]) == cert["widths"]
        assert section(cert["minimum"], payload).hex() == cert["section_hex"]
        result = decode(bytes.fromhex(cert["section_hex"]), [], 32)
        assert result["errors"] == 0 and result["indices"] == cert["indices"]
    fixed_errors = {"invalid_minimum":1,"first_unallocated":2,"future_code":2,
                    "premature_terminator":4,"truncated_payload":4,"eoi_byte_truncated":4,
                    "terminator_without_last":4,"bad_payload":8,"truncated_length":4,
                    "invalid_minimum_and_bad":9,"kw_count_overflow":16,
                    "unallocated_after_clear":2,"bad_final_terminator":8,
                    "bad_during_invalid_minimum_drain":9,"bad_post_eoi_payload":8}
    fixed_prefixes = {"canonical_one":[0],"implicit_literals":[7,6,5,4],
                      "future_code":[0],"truncated_payload":[],"eoi_byte_truncated":[0],
                      "terminator_without_last":[0],"bad_payload":[0],
                      "unallocated_after_clear":[0,0,0],"bad_final_terminator":[0],
                      "bad_post_eoi_payload":[1,2]}
    cases = []
    for profile in table["profiles"]:
        for spec in profile["main"]:
            data, bad, known = make_case(spec, certs)
            result = decode(data, bad, profile["COUNT_W"])
            assert result["errors"] == fixed_errors.get(spec["name"], 0), spec["name"]
            if known is not None:
                assert result["indices"] == known[:(1 << profile["COUNT_W"]) - 1], spec["name"]
            if spec["name"] in fixed_prefixes:
                assert result["indices"] == fixed_prefixes[spec["name"]], spec["name"]
            if spec["name"].startswith("empty_"):
                assert result["indices"] == []
            if spec["name"].startswith("full8_") or spec["name"].startswith("full2_"):
                assert result["metrics"]["max_width"] == 12
                assert result["metrics"]["max_next"] == 4096
                assert result["metrics"]["frozen_data_codes"] > 0
            case = dict(id=len(cases), key=profile["name"]+"/"+spec["name"],
                        COUNT_W=profile["COUNT_W"], TAG_W=profile["TAG_W"],
                        tag=(0x936a4f01 + len(cases)) & 0xffffffff,
                        section_hex=data.hex(), bad_positions=bad, expected=result)
            cases.append(case)
    assert len(cases) == 38 and [len(p["main"]) for p in table["profiles"]] == [15,15,8]
    by_key = {case["key"]: case for case in cases}
    assert len(table["reset_probes"]) == 24
    assert [sum(r["profile"] == p for r in table["reset_probes"]) for p in ("p0","p1","p2")] == [4,12,8]
    assert set(r["predicate"]["state"] for r in table["reset_probes"]) == set(range(1,16))
    assert table["reset_high_offers_per_probe"] == 3
    for reset in table["reset_probes"]:
        assert reset["prefix"] == reset["predicate"]["count"]
        assert 0 <= reset["prefix"] <= by_key[reset["owner"]]["expected"]["count"]
    # These arithmetic prefix certificates do not search an HDL or FSM model.
    assert 258 + (1791 - 1) == 2048
    assert 258 + (3838 - 1) == 4095
    assert sum(range(1,12)) == 66 and 256 + 12 == 268
    (ROOT / "fixtures").mkdir()
    write_json("fixtures/cases.json", cases)
    for case in cases:
        vector(f"fixtures/case_{case['id']:02d}.vec", case)
    fresh_cert = certs[table["reset_fresh_certificate"]]
    fresh = dict(id=99,tag=0,section_hex=fresh_cert["section_hex"],bad_positions=[],
                 expected=decode(bytes.fromhex(fresh_cert["section_hex"]), [],32))
    vector("fixtures/case_99.vec", fresh)
    predicate_keys = ["state","need_length","bit_count","errors","code_width","next_code","current_code","walk","stack_count","count"]
    for profile in table["profiles"]:
        name = profile["name"]
        ids = [case["id"] for case in cases if case["key"].startswith(name+"/")]
        (ROOT / f"fixtures/{name}.main").write_text(str(len(ids))+"\n"+"\n".join(map(str,ids))+"\n",encoding="ascii",newline="\n")
        resets = [r for r in table["reset_probes"] if r["profile"] == name]
        lines = [str(len(resets))]
        for reset in resets:
            values = [reset["id"],by_key[reset["owner"]]["id"],reset["prefix"],int(reset.get("actual_next_offer",False))]
            values += [reset["predicate"].get(key,-1) for key in predicate_keys]
            lines.append(" ".join(map(str,values)))
        (ROOT / f"fixtures/{name}.reset").write_text("\n".join(lines)+"\n",encoding="ascii",newline="\n")
    write_json("SOURCE_SEAL.json",dict(baseline=table["baseline"],sources=source_hashes,
                                      tools_sha256=tool_hashes,children=child_description,
                                      fixtures={p.relative_to(ROOT).as_posix():sha(p) for p in sorted((ROOT/"fixtures").iterdir())}))
    write_json("PREPARATION_RECEIPT.json",dict(status="PREPARED_ORACLE_ASSERTIONS_PASS_HW_NOT_RUN",main_cases=38,
               resets=24,children=20,certificates=3,source_seal_sha256=sha(ROOT/"SOURCE_SEAL.json")))
    print("PASS PREPARE cases=38 resets=24 children=20 certificates=3")


if __name__ == "__main__":
    main()
