"""Bounded owner-only preparation and 20-second HDL receipts; no synthesis."""
import argparse
import hashlib
import itertools
import json
import os
from pathlib import Path
import random
import shutil
import subprocess
import tempfile
import time
from fractions import Fraction

ROOT = Path(__file__).resolve().parent
BASELINE = '897cf84f5861f5fada3c1a5d64127e64cdb9af92'
PROFILES = [(2, 1, 1), (2, 3, 3), (4, 4, 8), (8, 8, 8), (12, 8, 32)]
REJECTS = [('w1', 1, 8, 8), ('w13', 13, 8, 8), ('m0', 8, 0, 8),
           ('m9', 8, 9, 8), ('t0', 8, 8, 0), ('t33', 8, 8, 33)]


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def hull(points):
    """Independent monotone convex boundary, removing interior collinear points."""
    points = sorted(set(points))
    if len(points) < 2:
        return points
    def turn(a, b, c):
        return (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])
    chains = []
    for order in (points, list(reversed(points))):
        chain = []
        for p in order:
            while len(chain) > 1 and turn(chain[-2], chain[-1], p) <= 0:
                chain.pop()
            chain.append(p)
        chains.append(chain[:-1])
    return chains[0] + chains[1]


def gaussian(matrix, rhs):
    """General exact 2x2 elimination, used to verify reconstructed corners."""
    a = [[Fraction(v) for v in row]+[Fraction(value)] for row, value in zip(matrix, rhs)]
    for c in range(2):
        pivot = next(r for r in range(c, 2) if a[r][c])
        a[c], a[pivot] = a[pivot], a[c]
        scale = a[c][c]
        a[c] = [v/scale for v in a[c]]
        for r in range(2):
            if r != c:
                scale = a[r][c]
                a[r] = [v-scale*q for v, q in zip(a[r], a[c])]
    return a[0][2], a[1][2]


def projection_box(points, direction):
    dx, dy = direction
    us = [x*dx+y*dy for x, y in points]
    vs = [y*dx-x*dy for x, y in points]
    bounds = (min(us), max(us), min(vs), max(vs))
    den = dx*dx+dy*dy
    area_num = (bounds[1]-bounds[0])*(bounds[3]-bounds[2])
    return bounds, den, area_num, (us.index(bounds[0]), us.index(bounds[1]),
                                   vs.index(bounds[2]), vs.index(bounds[3]))


