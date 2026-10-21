"""Prove the mapped chain contains the new four root register boundaries."""
import argparse,collections,hashlib,json
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('build',type=Path);p.add_argument('--stages',type=int,choices=(4,16),default=4);a=p.parse_args();b=a.build
net=json.loads((b/'top.json').read_text())['modules']['dsp_chain_harness']
drivers={bit:c['type'] for c in net['cells'].values() for port,bits in c['connections'].items() if c['port_directions'][port]=='output' for bit in bits}
source=(b/'statistics_stream.sv').read_text()
assert 'sqrt_floor' not in source
assert not any('sqrt_floor' in name for name in net['netnames'])
leaf=net['netnames']['core.stats.leaf.m_tdata']['bits'][32:48]
assert all(drivers.get(bit)=='GND' for bit in leaf)
stage=[]
for i in range(a.stages):
 bits=net['netnames'][f'core.stats.root_stage[{i}]']['bits']
 counts=dict(collections.Counter(drivers.get(bit,str(bit)) for bit in bits))
 assert sum(n for k,n in counts.items() if k.startswith('DFF'))==(16//a.stages)*(i+1)
 stage.append(counts)
assert net['netnames']['core.stats.m_tdata']['bits'][32:48]==net['netnames'][f'core.stats.root_stage[{a.stages-1}]']['bits']
result=dict(status='PASS',source_sha256=hashlib.sha256((b/'statistics_stream.sv').read_bytes()).hexdigest(),netlist_sha256=hashlib.sha256((b/'top.json').read_bytes()).hexdigest(),old_sqrt_function_absent=True,old_rms_output_16_bits='all GND',root_stage_driver_counts=stage,final_rms='exact mapped alias of final root register')
(b/'sqrt_mapping_audit.json').write_text(json.dumps(result,indent=2))
print('SQRT MAPPING PASS',b)
