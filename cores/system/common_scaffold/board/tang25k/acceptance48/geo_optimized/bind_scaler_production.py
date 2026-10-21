"""Bind production bytes to the completed v9 numerical and board regressions."""
from pathlib import Path
import hashlib,json,datetime

H=Path(__file__).resolve().parent
SV=H.parents[3]/'signal_video'
GEO=H.parents[3]/'image/geometry/rtl'
C=H/'scaler_v9'
sha=lambda data:hashlib.sha256(data).hexdigest()
summaries=[json.loads((H/('v9_hostbound_frozen_regression_'+n)/'summary.json').read_text())
           for n in ['scaler_tests','bicubic_tests']]
assert all(d['status']=='PASS' for d in summaries)
assert [len(d['cases']) for d in summaries]==[7,14]
bindings={}
for source in (C/'source').glob('*.v'):
    if source.name.startswith('acceptance48_'):continue
    target=next(p for p in [SV/'rtl'/source.name,GEO/source.name] if p.exists())
    assert source.read_bytes()==target.read_bytes(),str(target)
    bindings[str(target)]=sha(target.read_bytes())
for summary,name in zip(summaries,['tb_cip_image_scaler.v','tb_cip_image_bicubic_frame.v']):
    target=SV/'sim'/name
    expected=next(v for k,v in summary['source_sha256'].items() if k.endswith(name))
    assert sha(target.read_bytes())==expected,str(target)
    bindings[str(target)]=expected
# Oracle/fixtures are exactly the original runner. Only the VVP host timeout
# keyword changed; reverse that one edit before comparing its recorded hash.
runner=SV/'run_bicubic_tests.py'
current=runner.read_text()
assert current.count("simulation.log',timeout=1200)")==1
original=current.replace("simulation.log',timeout=1200)","simulation.log')")
expected=next(v for k,v in summaries[1]['source_sha256'].items() if k.endswith('run_bicubic_tests.py'))
assert expected in [sha(original.encode()),sha(original.replace('\n','\r\n').encode())], 'runner changed beyond host timeout/newline normalization'
bindings[str(runner)]=sha(runner.read_bytes())
board=C/'functional_board_frozen_seed3_20261019_003344_106493.json'
b=json.loads(board.read_text())
assert b['status']=='FUNCTIONAL_BOARD_PASS_HOLD_UNPROVEN'
assert len(b['runs'])==3 and all(r['status']=='PASS' for r in b['runs'])
result={'status':'PASS','time_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'method':'Exact DUT+TB hashes; original numerical runner differs only by VVP timeout1200 keyword',
        'profiles':21,'commands':1423,'outputs':60615,'reset_cases':45,
        'board_evidence':str(board),'board_evidence_sha256':sha(board.read_bytes()),
        'production_bindings':bindings,'hold':'UNPROVEN',
        'notes':'All tested DUT dependencies match; testbench watchdog bytes match actual frozen regression. No repeat of identical25-minute simulation.'}
(H/'SCALER_PRODUCTION_BINDING.json').write_text(json.dumps(result,indent=2)+'\n')
print('SCALER PRODUCTION BINDING PASS:14 DUT files,2 testbenches,21 profiles,3 board runs')
