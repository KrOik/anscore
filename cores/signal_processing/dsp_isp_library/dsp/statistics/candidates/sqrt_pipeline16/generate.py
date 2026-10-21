"""Separate diagnostic candidate: one restoring iteration per register stage."""
from pathlib import Path
import hashlib,json
H=Path(__file__).resolve().parent;S=H.parent/'sqrt_pipeline4'
wrapper=(S/'wrapper.vh').read_text()
wrapper=wrapper.replace('reg [3:0] valid','reg [15:0] valid').replace('wire [3:0] ready','wire [15:0] ready').replace('[0:3]','[0:15]')
wrapper=wrapper.replace('Four binary restoring iterations per register: 16 iterations in four stages.','One binary restoring iteration per register: 16 stages.')
wrapper=wrapper.replace('root_four','root_one').replace('k<4','k<1').replace('g<4','g<16').replace('g==3','g==15')
wrapper=wrapper.replace('valid[3]','valid[15]').replace('user_stage[3]','user_stage[15]').replace('metadata[3]','metadata[15]').replace('root_stage[3]','root_stage[15]')
source=H.parents[1]/'rtl/statistics_stream.sv';s=source.read_text();s=s.replace('module statistics_stream #(','module statistics_leaf_no_rms #(',1)
a=s.index(' function [15:0] sqrt_floor;');b=s.index(' // Explicit unsigned square',a);s=s[:a]+s[b:];s=s.replace('sqrt_floor(mean_power_w[31:0])',"16'b0")
(H/'wrapper.vh').write_text(wrapper)
(H/'statistics_stream.sv').write_text('// Isolated diagnostic: sixteen exact one-iteration root stages.\n'+wrapper+'\n'+s)
(H/'test_candidate.py').write_text((S/'test_candidate.py').read_text().replace('default=5','default=17'))
(H/'generation.json').write_text(json.dumps(dict(original_sha256=hashlib.sha256(source.read_bytes()).hexdigest(),stats_latency=17,root_stages=16,iterations_per_stage=1,II=1,production_modified=False),indent=2))
