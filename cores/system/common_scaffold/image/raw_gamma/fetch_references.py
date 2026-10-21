from pathlib import Path
import subprocess,tempfile,hashlib,json,datetime
H=Path(__file__).resolve().parent
urls=['https://cdn.jsdelivr.net/gh/libcamera-org/libcamera@master/src/ipa/libipa/pwl.cpp','https://cdn.jsdelivr.net/gh/libcamera-org/libcamera@master/src/ipa/rpi/controller/rpi/contrast.cpp']
rows=[]
for url in urls:
 with tempfile.TemporaryDirectory(prefix='gamma_reference_') as td:
  p=Path(td)/'reference.cpp'
  r=subprocess.run(['curl.exe','-f','-L','--ssl-revoke-best-effort','--connect-timeout','10','--max-time','25','-o',str(p),url],capture_output=True)
  if r.returncode: rows.append({'url':url,'error':r.stderr.decode(errors='replace')[-300:]});continue
  data=p.read_bytes();lines=data.decode().splitlines();hits=[i for i,l in enumerate(lines) if any(s in l for s in ('Pwl::eval','gamma','Gamma','interpolate'))]
  rows.append({'url':url,'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data),'accessed_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'excerpts':[{'line':i+1,'text':'\n'.join(lines[max(0,i-2):i+5])} for i in hits[:8]],'relationship':'Conceptual software reference only; no source copied. This RTL uses uniform integer-domain nodes, exact rational nearest rounding, synchronous banks and streaming handshakes, not libcamera floating-point arbitrary-coordinate Pwl evaluation.'})
(H/'references.json').write_text(json.dumps(rows,indent=2)+'\n')
assert any('sha256' in row and row['excerpts'] for row in rows)
print(json.dumps(rows,indent=2))


