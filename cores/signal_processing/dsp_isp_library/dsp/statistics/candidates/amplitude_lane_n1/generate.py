"""Diagnostic-only N=1 output-lane experiment; never production statistics."""
from pathlib import Path
import hashlib,json
H=Path(__file__).resolve().parent;source=H.parents[1]/'rtl/statistics_stream.sv';s=source.read_text()
a=s.index(' function [15:0] sqrt_floor;');b=s.index(' // Explicit unsigned square',a);s=s[:a]+s[b:]
s=s.replace('sqrt_floor(mean_power_w[31:0])','amplitude').replace('cfg_log2>6','cfg_log2!=0')
(H/'statistics_stream.sv').write_text('// DIAGNOSTIC ONLY: N=1. RMS lane receives amplitude; no root arithmetic.\n// All log2 != 0 configurations are rejected by this isolated core.\n'+s)
test=(H.parent/'sqrt_pipeline4/test_candidate.py').read_text().replace('default=5','default=1')
(H/'test_candidate.py').write_text(test)
(H/'generation.json').write_text(json.dumps(dict(scope='N=1 RMS physical result-lane diagnostic only; do not run other configurations',original_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),stats_latency=1,root_arithmetic=False),indent=2))
