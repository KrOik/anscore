"""Verify Yosys parameter derivation binds every rotated ROM entry to the intended radius asset."""
from pathlib import Path
import sys,tempfile,json,hashlib
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import execute,ROOT
rows=[]
for radius,params in [(3,''),(15,'chparam -set WIDTH 71 -set HEIGHT 69 -set BITS 10 -set LEVELS 2 -set RADIUS 15 multiscale_features_frame; ')]:
 with tempfile.TemporaryDirectory(prefix='multiscale_rom_audit_') as td:
  p=Path(td)
  execute(['yosys','-Q','-p',f'read_verilog -sv {(H/"multiscale_features_frame.sv").as_posix()}; {params}proc; memory_collect; write_json {(p/"memory.json").as_posix()}'],ROOT,p/'audit.log')
  module=json.loads((p/'memory.json').read_text())['modules']['multiscale_features_frame']
  cells=[v for v in module['cells'].values() if v['type']=='$mem_v2' and 'pattern' in v['parameters'].get('MEMID','')];assert len(cells)==1
  init=cells[0]['parameters']['INIT']
  words=[int(init[len(init)-24*(i+1):len(init)-24*i],2) for i in range(4096)]
  asset=H.parent/'oriented_brief'/f'pattern_r{radius}.mem';reference=[int(x,16) for x in asset.read_text().splitlines()]
  assert words==reference
  rows.append({'radius':radius,'entries':4096,'asset_sha256':hashlib.sha256(asset.read_bytes()).hexdigest()})
(H/'derived_rom_evidence.json').write_text(json.dumps({'result':'PASS','cases':rows,'rtl_sha256':hashlib.sha256((H/'multiscale_features_frame.sv').read_bytes()).hexdigest()},indent=2)+'\n')
print('PASS derived R3/R15 complete4096-entry ROM bindings')
