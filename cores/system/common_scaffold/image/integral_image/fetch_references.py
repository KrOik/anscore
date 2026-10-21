from pathlib import Path
import datetime,hashlib,json,subprocess,tempfile
H=Path(__file__).resolve().parent
urls=[('OpenCV integral scalar/SIMD implementation','https://cdn.jsdelivr.net/gh/opencv/opencv@4.x/modules/imgproc/src/sumpixels.simd.hpp'),('OpenCV integral dispatch','https://cdn.jsdelivr.net/gh/opencv/opencv@4.x/modules/imgproc/src/sumpixels.dispatch.cpp')]
rows=[]
for title,url in urls:
 with tempfile.TemporaryDirectory(prefix='integral_reference_')as td:
  p=Path(td)/'source';r=subprocess.run(['curl.exe','-fsL','--ssl-revoke-best-effort','--max-time','30','-o',str(p),url],capture_output=True)
  if r.returncode:rows.append(dict(title=title,url=url,error=r.stderr.decode(errors='replace')[-400:]));continue
  data=p.read_bytes();lines=data.decode(errors='replace').splitlines();hits=[i for i,l in enumerate(lines)if any(k in l for k in ('integral_', 'sqsum', 'memset(sum', 'sum[0]', 'sqsum[0]', 'Size isize'))]
  rows.append(dict(title=title,url=url,retrieved_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),sha256=hashlib.sha256(data).hexdigest(),bytes=len(data),excerpts=['\n'.join(lines[max(0,i-2):i+7])for i in hits[:18]],use='Mature integral/squared integral recurrence and zero border reviewed; no code copied. Actual cv2.integral2 is executed independently in run_tests.py; rectangular query uses exact half-open local contract.'))
  if 'dispatch' in url:
   start=next(i for i,l in enumerate(lines)if l.startswith('void integral_('))
   rows[-1]['scalar_sum_and_square_excerpt']='\n'.join(lines[start:start+87])
(H/'references.json').write_text(json.dumps(rows,indent=2)+'\n');print(json.dumps([dict(title=r['title'],bytes=r.get('bytes'),error=r.get('error'))for r in rows]))
