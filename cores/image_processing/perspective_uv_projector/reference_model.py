"""SPDX-License-Identifier: Apache-2.0.

Independent unbounded-integer oracle and finite deterministic vector preparation.
No project import; execute only after independent root source review and gate.
"""
import argparse
import hashlib
import json
from pathlib import Path


def area(vertices):
    a, b, c = vertices
    return (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])


def edge(a, b, x, y):
    return (b[0]-a[0])*(2*y+1-2*a[1])-(b[1]-a[1])*(2*x+1-2*a[0])


def rne(numerator, denominator):
    quotient, remainder = divmod(numerator, denominator)
    return quotient + (2*remainder > denominator or
                       (2*remainder == denominator and quotient % 2 == 1))


def project(vertices, x, y):
    determinant = area(vertices)
    assert determinant and all(vertex[4] > 0 for vertex in vertices)
    weights = [edge(vertices[(i+1) % 3], vertices[(i+2) % 3], x, y)
               * (1 if determinant > 0 else -1) for i in range(3)]
    if min(weights) < 0:
        return 0, 0, 0
    denominator = sum(weights[i]*vertices[i][4] for i in range(3))
    assert denominator > 0
    uv = [rne(sum(weights[i]*vertices[i][4]*vertices[i][channel]
                  for i in range(3)), denominator) for channel in (2, 3)]
    assert all(0 <= component <= 255 for component in uv)
    return *uv, 1


def status(vertices):
    if any(vertex[4] == 0 for vertex in vertices):
        return 2
    return 1 if area(vertices) == 0 else 0


def index_at(x, y):
    return (3*x + 5*y) % 256


def rgba_at(index):
    alpha = 0 if index % 7 == 0 else (index*11+1) % 255+1
    return (alpha << 24) | ((index*17+9) % 256 << 16) | ((index*29+3) % 256 << 8) | ((index*43+5) % 256)


def tag_at(value, width):
    raw = (0xa55a3cc3 ^ (value*0x10203)) & ((1 << width)-1)
    # Decimal signed-32 file fields preserve the complete 32-bit tag pattern.
    return raw-(1 << 32) if width == 32 and raw >= (1 << 31) else raw


def render(vertices, width, height, tw, th):
    code = status(vertices)
    if code:
        return (1 if code == 1 else 3), []
    a, b, c = vertices
    oriented = [a, b, c] if area(vertices) > 0 else [a, c, b]
    low_x = max(0, min(vertex[0] for vertex in vertices))
    low_y = max(0, min(vertex[1] for vertex in vertices))
    high_x = min(width, max(vertex[0] for vertex in vertices))
    high_y = min(height, max(vertex[1] for vertex in vertices))
    # The original raster labels bounding-box rejection only, not zero coverage.
    if high_x <= 0 or high_y <= 0 or low_x >= width or low_y >= height:
        return 2, []
    fragments = []
    for y in range(low_y, high_y):
        for x in range(low_x, high_x):
            inside = True
            for i in range(3):
                start, end = oriented[(i+1) % 3], oriented[(i+2) % 3]
                value = edge(start, end, x, y)
                inclusive = end[1] < start[1] or (end[1] == start[1] and end[0] > start[0])
                inside &= value > 0 or (value == 0 and inclusive)
            if inside:
                u, v, covered = project(vertices, x, y)
                assert covered
                if u >= tw or v >= th:
                    rgb, alpha, visible, reason = 0, 0, 0, 1
                else:
                    rgba = rgba_at(index_at(u, v))
                    rgb, alpha = rgba & 0xffffff, rgba >> 24
                    visible, reason = int(alpha != 0), (0 if alpha else 2)
                fragments.append((x, y, rgb, alpha, visible, reason, int(not fragments)))
    return 0, fragments


