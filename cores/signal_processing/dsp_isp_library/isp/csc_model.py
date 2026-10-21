"""Independent CSC oracles; no RTL output is consumed. Python standard library."""
from fractions import Fraction as F
import math

FRAC = 16

def validate(bits, standard, limited, op, pixel):
    if bits not in (8, 10) or standard not in ('601', '709') or op not in ('forward', 'inverse', 'gray'):
        raise ValueError('unsupported CSC configuration')
    if not isinstance(limited, bool) or len(pixel) != 3 or any(type(x) is not int or not 0 <= x < 2**bits for x in pixel):
        raise ValueError('invalid pixel/range')

def parameters(bits, standard, limited):
    kr, kb = (F(299,1000), F(114,1000)) if standard == '601' else (F(2126,10000), F(722,10000))
    m, scale = 2**bits-1, 2**(bits-8)
    return kr, kb, m, 16*scale if limited else 0, 219*scale if limited else m, 224*scale if limited else m, 2**(bits-1)

def floating(pixel, bits=8, standard='601', limited=False, op='forward'):
    """Normalized signal equations evaluated in float, before final rounding."""
    validate(bits, standard, limited, op, pixel)
    kr,kb,m,yo,ys,cs,mid = parameters(bits,standard,limited)
    kr,kb = float(kr),float(kb)
    kg=1-kr-kb
    if op == 'inverse':
        y,cb,cr=(pixel[0]-yo)/ys,(pixel[1]-mid)/cs,(pixel[2]-mid)/cs
        r=y+2*(1-kr)*cr; b=y+2*(1-kb)*cb; g=(y-kr*r-kb*b)/kg
        out=(r*m,g*m,b*m)
    else:
        r,g,b=(p/m for p in pixel)
        y=kr*r+kg*g+kb*b
        out=(yo+ys*y,) if op == 'gray' else (yo+ys*y,mid+cs*(b-y)/(2*(1-kb)),mid+cs*(r-y)/(2*(1-kr)))
    return tuple(max(0., min(float(m), v)) for v in out)

def round_half_away(v):
    """Exact rational ties away from zero, used for coefficient quantization."""
    if v < 0: return -round_half_away(-v)
    return (2*v.numerator+v.denominator)//(2*v.denominator)

def matrix(bits=8, standard='601', limited=False, op='forward'):
    """Exact rational affine matrix -> signed Q16 integer coefficients."""
    validate(bits,standard,limited,op,(0,0,0))
    kr,kb,m,yo,ys,cs,mid=parameters(bits,standard,limited); kg=1-kr-kb
    if op == 'inverse':
        a=((F(m,ys),0,F(2*m,cs)*(1-kr)),
           (F(m,ys),-F(2*m,cs)*kb*(1-kb)/kg,-F(2*m,cs)*kr*(1-kr)/kg),
           (F(m,ys),F(2*m,cs)*(1-kb),0))
        offsets=(-yo,-mid,-mid); bias=(0,0,0)
    else:
        a=((ys*kr/m,ys*kg/m,ys*kb/m),
           (-cs*kr/(2*m*(1-kb)),-cs*kg/(2*m*(1-kb)),F(cs,2*m)),
           (F(cs,2*m),-cs*kg/(2*m*(1-kr)),-cs*kb/(2*m*(1-kr))))
        offsets=(0,0,0); bias=(yo,mid,mid)
        if op=='gray': a=a[:1]; bias=bias[:1]
    return tuple(tuple(round_half_away(F(c)*2**FRAC) for c in row) for row in a),offsets,bias

def bit_exact(pixel,bits=8,standard='601',limited=False,op='forward'):
    validate(bits,standard,limited,op,pixel)
    a,offsets,bias=matrix(bits,standard,limited,op)
    out=[]
    for row,b in zip(a,bias):
        acc=sum(c*(p+o) for c,p,o in zip(row,pixel,offsets))+(b<<FRAC)
        q=(abs(acc)+(1<<(FRAC-1)))>>FRAC
        q=-q if acc < 0 else q
        out.append(max(0,min(2**bits-1,q)))
    return tuple(out)
