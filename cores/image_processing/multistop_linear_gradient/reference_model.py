"""SPDX-License-Identifier: Apache-2.0. Independent exact-rational oracle.

Executed only as an archived preparation child after root and peer review.
Uses Fraction geometry rather than cached thresholds or RTL scheduling.
"""
import argparse
from fractions import Fraction
import hashlib
import json
import os
from pathlib import Path
import random


def rne(value):
    q, r = divmod(value.numerator, value.denominator)
    return q + (2*r > value.denominator or (2*r == value.denominator and q % 2))


def channels(rgba):
    return [(rgba >> shift) & 255 for shift in (24, 16, 8, 0)]


def pack(values):
    return sum(v << shift for v, shift in zip(values, (24, 16, 8, 0)))


def paint(origin, end, point, stops, spread):
    dx, dy = end[0]-origin[0], end[1]-origin[1]
    norm = dx*dx + dy*dy
    if not norm:
        return stops[-1][1], 1
    t = Fraction((point[0]-origin[0])*dx+(point[1]-origin[1])*dy, norm)
    if spread == 0:
        t = max(Fraction(0), min(Fraction(1), t))
    elif spread == 1:
        t -= t // 1
    else:
        t %= 2
        if t > 1:
            t = 2-t
    left = None
    for offset, color in stops:
        position = Fraction(offset, 65536)
        if t >= position:
            left = position, color
        else:
            if left is None:
                return color, 0
            weight = (t-left[0])/(position-left[0])
            return pack([rne((1-weight)*a+weight*b)
                         for a, b in zip(channels(left[1]), channels(color))]), 0
    return left[1], 0


def compose(source, destination, mode):
    s, d = channels(source), channels(destination)
    if mode > 12:
        return 0, 1
    if max(d[:3]) > d[3]:
        return 0, 3
    a, b = [(0,0),(255,0),(0,255),(255,255-s[3]),(255-d[3],255),
            (d[3],0),(0,s[3]),(255-d[3],0),(0,255-s[3]),
            (d[3],255-s[3]),(255-d[3],s[3]),(255-d[3],255-s[3]),(255,255)][mode]
    return pack([min(255,(x*a+y*b+127)//255) for x,y in zip(s,d)]), 0


def make_stops(maximum, shape):
    colors = [0x00000001,0x01010101,0x60402080,0x00201040,
              0x00000000,0xff2010ff,0x201080c0]
    if maximum == 1:
        return [(32768,colors[(shape+2) % len(colors)])]
    if shape == 0:
        return [(0,0x00000003),(65536,0x01030203)]
    offsets = ([8192,32768,32768,49152,65536] if shape == 1 else
               [0,1,257,8192,16384,32767,32768,32768,32768,40000,49152,60000,65534,65535,65536,65536]
               if shape == 2 else [0,1,65535,65536] if shape == 3 else [32768]*maximum)
    if shape == 2 and maximum < 16:
        offsets = [0,32768,32768,65535,65536]
    offsets = offsets[:maximum]
    return [(offset, colors[(i+shape) % len(colors)]) for i,offset in enumerate(offsets)]


def make_cases(maximum, tag_width, example):
    geometry = [((0,0),(256,0)),((0,256),(0,-256)),
                ((-131072,131071),(131071,-131072)),((-4,7),(-3,7)),((123,-450),(123,-450))]
    result = []
    for shape,(origin,end) in enumerate(geometry):
        for spread in range(3):
            case_id = len(result)
            stops = make_stops(maximum,shape)
            points = [origin,end,(0,0),(128,0),(384,0),(-128,0),(-256,0),(512,0),
                      (131071,131071),(-131072,-131072),(-131072,131071),(131071,-131072),
                      (-5,7),(-4,7),(-3,7),(-2,7),(0,128),(0,-128),(1,1),(-1,-1)]
            rng = random.Random(0x491000+case_id)
            points += [(rng.randrange(-131072,131072),rng.randrange(-131072,131072)) for _ in range(20)]
            if case_id == 0:
                points += [(x*256+128,y*256+128) for y in range(5) for x in range(7)]
            queries = []
            for index,point in enumerate(points):
                alpha = rng.randrange(256)
                destination = pack([rng.randrange(alpha+1) for _ in range(3)]+[alpha])
                if index % 11 == 5:
                    destination = 0xff000000
                mode = index % 16
                color,degenerate = paint(origin,end,point,stops,spread)
                expected,error = compose(color,destination,mode) if example else (color,0)
                queries.append(dict(point=point,destination=destination,mode=mode,
                    x=(index*257+case_id)&65535,y=(65535-index*251)&65535,
                    tag=(index*65537+case_id)&((1<<tag_width)-1),
                    expected=expected,error=error,degenerate=degenerate))
            result.append(dict(origin=origin,end=end,spread=spread,stops=stops,queries=queries))
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--profile',required=True)
    parser.add_argument('--max-stops',required=True,type=int)
    parser.add_argument('--tag-w',required=True,type=int)
    parser.add_argument('--example',required=True,type=int,choices=(0,1))
    parser.add_argument('--out',required=True,type=Path)
    args = parser.parse_args()
    cases = make_cases(args.max_stops,args.tag_w,args.example)
    lines = [str(len(cases))]
    outputs = 0
    for case in cases:
        lines.append(' '.join(map(str,[len(case['stops']),case['spread'],*case['origin'],*case['end'],len(case['queries'])])))
        lines += [f'{offset} {color:08x}' for offset,color in case['stops']]
        for q in case['queries']:
            lines.append(f"{q['point'][0]} {q['point'][1]} {q['destination']:08x} {q['mode']} {q['x']} {q['y']} {q['tag']:08x} {q['expected']:08x} {q['error']} {q['degenerate']}")
        outputs += len(case['queries'])
    counters = dict(cases=len(cases),main_outputs=outputs,main_holds=outputs*4,
                    live_resets=8,recovery_outputs=8,future_results=2,management_results=1)
    args.out.mkdir(parents=True,exist_ok=False)
    vector = ('\n'.join(lines)+'\n').encode('ascii')
    with (args.out/'vectors.txt').open('xb') as stream:
        stream.write(vector);stream.flush();os.fsync(stream.fileno())
    receipt = dict(profile=args.profile,oracle_definition_loads=1,numerical_preparations=1,
                   expected_counters=counters,files={'vectors.txt':dict(sha256=hashlib.sha256(vector).hexdigest(),bytes=len(vector),rows=len(lines))})
    with (args.out/'preparation.json').open('x',encoding='utf-8',newline='\n') as stream:
        json.dump(receipt,stream,indent=2);stream.write('\n');stream.flush();os.fsync(stream.fileno())
    print('GRADIENT_PREP_PASS '+' '.join(f'{key}={value}' for key,value in counters.items()))


if __name__ == '__main__':
    main()