def core_cases(qmax):
    # Every good configuration receives all queries, including edge and outside.
    qmid = max(1, qmax//3)
    cases = [
        [(0,0,0,255,1),(8,0,255,0,qmax),(0,8,64,192,qmid)],
        [(0,0,0,255,1),(0,8,64,192,qmid),(8,0,255,0,qmax)],
        [(-512,-512,255,0,qmax),(511,-512,0,255,1),(-512,511,127,128,qmax)],
        [(-512,-512,0,255,1),(511,511,255,0,qmax),(-512,511,255,255,qmid)],
        [(0,0,0,1,1),(2,0,2,3,1),(0,2,0,1,1)],
        [(0,0,1,2,1),(2,0,3,4,1),(0,2,1,2,1)],
        [(-1,0,255,255,qmax),(1,0,255,255,qmax),(0,2,255,255,qmax)],
        [(0,0,0,0,1),(0,0,255,255,qmax),(0,0,127,127,1)],
        [(0,0,0,0,0),(8,0,255,0,1),(0,8,0,255,1)],
        [(0,0,0,0,0),(0,0,0,0,1),(0,0,0,0,1)],
        [(255,255,0,255,1),(511,255,255,0,qmax),(255,511,255,255,qmid)],
        [(-4,-4,255,255,qmax),(12,-4,0,0,1),(-4,12,255,0,qmax)]
    ]
    queries = [(0,0),(1,0),(0,1),(1,1),(2,2),(3,3),(4,3),(3,4),
               (7,0),(0,7),(7,7),(8,8),(255,255),(254,255),(255,254),(127,128)]
    return cases, queries


def wrapper_cases(width, height, tw, th, qmax):
    # Sparse corner probes retain maximum dimensions without a full-frame run.
    w, h = min(width, 6), min(height, 6)
    return [
        [(0,0,0,0,1),(w,0,tw-1,0,qmax),(0,h,0,th-1,1)],
        [(0,0,0,0,1),(0,h,0,th-1,1),(w,0,tw-1,0,qmax)],
        [(-2,-2,0,0,qmax),(w,0,255,0,1),(0,h,0,255,qmax)],
        [(0,0,0,0,1),(w,0,0,0,1),(w,h,0,0,1)],
        [(0,0,0,0,1),(w,h,0,0,1),(0,h,0,0,1)],
        [(width-3,height-3,tw-1,th-1,qmax),(width,height-3,0,0,1),(width-3,height,tw-1,0,1)],
        [(-512,-512,0,0,1),(-510,-512,255,0,qmax),(-512,-510,0,255,1)],
        [(0,0,0,0,1),(1,1,1,1,qmax),(2,2,2,2,1)],
        [(0,0,0,0,0),(w,0,1,0,1),(0,h,0,1,1)]
    ]


def main():
    parser = argparse.ArgumentParser()
    for name in ('q', 'tag', 'wrap', 'width', 'height', 'tw', 'th'):
        parser.add_argument('--'+name, type=int, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    assert 1 <= args.q <= 16 and 1 <= args.tag <= 32 and args.wrap in (0,1)
    assert all(1 <= value <= 256 for value in (args.width,args.height,args.tw,args.th))
    args.output.mkdir(parents=True, exist_ok=False)
    qmax = (1 << args.q)-1
    configs, results, pixels = [], [], []
    if not args.wrap:
        cases, queries = core_cases(qmax)
        for ci, vertices in enumerate(cases):
            code = status(vertices)
            configs.append([value for vertex in vertices for value in vertex] + [tag_at(ci,args.tag),code,0 if code else len(queries)])
            if code == 0:
                for qi,(x,y) in enumerate(queries):
                    results.append((x,y,tag_at(qi+ci*7,args.tag),qi % 2,*project(vertices,x,y)))
        expected = dict(configs=len(configs),outputs=len(results),config_faults=3,resets=9)
    else:
        for ci,vertices in enumerate(wrapper_cases(args.width,args.height,args.tw,args.th,qmax)):
            code, fragments = render(vertices,args.width,args.height,args.tw,args.th)
            configs.append([value for vertex in vertices for value in vertex]+[tag_at(ci,args.tag),code,len(fragments)])
            pixels.extend((*fragment,tag_at(ci,args.tag)) for fragment in fragments)
        expected = dict(configs=len(configs),outputs=len(pixels),config_faults=2,resets=7)
    files = {'config.txt': configs, 'query.txt': results, 'pixel.txt': pixels}
    metadata = {}
    for name,rows in files.items():
        raw = (str(len(rows))+'\n'+''.join(' '.join(map(str,row))+'\n' for row in rows)).encode('ascii')
        (args.output/name).write_bytes(raw)
        metadata[name] = dict(sha256=hashlib.sha256(raw).hexdigest(),bytes=len(raw))
    receipt = dict(schema='anscore-b45-c-preparation-v1',parameters=vars(args) | {'output':str(args.output)},
                   expected_counters=expected,files=metadata,oracle_definition_loads=1,numerical_preparations=1)
    (args.output/'preparation.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
    print('B45_C_PREP_PASS '+' '.join(f'{key}={value}' for key,value in expected.items()))


if __name__ == '__main__':
    main()
