"""Unbounded integer matrix/interpolation model; no HDL state-machine emulation."""
import json,math
from pathlib import Path
ROOT=Path(__file__).resolve().parent
MATRIX=json.loads((ROOT/'coefficients.json').read_text())
def signed_file(name,bits):
 return [int(s,16)-(1<<bits) if int(s,16)&(1<<(bits-1)) else int(s,16) for s in (ROOT/name).read_text().split()]
DECODE=signed_file('decode.mem',19);NONLINEAR=signed_file('nonlinear.mem',26)
def rounding(v,bits=16):return (-1 if v<0 else 1)*((abs(int(v))+(1<<(bits-1)))>>bits)
def clamp(v,maximum=255):return max(0,min(maximum,int(v)))
def interpolate(v,kind):
 if kind==2:offset=clamp(v+32768,163840);i,frac=divmod(offset,128);base=2050;shift=7
 else:offset=clamp(v,65536);i,frac=divmod(offset,64);base=1025 if kind==1 else 0;shift=6
 return NONLINEAR[base+i]+((NONLINEAR[base+i+1]-NONLINEAR[base+i])*frac+(1<<(shift-1)))//(1<<shift)
def oracle(pixel,inverse=False):
 p=list(map(int,pixel))
 if inverse:
  fy=DECODE[256+p[0]];v=[fy+DECODE[512+p[1]],fy,fy-DECODE[768+p[2]]]
  xyz=[interpolate(x,2) for x in v]
  linear=[clamp(rounding(sum(a*b for a,b in zip(row,xyz))),65536) for row in MATRIX['inverse']]
  return tuple(clamp(rounding(interpolate(x,1))) for x in linear)
 linear=[DECODE[x] for x in p]
 xyz=[clamp(rounding(sum(a*b for a,b in zip(row,linear))),65536) for row in MATRIX['forward']]
 fx,fy,fz=[interpolate(x,0) for x in xyz]
 return (clamp((fy*29580-267386880+3276800)//6553600),clamp(rounding(500*(fx-fy))+128),clamp(rounding(200*(fy-fz))+128))
def mathematical(pixel,inverse=False):
 """Independent direct floating CIE equations, no fixed-point ROM access."""
 pixel=tuple(map(int,pixel))
 if inverse:
  L,a,b=pixel[0]*100/255,pixel[1]-128,pixel[2]-128
  fy=(L+16)/116
  f=lambda t:t**3 if t>6/29 else 3*(6/29)**2*(t-4/29)
  X,Y,Z=f(fy+a/500)*.95047,f(fy),f(fy-b/200)*1.08883
  v=[3.2404542*X-1.5371385*Y-.4985314*Z,-.9692660*X+1.8760108*Y+.0415560*Z,.0556434*X-.2040259*Y+1.0572252*Z]
  g=lambda t:12.92*t if t<=.0031308 else 1.055*t**(1/2.4)-.055
  out=[g(max(0,min(1,t)))*255 for t in v]
 else:
  g=lambda t:t/12.92 if t<=.04045 else ((t+.055)/1.055)**2.4
  r,gc,b=[g(t/255) for t in pixel]
  X=(.4124564*r+.3575761*gc+.1804375*b)/.95047;Y=.2126729*r+.7151522*gc+.072175*b;Z=(.0193339*r+.1191920*gc+.9503041*b)/1.08883
  f=lambda t:t**(1/3) if t>(6/29)**3 else t/(3*(6/29)**2)+4/29
  fx,fy,fz=map(f,(X,Y,Z));out=[(116*fy-16)*255/100,500*(fx-fy)+128,200*(fy-fz)+128]
 return tuple(clamp(math.floor(x+.5)) for x in out)
