"""Independent direct-convolution rational resampling references."""
import math,cmath
from dataclasses import dataclass

def rne(n,d=32768):
 q,r=divmod(abs(n),d);q+=2*r>d or (2*r==d and q&1)
 return -q if n<0 else q

@dataclass(frozen=True)
class Config:
 l:int=1
 m:int=1
 coefficients:tuple=(32768,)
 def __post_init__(self):
  if not 1<=self.l<=8 or not 1<=self.m<=8:raise ValueError('L/M must be 1..8')
  if not self.l<=len(self.coefficients)<=128:raise ValueError('L <= taps <= 128')
  if any(not isinstance(c,int) or not -131072<=c<=131071 for c in self.coefficients):raise ValueError('signed18 coefficients required')

def design(l,m,taps=128):
 """Blackman-windowed sinc. Reference usable band <=0.1/max(L,M) cycles/high-rate tick.
 Cutoff0.3/max, stop begins0.5/max. Coefficient sum normalized to L.
 """
 if not 1<=l<=8 or not 1<=m<=8 or not max(l,8)<=taps<=128:raise ValueError('unsupported design')
 fc=.3/max(l,m);center=(taps-1)/2
 h=[]
 for n in range(taps):
  t=n-center;sinc=2*fc if t==0 else math.sin(2*math.pi*fc*t)/(math.pi*t)
  window=.42-.5*math.cos(2*math.pi*n/(taps-1))+.08*math.cos(4*math.pi*n/(taps-1))
  h.append(sinc*window)
 scale=l/math.fsum(h);h=[x*scale for x in h]
 quant=tuple(round(x*32768) for x in h);cfg=Config(l,m,quant)
 return cfg,h

def float_reference(samples,l,m,coefficients,flush=True):
 """Physical normalized amplitudes; coefficients are real, no sample quantization."""
 if not samples:return []
 end=(len(samples)-1)*l+len(coefficients)-1 if flush else len(samples)*l-1
 return [math.fsum(samples[n]/32768*coefficients[t-n*l] for n in range(len(samples)) if 0<=t-n*l<len(coefficients)) for t in range(0,end+1,m)]

def integer_reference(samples,cfg,flush=True):
 if not samples:return []
 end=(len(samples)-1)*cfg.l+len(cfg.coefficients)-1 if flush else len(samples)*cfg.l-1
 result=[]
 for t in range(0,end+1,cfg.m):
  # Direct n-domain convolution: independent of RTL's phase/shift registers.
  value=sum(x*cfg.coefficients[t-n*cfg.l] for n,x in enumerate(samples) if 0<=t-n*cfg.l<len(cfg.coefficients))
  wide=rne(value);result.append((min(32767,max(-32768,wide)),int(not -32768<=wide<=32767)))
 return result

def response(coefficients,l,f):
 return abs(sum((c/32768)*cmath.exp(-2j*math.pi*f*k) for k,c in enumerate(coefficients)))/l

def spectrum_metrics(cfg):
 k=max(cfg.l,cfg.m);pass_edge=.1/k;stop_edge=.5/k
 pass_values=[response(cfg.coefficients,cfg.l,pass_edge*i/128) for i in range(129)]
 stop_values=[response(cfg.coefficients,cfg.l,stop_edge+(.5-stop_edge)*i/512) for i in range(513)]
 return {'passband_edge_highrate':pass_edge,'stopband_edge_highrate':stop_edge,
         'passband_max_abs_db':max(abs(20*math.log10(max(v,1e-15))) for v in pass_values),
         'stopband_attenuation_db':-20*math.log10(max(max(stop_values),1e-15)),
         'dc_gain':response(cfg.coefficients,cfg.l,0)}
