"""Freeze original statistics leaf, remove only RMS arithmetic, append pipeline."""
from pathlib import Path
import hashlib,json
H=Path(__file__).resolve().parent
source=H.parents[1]/'rtl/statistics_stream.sv'
s=source.read_text()
assert s.count('sqrt_floor(mean_power_w[31:0])')==1
s=s.replace('module statistics_stream #(', 'module statistics_leaf_no_rms #(',1)
a=s.index(' function [15:0] sqrt_floor;');b=s.index(' // Explicit unsigned square',a)
s=s[:a]+s[b:]
s=s.replace('sqrt_floor(mean_power_w[31:0])',"16'b0")
wrapper=(H/'wrapper.vh').read_text()
(H/'statistics_stream.sv').write_text('// Candidate: original RMS removed; four registered radix-4 groups.\n'+wrapper+'\n'+s)
(H/'generation.json').write_text(json.dumps(dict(original_source=str(source),original_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),changes=['rename original module statistics_leaf_no_rms','remove sqrt_floor function','replace original RMS field with constant zero','append four-stage exact floor-sqrt elastic pipeline'],stats_latency=5,initiation_interval=1),indent=2))
