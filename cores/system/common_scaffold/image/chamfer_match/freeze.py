import json,hashlib
from run_tests import HERE,DEP,hashes
current=hashes()
for name in ['test_result.json','protocol_result.json','invalid_parameters.json','numeric_result.json','synthesis_result.json']:
 data=json.loads((HERE/name).read_text());assert data['status']=='PASS' and data['sources']==current,name
assets=[p for p in HERE.iterdir() if p.suffix in ['.sv','.py','.md','.f'] or p.name in ['manifest.json','references.json']]
deps=[DEP,DEP.parent/'README.md',DEP.parent/'manifest.json',DEP.parent/'run_tests.py']
(HERE/'freeze_hashes.json').write_text(json.dumps(dict(status='FROZEN',sources={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(assets)},dependencies={'../euclidean_distance/'+p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in deps},evidence_mutable=True),indent=2)+'\n')
data=json.loads((HERE/'test_result.json').read_text());print(dict(rtl_sha256=hashlib.sha256((HERE/'chamfer_match.sv').read_bytes()).hexdigest(),dependency_sha256=hashlib.sha256(DEP.read_bytes()).hexdigest(),frames=len(data['cases']),scores=sum(r['scores'] for r in data['cases']),directory_bytes=sum(p.stat().st_size for p in HERE.iterdir() if p.is_file())))
