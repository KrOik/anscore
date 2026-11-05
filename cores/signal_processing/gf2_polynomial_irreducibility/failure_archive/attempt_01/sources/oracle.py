"""Independent exact finite-field mathematics; no HDL, SymPy or package imports."""
from __future__ import annotations

def degree(f):
    return f.bit_length()-1

def division(a,b):
    """Complete degree-aligned long division, not the RTL clock schedule."""
    if not b:
        raise ValueError('zero polynomial divisor')
    q=0
    while a and degree(a)>=degree(b):
        k=degree(a)-degree(b)
        q ^= 1<<k
        a ^= b<<k
    return q,a

def gcd(a,b):
    while b:
        a,b=b,division(a,b)[1]
    return a

def derivative(f):
    return sum(((f>>i)&1)<<(i-1) for i in range(1,f.bit_length(),2))

def rank_columns(columns):
    pivots={}
    for column in columns:
        while column:
            k=degree(column)
            if k not in pivots:
                pivots[k]=column
                break
            column ^= pivots[k]
    return len(pivots)

def berlekamp(poly,d):
    """Q maps basis x**j to x**(2*j); a separate derivative excludes powers."""
    f=(1<<d)|poly
    columns=[division(1<<(2*j),f)[1] ^ (1<<j) for j in range(d)]
    rank=rank_columns(columns)
    repeated=gcd(f,derivative(f))
    return {'irreducible':repeated==1 and rank==d-1,
            'berlekamp_rank':rank,'nullity':d-rank,'derivative_gcd':repeated}

def streamed_remainder(a,b):
    """Bit-scan full-integer remainder, separate from degree-aligned division."""
    r=0
    top=1<<degree(b)
    for j in range(degree(a),-1,-1):
        r=(r<<1)|((a>>j)&1)
        if r & top:
            r ^= b
    return r

def square_complete(a):
    # Construct the entire unreduced square by the characteristic-two identity.
    return sum(((a>>j)&1)<<(2*j) for j in range(a.bit_length()))

def gcd_stream(a,b):
    while b:
        a,b=b,streamed_remainder(a,b)
    return a

def trial_irreducible(poly,d):
    f=(1<<d)|poly
    for k in range(1,d//2+1):
        for low in range(1<<k):
            if division(f,(1<<k)|low)[1]==0:
                return False
    return True

def checkpoints(d):
    primes=[q for q in range(2,d+1)
            if d%q==0 and all(q%j for j in range(2,q))]
    return sorted(d//q for q in primes)

def rabin(poly,d):
    f=(1<<d)|poly
    x=streamed_remainder(2,f)
    h=x
    rounds=[]
    cycles=0
    for i in range(1,d+1):
        h=streamed_remainder(square_complete(h),f)
        delta=h^x
        row={'i':i,'h':h,'delta':delta,'checkpoint':i in checkpoints(d)}
        cycles += d+2
        if row['checkpoint']:
            g=gcd_stream(f,delta)
            # A whole-division quotient audit gives the micro-operation count.
            a,b=f,delta;quotients=[]
            while b:
                q,r=division(a,b);quotients.append(q);a,b=b,r
            latency=sum(q.bit_count() for q in quotients)+len(quotients)+1
            assert a==g and latency<=3*d+1
            row.update(gcd=g,quotients=quotients,gcd_cycles=latency)
            cycles += latency+1
            rounds.append(row)
            if g!=1:
                return dict(irreducible=False,kind=1,index=i,delta=delta,
                            witness_gcd=g,cycles=cycles,rounds=rounds)
        else:
            rounds.append(row)
    return dict(irreducible=h==x,kind=0 if h==x else 2,index=d,
                delta=h^x,witness_gcd=1,cycles=cycles,rounds=rounds)

def certificate(poly,d,tag):
    primary=berlekamp(poly,d)
    secondary=rabin(poly,d)
    assert primary['irreducible']==secondary['irreducible']
    if d<=8:
        assert trial_irreducible(poly,d)==primary['irreducible']
    assert secondary['cycles']<=d*(d+2)+len(checkpoints(d))*(3*d+2)
    return dict(poly=poly,tag=tag,**primary,**{k:v for k,v in secondary.items() if k!='irreducible'})

def gcd_probe_states(f,delta):
    """Only a reset-predicate/timing audit, never the arithmetic oracle.

    Full quotient monomials predict the registered u/v values before each
    cancellation and swap, including zero remainders and the final check.
    """
    u,v=f,delta
    result=[]
    while v:
        q,r=division(u,v)
        for k in range(degree(q),-1,-1):
            if (q>>k)&1:
                result.append(dict(u=u,v=v,event='cancel',shift=k,
                                   cancels_to_zero=(u^(v<<k))==0))
                u ^= v<<k
        assert u==r
        result.append(dict(u=u,v=v,event='swap_zero' if not u else 'swap_nonzero'))
        u,v=v,u
    result.append(dict(u=u,v=v,event='done'))
    return result
