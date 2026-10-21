import hashlib,json,tempfile,subprocess,datetime
from pathlib import Path
HERE=Path(__file__).resolve().parent
sources=[('OpenCV StereoSGBM documentation','https://docs.opencv.org/4.x/d2/d85/classcv_1_1StereoSGBM.html'),('Hirschmueller CVPR 2005 paper','https://elib.dlr.de/55364/1/04361082.pdf'),('OpenCV SGBM implementation','https://raw.githubusercontent.com/opencv/opencv/4.x/modules/calib3d/src/stereosgbm.cpp')]
rows=[]
for title,url in sources:
 with tempfile.TemporaryDirectory(prefix='sgm_reference_')as tmp:
  p=Path(tmp)/'asset';run=subprocess.run(['curl.exe','-f','-L','--ssl-revoke-best-effort','--max-time','35','-o',str(p),url],capture_output=True)
  if run.returncode:rows.append(dict(title=title,url=url,error=run.stderr.decode(errors='replace')[-800:]));continue
  data=p.read_bytes();row=dict(title=title,url=url,status=200,bytes=len(data),sha256=hashlib.sha256(data).hexdigest(),used='conceptual reference; no code copied',retrieved_utc=datetime.datetime.now(datetime.timezone.utc).isoformat())
  if title=='OpenCV SGBM implementation':
   text=data.decode();lines=text.splitlines();hits=[i for i,l in enumerate(lines)if 'L_r(p, d)' in l];row['recurrence_excerpts']=['\n'.join(lines[max(0,i-2):i+9])for i in hits[:3]]
  rows.append(row)
(HERE/'references.json').write_text(json.dumps(rows,indent=2)+'\n');print(json.dumps(rows))
