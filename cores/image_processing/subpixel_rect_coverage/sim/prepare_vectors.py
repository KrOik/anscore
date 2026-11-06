"""SPDX-License-Identifier: Apache-2.0.
Standalone, finite independent cell-histogram oracle; no project imports.
Only execute as an archived preparation child under the approved sealed plan.
"""
import argparse
import hashlib
import json
from pathlib import Path

PROFILES = {
    'core_1': (1, 1, 1, False, 24, 13, 4),
    'core_7': (7, 5, 8, False, 24, 75, 4),
    'core_256': (256, 256, 32, False, 24, 65825, 4),
    'blend_7': (7, 5, 8, True, 44, 93, 8),
    'blend_256': (256, 256, 32, True, 44, 311, 8),
}
PAINTS = (0x00000000, 0x01030507, 0xff0000ff, 0x406080c0)
DESTS = (0x00000000, 0x11223344, 0x0000ffff, 0x80808080)


def geometry(width, height, blend):
    xmax, ymax = width * 256, height * 256
    result = [
        (0, 0, 0, 256), (256, 0, 0, 256), (0, 256, 256, 0),
        (256, 0, 0, 0), (-512, 0, -1, 256), (xmax, 0, xmax+256, 256),
        (0, -512, 256, -1), (0, ymax, 256, ymax+256),
        (-8388608, -8388608, 512 if blend and width==256 else 8388607,
         512 if blend and height==256 else 8388607),
        (1, 2, 2, 3), (0, 0, 256, 256), (13, 29, 213, 229),
        (0, 0, 128, 256), (255, 0, 257, min(ymax, 768)),
        (0, 255, min(xmax, 768), 257), (-129, -65, 384, 384),
        (xmax-1, ymax-1, xmax+1, ymax+1), (-128, -64, 128, 192),
        (256, 0, 512, 256), (128, 128, min(xmax, 640), min(ymax, 640)),
        (-999, 0, 999, 0), (-10, -10, -10, -10), (0, 0, xmax, 1),
        (-8388608, 0, 1, 1),
    ]
    if blend:
        result += [(64, 32, 192, 224)] * 13
        result += [(0, 0, 256, 256), (0, 0, 256, 256), (1, 2, 2, 3),
                   (0, 0, 256, 256), (0, 0, 0, 256), (256, 0, 0, 256),
                   (0, 0, 256, 256)]
    return result


def histogram(lo, hi, pixels):
    # Enumerate viewport subcells, never multiply an overlap of clipped edges.
    bins = [0] * pixels
    for subcell in range(pixels * 256):
        if lo <= subcell < hi:
            bins[subcell // 256] += 1
    return bins


def rgba_bytes(value):
    return [(value >> shift) & 255 for shift in (24, 16, 8, 0)]


def pack(channels):
    result = 0
    for value in channels:
        result = result * 256 + value
    return result


def nearest_even(numerator, denominator):
    quotient, remainder = divmod(numerator, denominator)
    return quotient + (2*remainder > denominator or
                       (2*remainder == denominator and quotient % 2 == 1))


def composite(paint, destination, area, mode):
    source, dest = rgba_bytes(paint), rgba_bytes(destination)
    if mode > 12:
        return 0, 1
    if any(value > source[3] for value in source[:3]):
        return 0, 2
    if any(value > dest[3] for value in dest[:3]):
        return 0, 3
    scaled = [nearest_even(value*area, 65536) for value in source]
    sa, da = scaled[3], dest[3]
    # Original mathematical Porter-Duff factor table; no RTL model imported.
    factors = [(0,0), (255,0), (0,255), (255,255-sa), (255-da,255),
               (da,0), (0,sa), (255-da,0), (0,255-sa), (da,255-sa),
               (255-da,sa), (255-da,255-sa), (255,255)]
    fs, fd = factors[mode]
    return pack([min(255, nearest_even(s*fs+d*fd, 255))
                 for s,d in zip(scaled,dest)]), 0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--profile', choices=PROFILES, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    width,height,tag_w,blend,ncases,nfrags,nresets = PROFILES[args.profile]
    args.output.mkdir(parents=True, exist_ok=False)
    rows, observed_fragments = [], 0
    rectangles = geometry(width,height,blend)
    assert len(rectangles)==ncases
    for index,(x0,y0,x1,y1) in enumerate(rectangles):
        tag = (0xa5830f19 + index*0x1020307) & ((1<<tag_w)-1)
        paint,mode = PAINTS[index % len(PAINTS)], index % 13
        if blend and 24<=index<=36:
            mode=index-24
        if index==12:
            paint=0x01030507  # half coverage exercises even and odd ties
        if blend and index>=37:
            mode = {37:13,38:15,39:3,40:3,41:13,42:3,43:3}[index]
            paint = 0x01000000 if index in (38,39,41,42,43) else 0x11223344
        status = 1 if x1<x0 or y1<y0 else 0
        fragments=[]
        if status==0:
            xs,ys=histogram(x0,x1,width),histogram(y0,y1,height)
            for y,ny in enumerate(ys):
                if not ny: continue
                for x,nx in enumerate(xs):
                    if not nx: continue
                    area=nx*ny
                    destination=DESTS[(index+x+3*y)%len(DESTS)]
                    if blend and index in (38,40,43): destination=0x01000000
                    rgba,error=composite(paint,destination,area,mode) if blend else (0,0)
                    fragments.append((x,y,area,destination,rgba,error))
            if not fragments: status=2
        total=sum(item[2] for item in fragments)
        # Separately check the histogram's conservation against the interval length.
        if status!=1:
            cw=max(0,min(x1,width*256)-max(x0,0))
            ch=max(0,min(y1,height*256)-max(y0,0))
            assert total==cw*ch
        error_count=sum(item[5]!=0 for item in fragments)
        rows.append(f'C {x0} {y0} {x1} {y1} {tag:08x} {paint:08x} {mode} {status} {len(fragments)} {total} {error_count}')
        for pixel,item in enumerate(fragments):
            x,y,area,destination,rgba,error=item
            rows.append(f'P {x} {y} {area} {destination:08x} {rgba:08x} {error} {int(pixel==len(fragments)-1)}')
        observed_fragments+=len(fragments)
    assert observed_fragments==nfrags
    payload=(f'{len(rows)} {ncases} {nfrags}\n'+'\n'.join(rows)+'\n').encode('ascii')
    vector=args.output/'vectors.txt'
    with vector.open('xb') as stream: stream.write(payload)
    counters=dict(cases=ncases,fragments=nfrags,reset_checks=nresets,queued_commands=2)
    receipt=dict(profile=args.profile,width=width,height=height,tag_w=tag_w,blend=blend,
        cases=ncases,oracle_definition_loads=1,numerical_preparations=1,
        expected_counters=counters,files={'vectors.txt':dict(rows=len(rows),bytes=len(payload),
        sha256=hashlib.sha256(payload).hexdigest())})
    with (args.output/'preparation.json').open('x',encoding='utf-8',newline='\n') as stream:
        json.dump(receipt,stream,indent=2);stream.write('\n')
    print('B47_PREP '+' '.join(f'{key}={value}' for key,value in counters.items()))


if __name__=='__main__': main()
