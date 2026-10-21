"""Independent floating/direct-form and integer DF-II-T SOS references."""
import math
from dataclasses import dataclass
COEF_FRAC=15
JURY_MARGIN=32
IDENTITY=(32768,0,0,0,0)

def rne(n,d=32768):
    q,r=divmod(abs(n),d)
    q+=2*r>d or (2*r==d and q&1)
    return -q if n<0 else q

def validate(sections,max_sos=4):
    if not 1<=len(sections)<=max_sos:raise ValueError('unsupported section count')
    for section in sections:
        if len(section)!=5 or any(not isinstance(c,int) or not -131072<=c<=131071 for c in section):
            raise ValueError('signed18 Q3.15 coefficients required')
        _,_,_,a1,a2=section
        if min(32768+a1+a2,32768-a1+a2,32768-a2)<JURY_MARGIN:
            raise ValueError('quantized denominator fails conservative Jury margin')

@dataclass(frozen=True)
class Config:
    sections: tuple=(IDENTITY,)
    def __post_init__(self):validate(self.sections)

def lowpass(fs=48000,fc=2000,q=math.sqrt(.5)):
    if not fs>0 or not 0<fc<fs/2 or q<=0:raise ValueError('invalid filter design')
    w=2*math.pi*fc/fs;c=math.cos(w);alpha=math.sin(w)/(2*q);a0=1+alpha
    coeff=((1-c)/2/a0,(1-c)/a0,(1-c)/2/a0,-2*c/a0,(1-alpha)/a0)
    quant=tuple(round(v*32768) for v in coeff);validate((quant,))
    return quant

def float_reference(samples,cfg):
    """Float direct-form I recurrence, using quantized coefficients as real values.

    Normalized signed16 I/O, per-section saturation but no sample quantization.
    State realization intentionally differs from integer/RTL transposed form.
    """
    history=[[0.,0.,0.,0.] for _ in cfg.sections];out=[]
    for sample in samples:
        x=sample/32768
        for k,section in enumerate(cfg.sections):
            b0,b1,b2,a1,a2=[c/32768 for c in section]
            x1,x2,y1,y2=history[k]
            y=min(32767/32768,max(-1,b0*x+b1*x1+b2*x2-a1*y1-a2*y2))
            history[k]=[x,x1,y,y1];x=y
        out.append(x)
    return out

class IntegerModel:
    def __init__(self,max_sos=4):
        self.max_sos=max_sos;self.sections=(IDENTITY,);self.state=[[0,0] for _ in range(max_sos)]
    def configure(self,sections,clear=True):
        sections=tuple(tuple(s) for s in sections)
        validate(sections,self.max_sos)
        if not clear and len(sections)!=len(self.sections):raise ValueError('retain requires same section count')
        self.sections=sections
        if clear:self.state=[[0,0] for _ in range(self.max_sos)]
    def step(self,x):
        if not isinstance(x,int) or not -32768<=x<=32767:raise ValueError('signed16 input required')
        clip=False
        for k,(b0,b1,b2,a1,a2) in enumerate(self.sections):
            s1,s2=self.state[k]
            wide=rne(b0*x+s1);y=min(32767,max(-32768,wide));clip|=y!=wide
            self.state[k]=[b1*x-a1*y+s2,b2*x-a2*y]
            assert all(-(1<<35)<=s<(1<<35) for s in self.state[k])
            x=y
        return x,int(clip)

def pack_coefficients(sections,max_sos=4):
    validate(sections,max_sos)
    return sum((c&0x3ffff)<<(18*(k*5+i)) for k,s in enumerate(sections) for i,c in enumerate(s))
