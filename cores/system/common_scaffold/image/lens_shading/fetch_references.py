import subprocess,tempfile,hashlib,json,datetime
from pathlib import Path
HERE=Path(__file__).resolve().parent
urls=[('Raspberry Pi libcamera ALSC','https://cdn.jsdelivr.net/gh/raspberrypi/libcamera@main/src/ipa/rpi/controller/rpi/alsc.cpp'),('Infinite-ISP Lens Shading Correction','https://cdn.jsdelivr.net/gh/10x-Engineers/Infinite-ISP@master/modules/lens_shading_correction/lens_shading_correction.py')]
rows=[]
for title,url in urls:
 with tempfile.TemporaryDirectory(prefix='lsc_reference_')as tmp:
  p=Path(tmp)/'source';run=subprocess.run(['curl.exe','-fsL','--ssl-revoke-best-effort','--max-time','25','-o',str(p),url],capture_output=True)
  if run.returncode:rows.append(dict(title=title,url=url,error=run.stderr.decode(errors='replace')[-300:]));continue
  data=p.read_bytes();lines=data.decode(errors='replace').splitlines();hits=[i for i,l in enumerate(lines)if any(k in l.lower()for k in('bilinear','interpolat','mesh','gain_r','gain_gr'))]
  row=dict(title=title,url=url,retrieved_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),sha256=hashlib.sha256(data).hexdigest(),bytes=len(data),excerpts=['\n'.join(lines[max(0,i-2):i+7])for i in hits[:8]],used='mature ISP gain-table/interpolation design reference only; fixed-point grid/rounding contract independently specified; no code copied')
  if 'Infinite' in title:row['used']='EXCLUDED: inspected execute() returns the unmodified image; placeholder is not an algorithm reference'
  else:
   start=next(i for i,l in enumerate(lines)if l.startswith('void resampleCalTable('));row['spatial_resample_excerpt']='\n'.join(lines[start:start+63])
  rows.append(row)
(HERE/'references.json').write_text(json.dumps(rows,indent=2)+'\n');print(json.dumps(rows))
