from pathlib import Path
import math,json,hashlib,urllib.request,datetime,argparse
ROOT=Path(__file__).resolve().parent
def nearest(x):return math.floor(x+.5) if x>=0 else -math.floor(-x+.5)
def generate():
 values=[(nearest(math.cos(2*math.pi*k/32)*32768),nearest(-math.sin(2*math.pi*k/32)*32768)) for k in range(16)]
 (ROOT/'twiddle.mem').write_text(''.join(f'{((r&0x1ffff)<<17)|(i&0x1ffff):09x}\n' for r,i in values))
def references(proxy=None):
 urls=['https://raw.githubusercontent.com/opencv/opencv/4.x/modules/imgproc/src/phasecorr.cpp','https://raw.githubusercontent.com/numpy/numpy/main/numpy/fft/__init__.py','https://raw.githubusercontent.com/scikit-image/scikit-image/v0.24.0/skimage/registration/_phase_cross_correlation.py']
 opener=urllib.request.build_opener(urllib.request.ProxyHandler({'https':proxy} if proxy else {}))
 result=[]
 for url in urls:
  error=None
  for attempt in range(3):
   try:
    data=opener.open(url,timeout=30).read();error=None;break
   except Exception as e:error=str(e)
  if error:result.append({'url':url,'error':error})
  else:result.append({'url':url,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),'accessed_utc':datetime.datetime.now(datetime.timezone.utc).isoformat()})
 (ROOT/'references.json').write_text(json.dumps(result,indent=2)+'\n')
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('--fetch',action='store_true');p.add_argument('--proxy');a=p.parse_args();generate()
 if a.fetch:references(a.proxy)
