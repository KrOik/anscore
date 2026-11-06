"""SPDX-License-Identifier: Apache-2.0. Whole-record rational reference; no RTL recurrences."""
from fractions import Fraction
import random


def rne(value):
    q, r = divmod(value.numerator, value.denominator)
    return q + (2*r > value.denominator or (2*r == value.denominator and q % 2))


def measure(values, baseline, negative, fraction, floor):
    y = [(-1 if negative else 1)*(v-baseline) for v in values]
    peak = max(0, max(y))
    p = y.index(peak) if peak else 0
    if peak < floor:
        return 5, peak, p, 0, 0, 0, 0
    threshold = Fraction(peak*fraction, 256)
    left_candidates = [j for j in range(p) if y[j] <= threshold]
    right_candidates = [j for j in range(p+1, len(y)) if y[j] <= threshold]
    left = right = 0
    if left_candidates:
        j = max(left_candidates)
        left = rne((j + (threshold-y[j])/(y[j+1]-y[j]))*65536)
    if right_candidates:
        j = min(right_candidates)
        right = rne((j-1 + (y[j-1]-threshold)/(y[j-1]-y[j]))*65536)
    sides = bool(left_candidates) + 2*bool(right_candidates)
    return (0 if sides == 3 else 6), peak, p, sides, left, right, right-left if sides == 3 else 0


def prepare(profile):
    d, cap, tag_w, example = (profile[k] for k in ('data_w','max_samples','tag_w','example'))
    lo, hi = -(1 << (d-1)), (1 << (d-1))-1
    rows = []
    counts = dict(commands=0, samples=0, records=0)
    def emit(*values):
        rows.append(' '.join(format(v & ((1 << 64)-1), 'x') for v in (*values, *([0]*(16-len(values))))))
    def command(n, f, b, neg, floor, tag):
        emit(1,n,f,b,neg,floor,tag);counts['commands'] += 1
    def expected(result, tag, hold=3):
        emit(3,*result,tag,hold);counts['records'] += 1
    def frame(values, b=0, neg=0, f=128, floor=1, tag=1, gap=False, trigger_at=64):
        if example:
            values = (values + [b]*(trigger_at+192))[:trigger_at+192]
        command(len(values),f,b,neg,floor,tag)
        for j,v in enumerate(values):
            emit(2,v,(j==trigger_at) if example else (j==len(values)-1),0 if gap or j==0 else 1)
            counts['samples'] += 1
            if gap and j%3==0:emit(4,2)
        expected(measure(values[max(0,trigger_at-64):] if example else values,b,neg,f,floor),tag)
    pulses = [
        ([0,2,8,2,0],0,0,128,1),
        ([0,2,8,8,2,0],0,0,128,1),
        ([0,4,4,8,8,4,4,0],0,0,128,1),
        ([0,8,0,8,0],0,0,128,1),
        ([8,4,0],0,0,128,1),([0,4,8],0,0,128,1),
        ([8,8,8],0,0,1,1),([0,0,0],0,0,255,1),
        ([-3,-2,-1],0,0,128,1),
        ([0,-4,-16,-4,0],0,1,128,1),
        ([lo,hi,lo],lo,0,255,1),([hi,lo,hi],hi,1,1,1),
        ([lo,hi,lo],0,0,1,1),([lo,hi,lo],0,0,255,1),
        ([0,1,2,1,0],0,0,128,2),([0,1,2,1,0],0,0,128,3),
        ([0,3,9,3,0],0,0,85,1),([0,3,9,3,0],0,0,171,1),
        ([0,1,3,1,0],0,0,128,1),
    ]
    for i,(v,b,neg,f,floor) in enumerate(pulses):
        if len(v)<=cap or example:frame(v,b,neg,f,floor,(i+1)&((1<<tag_w)-1),i%3==0)
    rng = random.Random(4000+d+cap)
    for k in range(10):
        n = min(cap, 17+k)
        b = rng.randint(lo,hi)
        v = [rng.randint(lo,hi) for _ in range(n)]
        frame(v,b,k%2,rng.randint(1,255),rng.randint(1,hi),k&((1<<tag_w)-1))
    # Sub-LSB tie cases: amplitude256 or512, f1, neighboring slope256.
    if d>=12:
        frame([0,512,513,0],0,0,1,1,3)
        frame([0,512,515,0],0,0,1,1,4)
    if example:
        frame([0,4,16,4,0],tag=6,trigger_at=0)
        frame([0,4,16,4,0],tag=7,trigger_at=3)
        frame([0]*70+[0,4,16,4,0],tag=8,trigger_at=80)
    if profile['full_capacity']:
        v = [hi]*cap;v[0] = v[-1] = 0
        frame(v,0,0,128,1,5)
    for f,floor,status in ((0,1,2),(256,1,2),(0x80000001,1,2),(128,0,3)):
        command(256 if example else 3,f,0,0,floor,1);expected((status,0,0,0,0,0,0),1)
    if not example:
        for n in (0,2,cap+1,0x80000003):
            command(n,0,0,0,0,1);expected((1,0,0,0,0,0,0),1)
        for n,early in ((3,True),(3,False)):
            command(n,128,0,0,1,1)
            count = 1 if early else n
            for j in range(count):
                emit(2,1,1 if early else 0,0 if j==0 else 1);counts['samples'] += 1
            expected((4,0,0,0,0,0,0),1)
    return '\n'.join(rows)+'\n', counts
