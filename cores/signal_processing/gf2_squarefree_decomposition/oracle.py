"""Exact independent factorization, SFD crosscheck, and a separate timing audit.

No SymPy, existing package, HDL or external process is imported or executed.
Only explicitly authorized preparation calls these functions.
"""

def degree(f):return f.bit_length()-1

def divide(a,b):
    if not b:raise ValueError('zero polynomial divisor')
    quotient=0
    while a and degree(a)>=degree(b):
        j=degree(a)-degree(b);quotient^=1<<j;a^=b<<j
    return quotient,a

def exact_quotient(a,b):
    q,r=divide(a,b)
    assert r==0
    return q

def gcd(a,b):
    while b:a,b=b,divide(a,b)[1]
    return a

def multiply(a,b):
    return _xor(a<<j for j in range(b.bit_length()) if b>>j&1)

def _xor(values):
    result=0
    for x in values:result^=x
    return result

def power(a,e):
    result=1
    for _ in range(e):result=multiply(result,a)
    return result

def derivative(f):
    return sum(((f>>j)&1)<<(j-1) for j in range(1,f.bit_length(),2))

def square_root(f):
    assert not any(f>>j&1 for j in range(1,f.bit_length(),2))
    return sum(((f>>(2*j))&1)<<j for j in range((f.bit_length()+1)//2))

def kernel(f):
    """RREF nullspace of the full Berlekamp Q-I matrix, with row elimination."""
    n=degree(f)
    assert n>=1
    columns=[divide(1<<(2*j),f)[1]^(1<<j) for j in range(n)]
    rows=[sum(((columns[j]>>i)&1)<<j for j in range(n)) for i in range(n)]
    pivots=[]
    for j in range(n):
        pivot=next((i for i in range(len(pivots),n) if rows[i]>>j&1),None)
        if pivot is None:continue
        k=len(pivots);rows[k],rows[pivot]=rows[pivot],rows[k]
        for i in range(n):
            if i!=k and rows[i]>>j&1:rows[i]^=rows[k]
        pivots.append(j)
    basis=[]
    for free in range(n):
        if free not in pivots:
            value=1<<free
            for i,pivot in enumerate(pivots):
                if rows[i]>>free&1:value|=1<<pivot
            assert _xor(columns[j] for j in range(n) if value>>j&1)==0
            basis.append(value)
    return basis

def split_squarefree(f):
    if f==1:return []
    assert gcd(f,derivative(f))==1
    basis=kernel(f);factors=[f]
    # Each basis element separates its zero/one components. All basis elements,
    # not random combinations or a try-until-split search, are visited once.
    for b in basis:
        pieces=[]
        for h in factors:
            g=gcd(h,b)
            pieces.extend([g,exact_quotient(h,g)] if g not in [1,h] else [h])
        factors=pieces
    assert len(factors)==len(basis)
    assert all(len(kernel(h))==1 for h in factors)
    return sorted(factors)

def order(exponent):
    twopart=(exponent&-exponent).bit_length()-1
    return twopart,exponent>>twopart

def primary(f):
    """Collect ALL irreducibles; then count powers by dividing the ORIGINAL P.

    This does not reproduce the DUT's successive W/C/Y/Z multiplicity loop.
    At most floor(log2(D))+1 derivative/root layers are visited. A full fixed
    nullspace basis, bounded by degree, replaces randomized splitting.
    """
    current=f;irreducibles=set();layers=0
    while current!=1:
        repeated=gcd(current,derivative(current))
        odd=exact_quotient(current,repeated)
        irreducibles.update(split_squarefree(odd))
        current=square_root(repeated);layers+=1
    assert layers<=degree(f).bit_length()
    remaining=f;groups={};audit=[]
    for h in sorted(irreducibles):
        multiplicity=0
        while True:
            quotient,remainder=divide(remaining,h)
            if remainder:break
            remaining=quotient;multiplicity+=1
        assert multiplicity>=1
        groups[multiplicity]=multiply(groups.get(multiplicity,1),h)
        audit.append(dict(factor=h,degree=degree(h),multiplicity=multiplicity,
                          berlekamp_nullity=len(kernel(h))))
    assert remaining==1
    return [dict(factor=groups[e],multiplicity=e,degree=degree(groups[e]))
            for e in sorted(groups,key=order)],audit

def secondary(f):
    """Characteristic-two squarefree decomposition, whole polynomial steps."""
    result=[];scale=1
    while f!=1:
        c=gcd(f,derivative(f));w=exact_quotient(f,c);i=1
        while w!=1:
            y=gcd(w,c);z=exact_quotient(w,y);c=exact_quotient(c,y);w=y
            if z!=1:result.append(dict(factor=z,multiplicity=i*scale,degree=degree(z)))
            i+=1
        f=square_root(c);scale*=2
    return result

def small_trial(f):
    """Exhaust all fixed monic factor domains; divide only irreducibles."""
    remaining=f;groups={};d=degree(f)
    for k in range(1,d+1):
        for low in range(1<<k):
            h=(1<<k)|low
            if any(divide(h,(1<<j)|v)[1]==0 for j in range(1,k//2+1) for v in range(1<<j)):
                continue
            e=0
            while divide(remaining,h)[1]==0:remaining=exact_quotient(remaining,h);e+=1
            if e:groups[e]=multiply(groups.get(e,1),h)
    assert remaining==1
    return [dict(factor=groups[e],multiplicity=e,degree=degree(groups[e]))
            for e in sorted(groups,key=order)]

def certificate(poly,d,tag):
    assert 1<=d<=64 and 0<=poly<1<<d
    f=(1<<d)|poly;factors,irreducibles=primary(f)
    assert factors==secondary(f)
    if d<=5:assert factors==small_trial(f)
    reconstruction=1
    for i,row in enumerate(factors):
        assert row['factor']>1 and gcd(row['factor'],derivative(row['factor']))==1
        assert all(gcd(row['factor'],x['factor'])==1 for x in factors[:i])
        reconstruction=multiply(reconstruction,power(row['factor'],row['multiplicity']))
    assert reconstruction==f and sum(x['degree']*x['multiplicity'] for x in factors)==d
    assert len({x['multiplicity'] for x in factors})==len(factors)
    return dict(poly=poly,tag=tag,factors=factors,irreducibles=irreducibles,
                reconstruction=reconstruction,degree_sum=d)
