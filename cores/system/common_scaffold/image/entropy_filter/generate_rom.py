"""192 x 20-bit contributions to exact 8-bit local Shannon entropy in Q20 bits."""
from decimal import Decimal,localcontext,ROUND_HALF_UP
from pathlib import Path

def values():
    result=[]
    with localcontext() as c:
        c.prec=70
        for n in (9,25,49):
            for count in range(64):
                if count==0 or count>=n:result.append(0)
                else:
                    p=Decimal(count)/Decimal(n)
                    v=-p*(p.ln()/Decimal(2).ln())*Decimal(1<<20)
                    result.append(int(v.to_integral_value(rounding=ROUND_HALF_UP)))
    assert len(result)==192 and max(result)<1<<20
    return result

def content():return ''.join(f'{v:05x}\n' for v in values())

if __name__=='__main__':
    (Path(__file__).resolve().parent/'entropy.mem').write_text(content(),encoding='ascii')
