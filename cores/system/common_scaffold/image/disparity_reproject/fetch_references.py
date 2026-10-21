import subprocess,tempfile,hashlib,json,datetime
from pathlib import Path
HERE=Path(__file__).resolve().parent
url='https://raw.githubusercontent.com/opencv/opencv/4.12.0/modules/calib3d/src/stereo_geom.cpp'
with tempfile.TemporaryDirectory(prefix='reproject_reference_')as tmp:
 p=Path(tmp)/'source';subprocess.run(['curl.exe','-fsL','--ssl-revoke-best-effort','--max-time','35','-o',str(p),url],check=True);data=p.read_bytes();lines=data.decode().splitlines();i=next(i for i,l in enumerate(lines)if 'void reprojectImageTo3D' in l)
 row=dict(url=url,retrieved_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),sha256=hashlib.sha256(data).hexdigest(),bytes=len(data),excerpt='\n'.join(lines[i:i+115]),used='General 4x4 homogeneous Q and XYZ/W semantics; no code copied; handleMissingValues=False reference')
(HERE/'references.json').write_text(json.dumps(row,indent=2)+'\n');print(row['sha256'],row['bytes']);print(row['excerpt'])
