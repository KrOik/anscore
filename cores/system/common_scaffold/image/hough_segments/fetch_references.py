"""Record actual upstream source retrieval, without retaining large downloads."""
import urllib.request,hashlib,json,datetime,sys
from pathlib import Path
urls=[
 'https://raw.githubusercontent.com/scikit-image/scikit-image/v0.25.2/skimage/transform/_hough_transform.pyx',
 'https://raw.githubusercontent.com/scikit-image/scikit-image/v0.25.2/skimage/transform/hough_transform.py',
 'https://raw.githubusercontent.com/opencv/opencv/4.12.0/modules/imgproc/src/hough.cpp']
if '--reuse-existing' in sys.argv:
 prior=Path(__file__).resolve().parent.parent/'hough_lines_full'/'references.json'
 data=json.loads(prior.read_text());assert {z['url'] for z in data['references']}==set(urls)
 data.update(provenance='Previous successful direct retrieval in the same Hough development session; segment-task fresh retry timed out twice.',
  prior_evidence_sha256=hashlib.sha256(prior.read_bytes()).hexdigest(),fresh_segment_retrieval=False)
 Path(__file__).with_name('references.json').write_text(json.dumps(data,indent=2)+'\n');print('Reused explicit prior retrieval metadata');sys.exit(0)
opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
records=[]
for url in urls:
 with opener.open(url,timeout=30) as f:data=f.read()
 records.append(dict(url=url,bytes=len(data),sha256=hashlib.sha256(data).hexdigest()))
Path(__file__).with_name('references.json').write_text(json.dumps(dict(retrieved_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),references=records),indent=2)+'\n')
print(records)
