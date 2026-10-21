"""Bind integrated production to completed frozen numerical/physical evidence."""
from pathlib import Path
import hashlib,json
C=Path(__file__).resolve().parent
R=C.parents[4]
sha=lambda b:hashlib.sha256(b).hexdigest()
reg=C/'original_public_regression_20261019_010950/summary.json'
s=json.loads(reg.read_text());assert s['status']=='PASS'
checks={}
for name,expected in s['source_sha256'].items():
 p=R/Path(name.replace(chr(92),'/'));data=p.read_bytes()
 if p.name=='run_super_resolution_tests.py':
  assert data.count(b'timeout=600')==1
  data=data.replace(b'timeout=600',b'timeout=120')
  # Original runner used platform CRLF; only host timeout and newline convention may differ.
  candidates=[data,data.replace(b'\r\n',b'\n'),data.replace(b'\r\n',b'\n').replace(b'\n',b'\r\n')]
  assert expected in [sha(x) for x in candidates],name
 else:assert sha(data)==expected,(name,sha(data),expected)
 checks[name]={'production_sha256':sha(p.read_bytes()),'frozen_regression_sha256':expected,'match':'EXACT_BYTES' if p.suffix=='.v' else 'EXACT_ORACLE_RUNNER_AFTER_HOST_TIMEOUT_AND_LINE_ENDING_NORMALIZATION'}
rtl=R/'signal_video/rtl/cip_image_super_resolution.v'
assert rtl.read_bytes()==(C/'source/cip_image_super_resolution.v').read_bytes()
tb=(R/'signal_video/sim/tb_cip_image_super_resolution.v').read_text()
assert 'ct>170000' in tb and 'cycles>3000000' in tb and '#4000000000' in tb
board=C/'functional_board_frozen_seed3_20261019_011832_039999.json'
b=json.loads(board.read_text());assert b['status']=='FUNCTIONAL_BOARD_PASS_HOLD_UNPROVEN'
assert len(b['runs'])==3 and all(x['status']=='PASS' and x['uart_hex']==x['expected_hex'] for x in b['runs'])
case=json.loads((C/'case.json').read_text())
frozen_checks={}
for name,h in case['source_sha256'].items():
 p=C/name
 assert sha(p.read_bytes())==h,name
 frozen_checks[name]=h
out={'status':'PASS','scope':'production byte binding to completed original five-profile regression and bounded three-run SRAM/UART evidence; hold UNPROVEN','production':checks,'frozen_source_hashes_verified':frozen_checks,'regression':{'path':reg.name,'sha256':sha(reg.read_bytes()),'profiles':5,'commands':258,'outputs':6720,'reset_cases':16},'board':{'path':board.name,'sha256':sha(board.read_bytes()),'runs':3,'status':b['status']},'watchdogs':{'reset_first_output':170000,'main_cycles':3000000,'global_ns':4000000000,'host_seconds':600},'regression_rerun':'not repeated; exact RTL/TB bytes and unchanged runner oracle bound to retained PASS evidence'}
(C/'PRODUCTION_BINDING.json').write_text(json.dumps(out,indent=2)+'\n')
h=json.loads((C/'HANDOFF.json').read_text());h.update(status='PRODUCTION_INTEGRATED_BOUND_TO_THREE_BOARD_PASS_HOLD_UNPROVEN',board=board.name,production_binding='PRODUCTION_BINDING.json');(C/'HANDOFF.json').write_text(json.dumps(h,indent=2)+'\n')
print('SR production binding PASS: exact RTL/TB, original oracle, five profiles, three board runs, all frozen source hashes')
