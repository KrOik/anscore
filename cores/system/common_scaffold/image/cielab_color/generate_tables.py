"""Generate bounded fixed-point D65/sRGB transfer ROMs from published formulas."""
from pathlib import Path
import math,json,hashlib,urllib.request,datetime
ROOT=Path(__file__).resolve().parent
def nearest(x):return math.floor(x+0.5) if x>=0 else -math.floor(-x+0.5)
def linear(x):return x/12.92 if x<=.04045 else ((x+.055)/1.055)**2.4
def srgb(x):return 12.92*x if x<=.0031308 else 1.055*x**(1/2.4)-.055
def labf(x):return x**(1/3) if x>(6/29)**3 else x/(3*(6/29)**2)+4/29
def invf(x):return x**3 if x>6/29 else 3*(6/29)**2*(x-4/29)
def generate():
 decode=[nearest(linear(i/255)*65536) for i in range(256)]
 decode += [nearest((i*100/255+16)/116*65536) for i in range(256)]
 decode += [nearest((i-128)/500*65536) for i in range(256)]
 decode += [nearest((i-128)/200*65536) for i in range(256)]
 nonlinear=[nearest(labf(i/1024)*65536) for i in range(1025)]
 nonlinear += [nearest(srgb(i/1024)*255*65536) for i in range(1025)]
 nonlinear += [nearest(invf(-.5+i/512)*65536) for i in range(1281)]
 nonlinear += [0]*(4096-len(nonlinear))
 (ROOT/'decode.mem').write_text(''.join(f'{v&0x7ffff:05x}\n' for v in decode))
 (ROOT/'nonlinear.mem').write_text(''.join(f'{v&0x3ffffff:07x}\n' for v in nonlinear))
 f=[[.4124564/.95047,.3575761/.95047,.1804375/.95047],[.2126729,.7151522,.0721750],[.0193339/1.08883,.1191920/1.08883,.9503041/1.08883]]
 r=[[3.2404542*.95047,-1.5371385,-.4985314*1.08883],[-.9692660*.95047,1.8760108,.0415560*1.08883],[.0556434*.95047,-.2040259,1.0572252*1.08883]]
 forward=[[nearest(x*65536) for x in row] for row in f]
 for row in forward:row[max(range(3),key=lambda i:row[i])]+=65536-sum(row)
 reverse=[[nearest(x*65536) for x in row] for row in r]
 (ROOT/'coefficients.json').write_text(json.dumps({'forward':forward,'inverse':reverse},indent=2)+'\n')
 return forward,reverse
def references(proxy=None):
 urls=['https://raw.githubusercontent.com/opencv/opencv/4.x/modules/imgproc/src/color_lab.cpp','https://www.brucelindbloom.com/index.html?Eqn_RGB_XYZ_Matrix.html','https://www.w3.org/TR/css-color-4/']
 result=[]
 for url in urls:
  try:
   opener=urllib.request.build_opener(urllib.request.ProxyHandler({'https':proxy})) if proxy else urllib.request.build_opener()
   data=opener.open(urllib.request.Request(url,headers={'User-Agent':'Mozilla/5.0'}),timeout=30).read()
   result.append({'url':url,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest(),'accessed_utc':datetime.datetime.now(datetime.timezone.utc).isoformat()})
  except Exception as e:result.append({'url':url,'error':str(e)})
 (ROOT/'references.json').write_text(json.dumps(result,indent=2)+'\n')
if __name__=='__main__':
 import argparse
 parser=argparse.ArgumentParser();parser.add_argument('--fetch',action='store_true');parser.add_argument('--proxy');args=parser.parse_args()
 print(generate())
 if args.fetch:references(args.proxy)
