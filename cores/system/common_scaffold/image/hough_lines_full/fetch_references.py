"""Record actual upstream source retrieval, without retaining large downloads."""
import urllib.request,hashlib,json,datetime
from pathlib import Path
urls=[
 'https://raw.githubusercontent.com/scikit-image/scikit-image/v0.25.2/skimage/transform/_hough_transform.pyx',
 'https://raw.githubusercontent.com/scikit-image/scikit-image/v0.25.2/skimage/transform/hough_transform.py',
 'https://raw.githubusercontent.com/opencv/opencv/4.12.0/modules/imgproc/src/hough.cpp']
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
records=[]
for url in urls:
 with opener.open(url,timeout=30) as f:data=f.read()
 records.append(dict(url=url,bytes=len(data),sha256=hashlib.sha256(data).hexdigest()))
Path(__file__).with_name('references.json').write_text(json.dumps(dict(retrieved_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),references=records),indent=2)+'\n')
print(records)