def oracle(points):
    boundary = hull(points)
    if len(boundary) == 1:
        x, y = boundary[0]
        return (1, 0, x, x, y, y, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    # Primary minimization sees only convex-hull edges, not all source pairs.
    minimum = None
    for a, b in zip(boundary, boundary[1:]+boundary[:1]):
        direction = (b[0]-a[0], b[1]-a[1])
        bounds, den, num, _ = projection_box(boundary, direction)
        area = Fraction(num, den)
        minimum = area if minimum is None else min(minimum, area)
    # A separate representation pass implements the public first-input-pair tie.
    for i, j in itertools.combinations(range(len(points)), 2):
        dx, dy = points[j][0]-points[i][0], points[j][1]-points[i][1]
        if dx == dy == 0:
            continue
        if dx < 0 or (dx == 0 and dy < 0):
            dx, dy = -dx, -dy
        bounds, den, num, indices = projection_box(points, (dx, dy))
        if Fraction(num, den) != minimum:
            continue
        corners = [gaussian([[dx, dy], [-dy, dx]], [u, v])
                   for u, v in itertools.product(bounds[:2], bounds[2:])]
        assert all(Fraction(u*dx-v*dy, den) == x and Fraction(u*dy+v*dx, den) == y
                   for (u, v), (x, y) in zip(itertools.product(bounds[:2], bounds[2:]), corners))
        center = tuple(sum(c[k] for c in corners)/4 for k in range(2))
        assert center == (Fraction((bounds[0]+bounds[1])*dx-(bounds[2]+bounds[3])*dy, 2*den),
                          Fraction((bounds[0]+bounds[1])*dy+(bounds[2]+bounds[3])*dx, 2*den))
        return (dx, dy, *bounds, den, num, 1, i, j, *indices, 2 if num else 1)
    raise AssertionError('hull edge completeness')


def work(points, mw):
    products = 0
    reads = 1
    pairs = 0
    latency = 2
    first = True
    for a, b in itertools.combinations(points, 2):
        pairs += 1
        reads += 2
        if a == b:
            latency += 5
            continue
        nprod = 4*len(points)+3+(0 if first else 2)
        first = False
        products += nprod
        reads += len(points)
        latency += 6+2*len(points)+nprod*(mw+2)
    return products, reads, pairs, latency


def pack(values):
    out = 0
    for v, width in values:
        out = (out << width) | (v & ((1 << width)-1))
    return out


def transactions(w, m, t):
    low, high = -(1 << (w-1)), (1 << (w-1))-1
    shapes = [[], [(low, high)], [(0, 0)]*m, [(low, low), (high, high)],
              [(low, high), (high, low)], [(low, low), (high, low), (low, high)],
              [(low, low), (high, low), (high, high), (low, high)],
              [(0, 0), (1, 1), (-1, 1), (1, -1)],
              [(-1, -1), (1, -1), (0, 1)], [(1, -1), (-1, -1), (0, 1)],
              [(0, 0), (1, 0), (1, 1), (0, 1)],
              [(high, low), (high, low), (low, high), (0, 0)],
              [(x, x) for x in [low, high, 0, -1]],
              [(0, low), (0, high), (0, -1), (0, 0)],
              [(low, 0), (high, 0), (-1, 0), (0, 0)]]
    out = []
    def add(points, masked=True):
        frame = []
        tag = (len(out)*13+3) & ((1 << t)-1)
        if masked:
            frame.append((high, low, 0, 0, tag))
        for k, (x, y) in enumerate(points):
            frame.append((x, y, 1, 0, (tag+k+1) & ((1 << t)-1)))
        if not frame or len(out) % 3 != 0:
            frame.append((low, high, 0, 0, (tag+7) & ((1 << t)-1)))
        a = frame[-1]
        frame[-1] = (*a[:3], 1, a[4])
        out.append(frame)
    for points in shapes:
        if len(points) <= m:
            add(points)
    # Exhaustive nonempty subsets of a signed 2x2 grid for capacities >=3.
    grid = [(-1, -1), (1, -1), (-1, 1), (1, 1)]
    for mask in range(1, 16):
        points = [p for k, p in enumerate(grid) if mask >> k & 1]
        if len(points) <= m:
            add(points, False)
    rng = random.Random(0xB19+w*31+m)
    for q in range(16):
        n = 1 + q % m
        points = [(rng.randint(low, high), rng.randint(low, high)) for _ in range(n)]
        if q % 5 == 0 and n > 1:
            points[-1] = points[0]
        add(points)
    add([(low, high)]*(m+1))
    add([(high, low)]*(m+2))
    add([], False)
    add([(high, low)], False)
    return out


def prepare():
    profiles = []
    for w, m, t in PROFILES:
        mw, iw, cw = 4*w+4, max(1, (m-1).bit_length()), max(1, m.bit_length())
        rows = []
        stats = dict(frames=0, beats=0, success=0, empty=0, overflow=0,
                     dimension=[0, 0, 0], products=0, reads=0, pairs=0, fractional=0)
        frames = transactions(w, m, t)
        for frame in frames:
            points = [(x, y) for x, y, keep, _, _ in frame if keep]
            tag = frame[0][-1]
            status = 2 if len(points)>m else 1 if not points else 0
            count = min(len(points), m)
            fields = (0,)*16 if status else oracle(points)
            products, reads, pairs, latency = (0, 0, 0, 0) if status else work(points, mw)
            encoded = pack([(v, mw) for v in fields[:8]]+[(fields[8], 1)]+
                           [(v, iw) for v in fields[9:15]]+[(fields[15], 2), (status, 2), (count, cw), (tag, t)])
            rows.append(f'{len(frame)} {encoded:x} {products} {reads} {pairs} {latency}\n')
            for x, y, keep, last, beat_tag in frame:
                rows.append(f'{pack([(x,w),(y,w),(keep,1),(last,1),(beat_tag,t)]):x}\n')
            stats['frames'] += 1
            stats['beats'] += len(frame)
            stats[['success', 'empty', 'overflow'][status]] += 1
            if not status:
                stats['dimension'][fields[-1]] += 1
                stats['products'] += products
                stats['reads'] += reads
                stats['pairs'] += pairs
                dx, dy, u0, u1, v0, v1, den = fields[:7]
                stats['fractional'] += any((u*dx-v*dy) % den or (u*dy+v*dx) % den
                                           for u, v in itertools.product((u0, u1), (v0, v1)))
        name = f'w{w}_m{m}_t{t}'
        fixture = 'sim/fixtures/'+name+'.txt'
        raw = ''.join(rows).encode()
        (ROOT/fixture).parent.mkdir(parents=True, exist_ok=True)
        (ROOT/fixture).write_bytes(raw)
        resets = 5 if m == 1 else 58
        profiles.append(dict(name=name,w=w,m=m,t=t,fixture=fixture,sha256=sha(raw),statistics=stats,resets=resets,
                             latency_bound=2+(m*(m-1)//2)*(6+2*m+(4*m+5)*(mw+2))))
    plan = dict(schema=1,baseline=BASELINE,freeze='before first HDL child',timeout_seconds=20,
                profiles=profiles,negative_parameters=REJECTS,children=19,
                source_sha256=source_hashes(),oracle='exact Fraction convex hull edges + Gaussian corner audit; separate first-pair encoding',
                reset_policy='immediate observed target, all multiplier op first/middle/last steps; full analytic fresh after each',
                source_policy='complete actual next fixture token held through true acceptance or reset cancellation',
                no_synthesis=True,no_inherited_reruns=True)
    (ROOT/'TEST_PLAN.json').write_bytes((json.dumps(plan,indent=2)+'\n').encode())
    print(json.dumps(profiles,indent=2))


def source_hashes():
    return {p.relative_to(ROOT).as_posix():sha(p.read_bytes()) for p in sorted(ROOT.rglob('*'))
            if p.is_file() and p.name not in ['TEST_PLAN.json','verification.json']}


def run():
    plan_raw = (ROOT/'TEST_PLAN.json').read_bytes()
    plan = json.loads(plan_raw)
    assert plan['source_sha256'] == source_hashes()
    for p in plan['profiles']:
        assert sha((ROOT/p['fixture']).read_bytes()) == p['sha256']
    bundled = ROOT.parents[2]/'tools/oss-cad-suite/oss-cad-suite/bin/iverilog.exe'
    compiler = str(bundled) if bundled.is_file() else shutil.which('iverilog')
    assert compiler, 'install a local Icarus compiler; no network installation is attempted'
    simulator = str(Path(compiler).with_name('vvp.exe')) if compiler.endswith('.exe') else shutil.which('vvp')
    prefixes = [str(Path(compiler).parent), str(Path(compiler).parent.parent/'lib')]
    child_env = dict(os.environ)
    child_env['PATH'] = os.pathsep.join(prefixes+[child_env.get('PATH','')])
    records = []
    report = dict(schema=1,baseline=BASELINE,plan_sha256=sha(plan_raw),
                  source_sha256=dict(plan['source_sha256'],**{'TEST_PLAN.json':sha(plan_raw)}),
                  records=records,status='RTL_CANDIDATE',hardware='HW_UNVERIFIED',profiles=plan['profiles'],bounded_finite_only=True,
                  prior_attempts=plan.get('repair_history',[]),tool_path_prefixes=prefixes)
    def save():
        (ROOT/'verification.json').write_bytes((json.dumps(report,indent=2)+'\n').encode())
    def child(name, argv, reject=False):
        started = time.monotonic()
        try:
            result = subprocess.run(argv,cwd=ROOT,capture_output=True,text=True,timeout=20,encoding='utf-8',errors='replace',env=child_env)
            ok = result.returncode != 0 and 'minimum_area_rectangle_invalid_parameter__see_README' in result.stderr if reject else result.returncode == 0
            if name.endswith('_simulate'):
                ok = ok and 'PASS W=' in result.stdout
            rec = dict(name=name,argv=argv,timeout_seconds=20,exit_code=result.returncode,stdout=result.stdout,stderr=result.stderr,
                       status='PASS' if ok else 'FAIL',elapsed_seconds=round(time.monotonic()-started,3))
        except subprocess.TimeoutExpired as error:
            rec = dict(name=name,argv=argv,timeout_seconds=20,exit_code=None,stdout=str(error.stdout or ''),stderr=str(error.stderr or ''),
                       status='TIMEOUT_TERMINAL',elapsed_seconds=round(time.monotonic()-started,3))
        records.append(rec)
        save()
        print(name,rec['status'],rec['elapsed_seconds'])
        if rec['status'] != 'PASS':
            report['status'] = rec['status']
            save()
            raise SystemExit('child stopped; preserve receipt; timeout forbids retry/matrix shrink/limit increase')
    child('version',[compiler,'-V'])
    child('core_syntax',[compiler,'-g2012','-tnull','-s','minimum_area_rectangle','rtl/minimum_area_rectangle.sv'])
    child('example_syntax',[compiler,'-g2012','-tnull','-s','minimum_area_rectangle_example',
                            'rtl/minimum_area_rectangle.sv','example/minimum_area_rectangle_example.sv'])
    with tempfile.TemporaryDirectory(prefix='anscore_c19_') as temp:
        for p in plan['profiles']:
            binary = str(Path(temp)/(p['name']+'.vvp'))
            params = dict(COORD_W=p['w'],MAX_POINTS=p['m'],TAG_W=p['t'],FRAMES=p['statistics']['frames'],RESETS=p['resets'])
            argv = [compiler,'-g2012','-s','tb_minimum_area_rectangle','-o',binary]
            for k,v in params.items():
                argv += ['-P',f'tb_minimum_area_rectangle.{k}={v}']
            child(p['name']+'_compile',argv+['rtl/minimum_area_rectangle.sv','sim/tb_minimum_area_rectangle.sv'])
            child(p['name']+'_simulate',[simulator,binary,'+FIXTURE='+p['fixture']])
        for name,w,m,t in REJECTS:
            child('reject_'+name,[compiler,'-g2012','-tnull','-s','minimum_area_rectangle',
                  '-P',f'minimum_area_rectangle.COORD_W={w}','-P',f'minimum_area_rectangle.MAX_POINTS={m}',
                  '-P',f'minimum_area_rectangle.TAG_W={t}','rtl/minimum_area_rectangle.sv'],True)
    assert len(records) == plan['children']
    report['status'] = 'UNIT_SIM_PASS'
    save()


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--prepare',action='store_true')
    ap.add_argument('--run',action='store_true')
    args = ap.parse_args()
    if args.prepare == args.run:
        ap.error('choose exactly one of --prepare or --run')
    prepare() if args.prepare else run()
