from pathlib import Path
import hashlib,json
H=Path(__file__).resolve().parent
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
rtl=sha(H/'integral_image.sv')
names=['test_result.json','protocol_result.json','numeric_result.json','synthesis_result.json']
for name in names:
 d=json.loads((H/name).read_text());assert d['result']=='PASS'and d['rtl_sha256']==rtl,name
assets=[p for p in H.iterdir()if p.suffix in('.sv','.py','.md','.f')or p.name in('manifest.json','references.json')]
snapshot=dict(status='FROZEN',sources={p.name:sha(p)for p in sorted(assets)},evidence={n:sha(H/n)for n in names},dependencies={'cores/system/common_scaffold/integration/tooling.py':sha(H.parents[1]/'integration'/'tooling.py')},evidence_mutable=True)
(H/'freeze_hashes.json').write_text(json.dumps(snapshot,indent=2)+'\n');print('FROZEN integral_image RTL '+rtl)
