"""Original exact set-based reference. Import has no execution or file writes."""
from __future__ import annotations
import argparse
from fractions import Fraction
import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def ordered_edges(pixels: list[int], width: int, height: int) -> list[tuple[int,int,int,int]]:
    """Tuple is (weight, source, direction, target); no diagonal/wrap edges."""
    edges = []
    for y in range(height):
        for x in range(width):
            a = y*width+x
            if x+1 < width:
                edges.append((abs(pixels[a]-pixels[a+1]),a,0,a+1))
            if y+1 < height:
                edges.append((abs(pixels[a]-pixels[a+width]),a,1,a+width))
    return sorted(edges)


def segment(pixels: list[int], width: int, height: int, k: int, minimum: int) -> dict:
    n = width*height
    assert 1 <= width <= 64 and 1 <= height <= 64
    assert len(pixels) == n and all(0 <= p <= 255 for p in pixels)
    assert 0 <= k <= 65535 and 1 <= minimum <= n
    # Membership is materialized explicitly; no parent forest/rank walk is used.
    owner = list(range(n))
    sets = {i:{i} for i in range(n)}
    internal = {i:0 for i in range(n)}
    edges = ordered_edges(pixels,width,height)

    def join(a: int, b: int, weight: int) -> None:
        if len(sets[a]) < len(sets[b]):
            a,b = b,a
        for pixel in sets[b]:
            owner[pixel] = a
        sets[a].update(sets.pop(b))
        internal[a] = max(internal[a],internal.pop(b),weight)

    merges = []
    for weight,u,direction,v in edges:
        a,b = owner[u],owner[v]
        if a != b:
            # Rational definition, not the RTL's product implementation.
            ta = internal[a]+Fraction(k,len(sets[a]))
            tb = internal[b]+Fraction(k,len(sets[b]))
            if weight <= min(ta,tb):
                merges.append([0,weight,u,direction,v])
                join(a,b,weight)
    if minimum > 1:
        for weight,u,direction,v in edges:
            a,b = owner[u],owner[v]
            if a != b and (len(sets[a]) < minimum or len(sets[b]) < minimum):
                merges.append([1,weight,u,direction,v])
                join(a,b,weight)
    label = {a:min(s) for a,s in sets.items()}
    return dict(labels=[label[owner[i]] for i in range(n)],
                areas=[len(sets[owner[i]]) for i in range(n)],regions=len(sets),
                edges=len(edges),merges=merges)


def records(pixels: list[int], markers: list[list[int]], width: int, height: int,
            k: int, minimum: int, tag: int) -> tuple[list[list[int]],int]:
    n = width*height
    errors = 8 if not 1 <= minimum <= n else 0
    for i,(sof,eol,last) in enumerate(markers):
        errors |= (int(sof != int(i==0)) | (int(eol != int(i%width==width-1))<<1)
                   | (int(last != int(i==n-1))<<2))
    # Record order: index,label,area,regions,keep,sof,eol,last,errors,tag.
    if errors:
        return [[0,0,0,0,0,1,0,1,errors,tag]],errors
    result = segment(pixels,width,height,k,minimum)
    out = [[i,result['labels'][i],result['areas'][i],result['regions'],1,
            int(i==0),int(i%width==width-1),int(i==n-1),0,tag] for i in range(n)]
    return out,0


def certificates() -> list[dict]:
    literals = [
        dict(name='singleton',width=1,height=1,pixels=[17],k=0,minimum=1,
             labels=[0],areas=[1],regions=1),
        dict(name='four_connectivity',width=2,height=2,pixels=[0,255,255,0],k=0,minimum=1,
             labels=[0,1,2,3],areas=[1,1,1,1],regions=4),
        dict(name='adaptive_boundary',width=3,height=1,pixels=[0,1,4],k=1,minimum=1,
             labels=[0,0,2],areas=[2,2,1],regions=2),
        dict(name='minimum_cleanup',width=3,height=1,pixels=[0,1,4],k=1,minimum=2,
             labels=[0,0,0],areas=[3,3,3],regions=1),
        dict(name='stable_tie_cleanup',width=5,height=1,pixels=[0,0,5,10,10],k=0,minimum=2,
             labels=[0,0,0,3,3],areas=[3,3,3,2,2],regions=2),
        dict(name='flat',width=2,height=2,pixels=[9,9,9,9],k=0,minimum=1,
             labels=[0,0,0,0],areas=[4,4,4,4],regions=1)
    ]
    for case in literals:
        actual = segment(case['pixels'],case['width'],case['height'],case['k'],case['minimum'])
        for key in ('labels','areas','regions'):
            assert actual[key] == case[key],(case['name'],key,actual[key],case[key])
    # Full-precision product witness: a 16-bit intermediate would wrap to61440.
    assert 255*4096 == 1044480 and 1044480 > 65535
    assert not (255 <= Fraction(65535,4096))
    literals.append(dict(name='wide_product',weight=255,internal=0,size=4096,k=65535,
                         product=1044480,accept=False))
    assert not (3 <= 2+Fraction(1,2)) and 3 <= 2+Fraction(2,2)
    literals.append(dict(name='fraction_boundary',weight=3,internal=2,size=2,
                         k1_accept=False,k2_accept=True))
    return literals


def verify_stored() -> int:
    seal = json.loads((ROOT/'SOURCE_SEAL.json').read_text(encoding='utf-8'))
    for rel,digest in seal['fixtures'].items():
        assert hashlib.sha256((ROOT/rel).read_bytes()).hexdigest() == digest,rel
    assert json.loads((ROOT/'BOUNDARY_CERTIFICATES.json').read_text()) == certificates()
    count = 0
    table = json.loads((ROOT/'CASE_TABLE.json').read_text())
    for profile in table['profiles']:
        folder = ROOT/'fixtures'/profile['name']
        for filename in ('expected.json','reset_old.json','reset_fresh.json'):
            cases = json.loads((folder/filename).read_text())
            for case in cases:
                actual,error = records(case['pixels'],case['markers'],profile['width'],profile['height'],
                                       case['k'],case['minimum'],case['tag'])
                assert actual == case['records'] and error == case['errors'],case['id']
                count += 1
    print(f'PASS ORACLE stored_frames={count} certificates=8')
    return 0


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--verify-stored',action='store_true',required=True)
    parser.parse_args()
    raise SystemExit(verify_stored())
