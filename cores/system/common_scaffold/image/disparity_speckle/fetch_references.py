import subprocess,tempfile,hashlib,json,datetime
from pathlib import Path
HERE=Path(__file__).resolve().parent
url='https://cdn.jsdelivr.net/gh/opencv/opencv@4.12.0/modules/calib3d/src/stereosgbm.cpp'
with tempfile.TemporaryDirectory(prefix='speckle_reference_')as tmp:
 p=Path(tmp)/'source';subprocess.run(['curl.exe','-fsL','--ssl-revoke-best-effort','--max-time','35','-o',str(p),url],check=True);data=p.read_bytes();lines=data.decode().splitlines();i=next(i for i,l in enumerate(lines)if 'filterSpecklesImpl' in l)
 row=dict(url=url,retrieved_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),sha256=hashlib.sha256(data).hexdigest(),bytes=len(data),excerpt='\n'.join(lines[max(0,i-3):i+140]),used='4-connected local disparity difference and maxSpeckleSize comparison; no code copied')
(HERE/'references.json').write_text(json.dumps(row,indent=2)+'\n');print(row['sha256'],row['bytes'])
