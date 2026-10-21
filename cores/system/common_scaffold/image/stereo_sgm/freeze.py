import hashlib,json
from run_tests import HERE,hashes
for name in ['test_result.json','protocol_result.json','numeric_result.json','invalid_parameters.json','synthesis_result.json']:
 d=json.loads((HERE/name).read_text(encoding='utf-8-sig'));assert d['status']=='PASS' and d['sources']==hashes(),name
assets=[p for p in HERE.iterdir()if p.suffix in ['.sv','.py','.md','.f']or p.name in ['manifest.json','references.json']]
(HERE/'freeze_hashes.json').write_text(json.dumps(dict(status='FROZEN',sources={p.name:hashlib.sha256(p.read_bytes()).hexdigest()for p in sorted(assets)},dependencies={},evidence_mutable=True),indent=2)+'\n')
print('FROZEN',hashes())
