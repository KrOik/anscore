import json,hashlib
from pathlib import Path
from run_tests import HERE,FULL,SEG,hashes
current=hashes()
for name in ['test_result.json','protocol_result.json','invalid_parameters.json','synthesis_result.json']:
 data=json.loads((HERE/name).read_text());assert data['status']=='PASS' and data['sources']==current,name
dependencies={}
for folder,module in [(FULL,'hough_lines_full.sv'),(SEG,'hough_segments.sv')]:
 index=json.loads((folder/'freeze_hashes.json').read_text())
 for name in [module,'run_tests.py','trig.mem']:
  p=folder/name;h=hashlib.sha256(p.read_bytes()).hexdigest();assert index['sources'][name]==h,str(p)
  dependencies['../'+folder.name+'/'+name]=h
 dependencies['../'+folder.name+'/freeze_hashes.json']=hashlib.sha256((folder/'freeze_hashes.json').read_bytes()).hexdigest()
references=dict(provenance='Actual upstream retrieval metadata inherited from the frozen dependency implementations; no fresh download is claimed by this integration wrapper.',
 dependencies={str(p.relative_to(HERE.parent)):dict(sha256=hashlib.sha256(p.read_bytes()).hexdigest(),metadata=json.loads(p.read_text())) for p in [FULL/'references.json',SEG/'references.json']})
(HERE/'references.json').write_text(json.dumps(references,indent=2)+'\n')
assets=[p for p in HERE.iterdir() if p.suffix in ['.sv','.py','.mem','.md','.f'] or p.name in ['manifest.json','references.json']]
(HERE/'freeze_hashes.json').write_text(json.dumps(dict(status='FROZEN',sources={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(assets)},dependencies=dependencies,evidence_mutable=True),indent=2)+'\n')
print(dict(rtl_sha256=hashlib.sha256((HERE/'hough_segment_pipeline.sv').read_bytes()).hexdigest(),sources=len(assets),dependencies=len(dependencies),directory_bytes=sum(p.stat().st_size for p in HERE.iterdir() if p.is_file())))
