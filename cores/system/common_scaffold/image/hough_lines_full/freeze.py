import hashlib,json
from pathlib import Path
root=Path(__file__).resolve().parent
sha=hashlib.sha256((root/'hough_lines_full.sv').read_bytes()).hexdigest()
for name in ['test_result.json','protocol_result.json','synthesis_result.json']:
 data=json.loads((root/name).read_text());assert data['status']=='PASS' and data['rtl_sha256']==sha,name
sources=[p for p in root.iterdir() if p.suffix in ['.sv','.py','.mem','.md','.f'] or p.name=='manifest.json']
root.joinpath('freeze_hashes.json').write_text(json.dumps(dict(status='FROZEN',sources={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(sources)},evidence_mutable=True),indent=2)+'\n')
data=json.loads((root/'test_result.json').read_text());print(dict(rtl_sha256=sha,cases=len(data['cases']),skimage_bins=sum(c['skimage_bins'] for c in data['cases']),skimage_differences=sum(c['skimage_different_bins'] for c in data['cases']),directory_bytes=sum(p.stat().st_size for p in root.iterdir() if p.is_file())))
