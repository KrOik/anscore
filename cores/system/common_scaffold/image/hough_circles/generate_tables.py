"""Unique integer midpoint-circle circumference offsets, radii 1..31."""
from pathlib import Path
import json,urllib.request,datetime,hashlib,argparse
ROOT=Path(__file__).resolve().parent
def ring(radius):
 x=radius;y=0;decision=1-radius;points=set()
 while x>=y:
  for a,b in ((x,y),(y,x),(-x,y),(-y,x),(x,-y),(y,-x),(-x,-y),(-y,-x)):points.add((a,b))
  y+=1
  if decision<0:decision+=2*y+1
  else:x-=1;decision+=2*(y-x)+1
 return sorted(points,key=lambda p:(p[1],p[0]))
def generate():
 offsets=[];metadata=[0];counts={}
 for r in range(1,32):
  points=ring(r);metadata.append((len(points)<<12)|len(offsets));counts[r]=len(points)
  offsets.extend(((dy&63)<<6)|(dx&63) for dx,dy in points)
 assert len(offsets)<4096 and max(counts.values())<256
 (ROOT/'offsets.mem').write_text(''.join(f'{v:03x}\n' for v in offsets+[0]*(4096-len(offsets))))
 (ROOT/'metadata.mem').write_text(''.join(f'{v:05x}\n' for v in metadata))
 (ROOT/'ring_counts.json').write_text(json.dumps(counts,indent=2)+'\n')
def references():
 urls=['https://raw.githubusercontent.com/scikit-image/scikit-image/v0.24.0/skimage/transform/_hough_transform.pyx','https://raw.githubusercontent.com/scikit-image/scikit-image/v0.24.0/skimage/draw/_draw.pyx','https://raw.githubusercontent.com/opencv/opencv/4.x/modules/imgproc/src/hough.cpp']
 opener=urllib.request.build_opener(urllib.request.ProxyHandler({}));records=[]
 for url in urls:
  error=None
  for attempt in range(3):
   try:data=opener.open(url,timeout=20).read();error=None;break
   except Exception as e:error=str(e)
  if error:records.append({'url':url,'error':error})
  else:records.append({'url':url,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),'accessed_utc':datetime.datetime.now(datetime.timezone.utc).isoformat()})
 (ROOT/'references.json').write_text(json.dumps(records,indent=2)+'\n')
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--fetch',action='store_true');a=p.parse_args();generate()
 if a.fetch:references()
