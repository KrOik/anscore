import urllib.request,hashlib,json,datetime
from pathlib import Path
import scipy.ndimage._morphology as installed
urls=[
 'https://raw.githubusercontent.com/scipy/scipy/v1.15.3/scipy/ndimage/_morphology.py',
 'https://raw.githubusercontent.com/opencv/opencv/2.4/modules/contrib/src/chamfermatching.cpp']
records=[];opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
for url in urls:
 try:
  with opener.open(url,timeout=8) as f:data=f.read()
  records.append(dict(url=url,status='retrieved',bytes=len(data),sha256=hashlib.sha256(data).hexdigest()))
 except Exception as exc:records.append(dict(url=url,status='unavailable',error=f'{type(exc).__name__}: {exc}'))
p=Path(installed.__file__)
report=dict(checked_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),references=records,
 installed_scipy_actual_source=dict(path=str(p),bytes=p.stat().st_size,sha256=hashlib.sha256(p.read_bytes()).hexdigest()),
 formula='Directed average of exact squared Euclidean nearest-image-edge distances, sampled at translated template edge positions; not ordinary unsquared/symmetric Chamfer.')
Path(__file__).with_name('references.json').write_text(json.dumps(report,indent=2)+'\n');print(report)
