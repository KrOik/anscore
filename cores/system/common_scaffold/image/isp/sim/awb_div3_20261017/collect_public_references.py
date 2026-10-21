#!/usr/bin/env python3
"""Fetch public design references in memory; retain only hashes and snippets."""
from __future__ import annotations

import base64
import datetime as dt
import hashlib
import json
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent


def fetch(url: str) -> tuple[bytes, dict[str, object]]:
    request = urllib.request.Request(url, headers={
        "User-Agent": "awb-div3-design-reference-review", "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(request, timeout=25) as response:
        content = response.read()
        return content, {"requested_url": url, "final_url": response.geturl(),
            "http_status": response.status, "bytes": len(content),
            "sha256": hashlib.sha256(content).hexdigest(),
            "etag": response.headers.get("ETag"), "last_modified": response.headers.get("Last-Modified")}


def github_file(repo: str, path: str, commit: str, terms: tuple[str, ...]) -> dict[str, object]:
    raw, metadata = fetch(f"https://api.github.com/repos/{repo}/contents/{path}?ref={commit}")
    wrapper = json.loads(raw)
    source = base64.b64decode(wrapper["content"])
    lines = source.decode("utf-8").splitlines()
    selected = set()
    for index, line in enumerate(lines):
        if any(term.lower() in line.lower() for term in terms):
            selected.update(range(max(0, index-1), min(len(lines), index+2)))
    return {"retrieval": metadata, "commit": commit, "path": path,
        "browser_url": f"https://github.com/{repo}/blob/{commit}/{path}",
        "source_bytes": len(source), "source_sha256": hashlib.sha256(source).hexdigest(),
        "source_snippets": [{"line": index+1, "text": lines[index]} for index in sorted(selected)][:100],
        "full_source_retained": False}


def main() -> int:
    records: dict[str, object] = {"scope": "architecture and standard long-division references; no performance claims or copied numerical algorithm",
        "collected_utc": dt.datetime.now(dt.timezone.utc).isoformat(), "references": []}
    article, metadata = fetch("https://projectf.io/posts/division-in-verilog/")
    text = article.decode("utf-8")
    records["references"].append({"name": "Project F Division in Verilog", "retrieval": metadata,
        "article_title_present": "Division in Verilog" in text,
        "use": "reference for registered iterative division and explicit busy/done handling; our constant-three radix4 RTL and CE/backpressure interface are original",
        "full_html_retained": False})
    commit_data, commit_metadata = fetch("https://api.github.com/repos/projf/projf-explore/commits?path=lib/maths/div_int.sv&per_page=3")
    # The newest path-history entry deletes/replaces div_int.sv. Pin the
    # actual published source revision rather than claiming that 404 is code.
    commit = "c2eca17e9d3c5084db0c993a09d59c94bbd93439"
    if commit not in [entry["sha"] for entry in json.loads(commit_data)]:
        raise RuntimeError("pinned Project F divider absent from public path history")
    projectf = github_file("projf/projf-explore", "lib/maths/div_int.sv", commit,
                           ("copyright", "license", "busy", "done", "start", "quotient", "acc_next"))
    projectf["commit_resolution_http"] = commit_metadata
    projectf["use"] = "comparison of conventional one-bit iterative division state/handshake; not reused as a constant-three core"
    records["references"].append(projectf)
    commit = "e42643491a5851557fb392990d7be2e8139ae67b"
    vitis = github_file("Xilinx/Vitis_Libraries", "vision/L1/include/imgproc/xf_autowhitebalance.hpp", commit,
                       ("SPDX", "Apache", "AWBChannelGain", "AWBGainUpdate", "PIPELINE II"))
    vitis["use"] = "statistics/channel-gain versus pixel-application split only; its normalization differs from our exact arithmetic mean, so no algorithm substitution"
    records["references"].append(vitis)
    (HERE / "public_references.json").write_text(json.dumps(records, indent=2)+"\n", encoding="utf-8")
    print("AWB_DIV3_PUBLIC_REFERENCE_HTTP_PASS references=3 full_downloads_retained=0")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
