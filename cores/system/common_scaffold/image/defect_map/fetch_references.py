from pathlib import Path
import subprocess,tempfile,hashlib,json,datetime
H=Path(__file__).resolve().parent
urls=['https://cdn.jsdelivr.net/gh/ncruces/dcraw@master/dcraw.c','https://cdn.jsdelivr.net/gh/LibRaw/LibRaw@master/src/preprocessing/ext_preprocess.cpp']
rows=[]
for url in urls:
 with tempfile.TemporaryDirectory(prefix='defect_reference_') as td:
  p=Path(td)/'reference.c';r=subprocess.run(['curl.exe','-f','-L','--ssl-revoke-best-effort','--connect-timeout','10','--max-time','25','-o',str(p),url],capture_output=True)
  if r.returncode:rows.append({'url':url,'error':r.stderr.decode(errors='replace')[-300:]});continue
  data=p.read_bytes();lines=data.decode(errors='replace').splitlines();hits=[i for i,l in enumerate(lines) if 'void CLASS bad_pixels' in l]
  rows.append({'url':url,'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data),'accessed_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'excerpts':[{'line':i+1,'text':'\n'.join(lines[max(0,i-3):i+70])} for i in hits[:2]],'relationship':'Static calibrated bad-pixel list and same-CFA donor concept. No source copied. This RTL performs exhaustive nearest squared-distance search over original good map samples and averages every minimum-distance tie; it does not claim dcraw finite-radius neighborhood or directional algorithm equivalence.'})
  if hits:break
(H/'references.json').write_text(json.dumps(rows,indent=2)+'\n');assert any(row.get('excerpts') for row in rows);print(json.dumps(rows,indent=2))
