"""Specification tests and reproducible numerical envelope (not RTL evidence)."""
import itertools, json, random
from pathlib import Path
from csc_model import floating, bit_exact, matrix, round_half_away, F

def main():
    rng=random.Random(601709)
    report=[]
    assert [round_half_away(F(x,2)) for x in (-3,-1,1,3)]==[-2,-1,1,2]
    for bits,std,limited,op in itertools.product((8,10),('601','709'),(False,True),('forward','inverse','gray')):
        m=2**bits-1
        pixels=list(itertools.product((0,1,m//2,m-1,m),repeat=3))
        pixels += [(v,v,v) for v in range(m+1)]
        pixels += [tuple(rng.randrange(m+1) for _ in range(3)) for _ in range(4000)]
        maxerr=0
        for p in pixels:
            actual=bit_exact(p,bits,std,limited,op); expected=floating(p,bits,std,limited,op)
            maxerr=max(maxerr,max(abs(a-b) for a,b in zip(actual,expected)))
            assert all(0<=v<=m for v in actual)
        # Each coefficient quantization <= 0.5 ulp Q16. Three terms, then half-LSB rounding.
        bound=0.5+3*m/(2*65536)+1e-9
        assert maxerr <= bound,(bits,std,limited,op,maxerr,bound)
        if op in ('forward','gray'):
            s=1<<(bits-8); lo=16*s if limited else 0; hi=235*s if limited else m
            assert bit_exact((0,0,0),bits,std,limited,op)[0]==lo
            assert bit_exact((m,m,m),bits,std,limited,op)[0]==hi
            if op=='forward':
                assert bit_exact((m,m,m),bits,std,limited,op)[1:]==(1<<(bits-1),)*2
        report.append(dict(bits=bits,standard=std,limited=limited,operation=op,vectors=len(pixels),max_code_error=maxerr,bound=bound))
    for args in [dict(bits=9),dict(standard='2020'),dict(op='bad'),dict(limited=1)]:
        try: bit_exact((0,0,0),**args)
        except ValueError: pass
        else: raise AssertionError('invalid config accepted')
    for p in [(-1,0,0),(256,0,0),(0,0),(0.0,0,0)]:
        try: bit_exact(p)
        except ValueError: pass
        else: raise AssertionError('invalid pixel accepted')
    result=dict(status='PASS',scope='Independent model specification only; no RTL or hardware claim',seed=601709,configurations=report)
    Path(__file__).with_name('csc_model_results.json').write_text(json.dumps(result,indent=2)+'\n')
    print('PASS 24 configurations;',sum(x['vectors'] for x in report),'vectors; max error',max(x['max_code_error'] for x in report))

if __name__=='__main__': main()
