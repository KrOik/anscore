"""Fetch conceptual mature software reference, retain only hashes/excerpts and remove downloaded source."""
from pathlib import Path
import subprocess,tempfile,hashlib,json,datetime
H=Path(__file__).resolve().parent
urls=['https://cdn.jsdelivr.net/gh/opencv/opencv@4.x/modules/calib3d/src/stereosgbm.cpp','https://raw.githubusercontent.com/opencv/opencv/4.x/modules/calib3d/src/stereosgbm.cpp','https://raw.githubusercontent.com/opencv/opencv/4.12.0/modules/calib3d/src/stereosgbm.cpp']
rows=[]
for url in urls:
 with tempfile.TemporaryDirectory(prefix='subpixel_reference_') as td:
  p=Path(td)/'reference.cpp'
  result=subprocess.run(['curl.exe','-f','-L','--ssl-revoke-best-effort','--connect-timeout','10','--max-time','25','-o',str(p),url],capture_output=True)
  if result.returncode:rows.append({'url':url,'error':result.stderr.decode(errors='replace')[-500:]});continue
  data=p.read_bytes();lines=data.decode().splitlines();hits=[i for i,line in enumerate(lines) if 'denom2' in line or 'subpixel' in line.lower()]
  row={'url':url,'status':200,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),'accessed_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'excerpts':[{'line':i+1,'text':'\n'.join(lines[max(0,i-2):i+4])} for i in hits[:10]],'used':'Conceptual reference, no third-party RTL copied. Exact signed rounding, invalid masks, boundary and absolute uniqueness-gap policy are explicit variants.'};rows.append(row);break
(H/'references.json').write_text(json.dumps(rows,indent=2)+'\n');print(json.dumps(rows,indent=2))
assert any(row.get('status')==200 and row.get('excerpts') for row in rows),'No mature source retrieved'
