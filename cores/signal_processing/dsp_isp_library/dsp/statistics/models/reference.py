"""Independent floating and integer statistics models; no RTL dependencies."""
from dataclasses import dataclass
import math

def rne(n, d):
    q,r=divmod(abs(n),d)
    q += 2*r>d or (2*r==d and q&1)
    return -q if n<0 else q

@dataclass(frozen=True)
class Config:
    block: bool = False
    log2: int = 4
    scale: int = 0
    threshold: int = 0x10000000
    def __post_init__(self):
        if not 0<=self.log2<=6 or not -8<=self.scale<=15 or not 0<=self.threshold<=0xffffffff:
            raise ValueError('unsupported statistics configuration')

def scale_fixed(x, shift):
    if not -32768<=x<=32767: raise ValueError('signed16 input required')
    wide=rne(x,1<<shift) if shift>=0 else x*(1<<-shift)
    return min(32767,max(-32768,wide)), not -32768<=wide<=32767

class IntegerModel:
    def __init__(self,cfg=Config()): self.configure(cfg)
    def configure(self,cfg):
        self.cfg=cfg; self.history=[]; self.index=0
    def step(self,x):
        cfg=self.cfg; n=1<<cfg.log2
        value,clip=scale_fixed(x,cfg.scale)
        self.history.append((abs(value),self.index,clip)); self.index=(self.index+1)&0xffffffff
        if not cfg.block: self.history=self.history[-n:]
        elif len(self.history)<n: return None
        h=self.history
        meanabs=rne(sum(a for a,_,_ in h),n)
        power=rne(sum(a*a for a,_,_ in h),n)
        peak=max(a for a,_,_ in h)
        pos=next(i for a,i,_ in h if a==peak)
        result={'amplitude':abs(value),'meanabs':meanabs,'power':power,
                'rms':math.isqrt(power),'peak':peak,'position':pos,
                'clipped':any(c for _,_,c in h),'threshold':power>=cfg.threshold}
        if cfg.block:self.history=[]
        return result

def pack(result):
    if result is None:return None
    r=result
    data=(r['position']<<96)|(r['power']<<64)|(r['meanabs']<<48)|(r['rms']<<32)|(r['peak']<<16)|r['amplitude']
    return data,int(r['clipped'])|(int(r['threshold'])<<1)

def floating_reference(samples,cfg):
    """Normalized float reference, independent direct sums; no fixed model call.

    Scaling is ideal float followed by clipping, before integer input quantization.
    Outputs do not round means or sqrt. Position is integer source sample index.
    """
    h=[]; out=[]; n=1<<cfg.log2
    for index,x in enumerate(samples):
        v=min(32767/32768,max(-1,x/32768*2.0**(-cfg.scale)))
        h.append((abs(v),index))
        if not cfg.block:h=h[-n:]
        elif len(h)<n:continue
        a=[p[0] for p in h]; power=math.fsum(v*v for v in a)/n
        peak=max(a)
        out.append({'meanabs':math.fsum(a)/n,'power':power,'rms':math.sqrt(power),
                    'peak':peak,'position':next(i for v,i in h if v==peak)})
        if cfg.block:h=[]
    return out
