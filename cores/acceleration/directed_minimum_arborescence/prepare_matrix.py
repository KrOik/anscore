"""Create the complete finite matrix before RTL; no upstream code is run."""
from pathlib import Path
from hashlib import sha256
from itertools import product
from random import Random
import json

ROOT = Path(__file__).resolve().parent
BASELINE = 'd35d71be3bfc76f272809ae250d19cba92dbb18c'
PROFILES = [(1, 1, 1, 1), (2, 3, 1, 3), (4, 8, 4, 5),
            (8, 16, 8, 8), (12, 32, 12, 32)]
STATES = ['CAPTURE', 'INIT', 'MIN_EDGE_READ', 'MIN_EDGE_USE',
          'MIN_NODE_READ', 'MIN_NODE_USE', 'MIN_NEXT', 'VERIFY_READ',
          'VERIFY_USE', 'WALK_READ', 'WALK_USE', 'CYCLE_READ', 'CYCLE_USE',
          'WALK_NEXT', 'COMPONENT_READ', 'COMPONENT_USE', 'ROOT_READ',
          'ROOT_USE', 'CONTRACT_EDGE_READ', 'CONTRACT_EDGE_USE',
          'CONTRACT_FROM_READ', 'CONTRACT_FROM_USE', 'CONTRACT_TO_READ',
          'CONTRACT_TO_USE', 'CONTRACT_NEXT', 'LAYER_NEXT', 'SELECT_READ',
          'SELECT_USE', 'EXPAND_INIT_READ', 'EXPAND_INIT_USE',
          'EXPAND_NODE_READ', 'EXPAND_NODE_USE', 'EXPAND_EDGE_READ',
          'EXPAND_EDGE_USE', 'EXPAND_DEST_READ', 'EXPAND_DEST_USE',
          'EXPAND_NEXT', 'SUM_NODE_READ', 'SUM_NODE_USE', 'SUM_EDGE_READ',
          'SUM_EDGE_USE', 'OUTPUT_NODE_READ', 'OUTPUT_NODE_USE',
          'OUTPUT_EDGE_READ', 'OUTPUT_EDGE_USE', 'OUTPUT_HOLD', 'SUMMARY']
SEMANTIC = [
    'CAPTURE_PARTIAL', 'MIN_ZERO_UPDATE', 'CYCLE_FIRST_ASSIGN',
    'CYCLE_LAST_ASSIGN', 'NESTED_LAYER_TWO', 'CONTRACT_POSITIVE_REDUCTION',
    'CONTRACT_INTERNAL_DISABLED', 'EXPAND_OVERRIDE', 'SUM_ACC_NONZERO',
    'OUTPUT_FIRST_HELD', 'OUTPUT_MIDDLE_HELD', 'OUTPUT_LAST_EDGE_HELD',
    'SUMMARY_FEASIBLE_HELD', 'SUMMARY_NO_TREE_HELD', 'SUMMARY_BAD_FRAME_HELD',
    'ACTUAL_NEXT_BLOCKED', 'CAPTURE_CAPACITY_ERROR', 'NONZERO_CONTRACTED_ROOT']
TARGETS = STATES + SEMANTIC
PREDICATES = {str(i): 'state==' + str(i) for i in range(len(STATES))}
PREDICATES.update(dict(zip(map(str, range(47, 65)), [
    'CAPTURE and capture_active and !s_last',
    'MIN_NODE_USE and edge_cost==0 and (!min_valid or min_cost>0)',
    'CYCLE_USE and cursor==cycle_anchor',
    'CYCLE_USE and min_parent==cycle_anchor and cursor!=cycle_anchor',
    'INIT and layer==2',
    'CONTRACT_TO_USE and min_cost>0 and from_component!=to_component',
    'CONTRACT_TO_USE and from_component==to_component',
    'EXPAND_DEST_USE', 'SUM_EDGE_USE and total>0',
    'OUTPUT_HOLD and prior_retired==0 and !ready',
    'OUTPUT_HOLD and prior_retired==1 and prior_retired<N-2 and !ready',
    'OUTPUT_HOLD and prior_retired==N-2 and !ready',
    'SUMMARY and feasible and errors==0 and !ready',
    'SUMMARY and !feasible and errors==0 and !ready',
    'SUMMARY and errors!=0 and !ready',
    'actual next-frame first record valid&&!ready outside CAPTURE',
    'CAPTURE and errors[2] and capture_active',
    'INIT and layer==1 and root!=0'])))


def enc(value):
    return (json.dumps(value, sort_keys=True, indent=2) + '\n').encode()


def bound(n, m):
    return 4*n**3 + 24*n*n + 16*n*m + 32*n + 64


def exhaustive(n, root, edges):
    """Independent enumeration of incoming ORIGINAL edges, never contraction."""
    vertices = [v for v in range(n) if v != root]
    incoming = [[i for i, (u, w, c) in enumerate(edges) if w == v and u != v]
                for v in vertices]
    choices = 1
    for row in incoming:
        choices *= len(row)
    best = None
    best_indices = None
    valid_trees = 0
    for selection in product(*incoming):
        parents = {v: edges[e][0] for v, e in zip(vertices, selection)}
        valid = True
        for v in vertices:
            seen = set()
            u = v
            while u != root:
                if u in seen:
                    valid = False
                    break
                seen.add(u)
                u = parents[u]
            if not valid:
                break
        if valid:
            valid_trees += 1
            cost = sum(edges[e][2] for e in selection)
            if best is None or cost < best:
                best, best_indices = cost, list(selection)
    assert choices <= 118098
    return dict(feasible=int(best is not None), total=best or 0,
                incoming_combinations=choices, rooted_candidates=valid_trees,
                certificate_vertices=vertices, one_optimal_witness=best_indices)


def frame(n, m, c, t, name, edges, root=0, rng=None, extra=None):
    rng = rng or Random(0x25)
    tag = rng.getrandbits(t)
    rows = []
    for i, e in enumerate(edges):
        u, v, cost = e
        rows.append(dict(keep=1, src=u, dst=v, cost=cost, error=0))
    if extra:
        rows += extra
    if not rows:
        rows = [dict(keep=0, src=0xffffffff, dst=0xffffffff,
                     cost=(1 << c)-1, error=0)]
    for i, row in enumerate(rows):
        row.update(last=int(i == len(rows)-1),
                   root=root if i == 0 else rng.getrandbits(32),
                   tag=tag if i == 0 else rng.getrandbits(t))
        assert 0 <= row['cost'] < (1 << c)
    errors = int(root >= n)
    kept = []
    for row in rows:
        errors |= int(bool(row['error'])) << 3
        if row['keep']:
            errors |= int(row['src'] >= n or row['dst'] >= n) << 1
            errors |= int(len(kept) >= m) << 2
            kept.append([row['src'], row['dst'], row['cost']])
    oracle = (dict(feasible=0, total=0, incoming_combinations=0,
                   rooted_candidates=0, certificate_vertices=[], one_optimal_witness=None)
              if errors else exhaustive(n, root, kept))
    return dict(name=name, root=root, tag=tag, records=rows,
                kept_edges=kept, errors=errors,
                expected_records=n if oracle['feasible'] else 1,
                latency_bound=bound(n, m), **oracle)


def nested(n, c, root=0, full=None):
    if n < 4:
        es = [(root, v, min(1, (1 << c)-1)) for v in range(n) if v != root]
        if not es:
            es = [(root, root, 0)]
    else:
        labels = [root] + [v for v in range(n) if v != root]
        raw = [(1, 2, 0), (2, 1, 0), (2, 3, 1), (3, 1, 1), (0, 1, 5)]
        raw += [(0, v, 2) for v in range(4, n)]
        es = [(labels[u], labels[v], min(k, (1 << c)-1)) for u, v, k in raw]
    if full is not None:
        while len(es) < full:
            i = len(es)
            es.append((i % n, i % n, ((1 << c)-1) if i % 2 else 0))
    return es


def main_frames(n, m, c, t):
    rng = Random(0xB25A4B + 97*n + m)
    make = lambda name, es, **kw: frame(n, m, c, t, name, es, rng=rng, **kw)
    out = [make('empty', []), make('full_capacity_nested', nested(n, c, full=m)),
           make('nonzero_root_nested', nested(n, c, root=n-1, full=m), root=n-1),
           make('all_loops', [(v % n, v % n, (1 << c)-1) for v in range(m)])]
    for r in range(n):
        out.append(make('rooted_star', [(r, v, (1 << c)-1) for v in range(n) if v != r], root=r))
        out.append(make('reverse_star', [(v, r, 0) for v in range(n) if v != r], root=r))
    # Full32-bit validation before narrowing, kept-slot capacity, and error unions.
    for bit in range(32):
        for which in ('root', 'src', 'dst'):
            v = 1 << bit
            kw = dict(root=v) if which == 'root' else {}
            es = [(v if which == 'src' else 0, v if which == 'dst' else 0, 0)]
            out.append(make('isolated_'+which+'_bit_'+str(bit), es, **kw))
    out += [make('capacity_plus_one', [(0, 0, 0)]*(m+1)),
            make('ignored_bad_fields', [], extra=[dict(keep=0, src=0xffffffff,
                 dst=0xffffffff, cost=(1 << c)-1, error=0)]),
            make('upstream_error_ignored_row', [], extra=[dict(keep=0, src=0xffffffff,
                 dst=0xffffffff, cost=0, error=1)]),
            make('all_error_bits', [(0xffffffff, 0xffffffff, 0)]*(m+1), root=0xffffffff,
                 extra=[dict(keep=0, src=0, dst=0, cost=0, error=1)])]
    if n == 2:
        candidates = [(0, 0, 0), (0, 1, 0), (0, 1, 1), (1, 0, 0), (1, 1, 1)]
        for mask in range(1 << len(candidates)):
            for r in range(2):
                out.append(make('exhaustive_two_vertex_multigraph',
                                [e for i, e in enumerate(candidates) if mask >> i & 1], root=r))
    if n >= 4:
        # Cycle unreachable from root despite an incoming edge at every nonroot.
        out.append(make('closed_cycle_no_tree', [(1, 2, 0), (2, 1, 0)] +
                        [(0, v, 0) for v in range(3, n)]))
        out.append(make('equal_parallel_ties', [(0, v, 0) for v in range(1, n)] +
                        [(0, 1, 0)] * (m-n+1)))
    for trial in range(48):
        r = rng.randrange(n)
        es = [(r, v, rng.randrange(1 << c)) for v in range(n) if v != r] if trial % 2 else []
        edge_target = m if trial % 3 else rng.randrange(m+1)
        while len(es) < edge_target:
            es.append((rng.randrange(n), rng.randrange(n), rng.randrange(1 << c)))
        rng.shuffle(es)
        out.append(make('seeded_directed_multigraph', es, root=r))
    return out


def targets(n):
    excluded = {}
    if n <= 2:
        names = {'CYCLE_READ', 'CYCLE_USE', 'COMPONENT_READ', 'COMPONENT_USE',
                 'ROOT_READ', 'ROOT_USE', 'LAYER_NEXT', 'CONTRACT_NEXT',
                 'EXPAND_NEXT'}
        names.update(x for x in STATES if x.startswith(('CONTRACT_', 'EXPAND_')))
        names.update(SEMANTIC[2:8])
        names.update(['SUM_ACC_NONZERO', 'OUTPUT_MIDDLE_HELD', 'NONZERO_CONTRACTED_ROOT'])
        for i, x in enumerate(TARGETS):
            if x in names:
                excluded[i] = 'fewer than two nonroot vertices: no directed cycle contraction/expansion or multi-edge prefix'
    if n == 1:
        names = {'MIN_NODE_READ', 'MIN_NODE_USE', 'SUM_EDGE_READ', 'SUM_EDGE_USE',
                 'OUTPUT_EDGE_READ', 'OUTPUT_EDGE_USE', 'OUTPUT_HOLD',
                 'MIN_ZERO_UPDATE', 'OUTPUT_FIRST_HELD', 'OUTPUT_LAST_EDGE_HELD',
                 'SUMMARY_NO_TREE_HELD'}
        for i, x in enumerate(TARGETS):
            if x in names:
                excluded[i] = 'single root has no parent edge and is always feasible for a valid frame'
    return [i for i in range(len(TARGETS)) if i not in excluded], excluded


def text_frame(f, nxt):
    lines = [f"{len(f['records'])} {f['errors']} {f['feasible']} {f['total']} {f['tag']:08x} {f['root']:08x} {f['expected_records']} {f['latency_bound']}"]
    nr = nxt['records'][0] if nxt else dict(keep=0, src=0, dst=0, cost=0, last=0, root=0, tag=0, error=0)
    lines.append(f"{int(nxt is not None)} {nr['keep']} {nr['src']:08x} {nr['dst']:08x} {nr['cost']:04x} {nr['last']} {nr['root']:08x} {nr['tag']:08x} {nr['error']}")
    for r in f['records']:
        lines.append(f"{r['keep']} {r['src']:08x} {r['dst']:08x} {r['cost']:04x} {r['last']} {r['root']:08x} {r['tag']:08x} {r['error']}")
    return lines


def prepare():
    assert not (ROOT/'TEST_PLAN.json').exists()
    assert not list(ROOT.rglob('*.sv')) and not list(ROOT.rglob('*.v'))
    files, profiles, children = {}, [], []
    def child(name, argv, expected='PASS'):
        children.append(dict(name=name, argv=argv, expected=expected, timeout_seconds=20))
    child('core_lint', ['iverilog', '-g2012', '-Wall', '-tnull', '-s', 'directed_minimum_arborescence', '-f', 'files.f'])
    child('example_lint', ['iverilog', '-g2012', '-Wall', '-tnull', '-s', 'arborescence8', '-f', 'example/files.f'])
    def fixture(name, data, lines):
        j, txt = 'fixtures/'+name+'.json', 'fixtures/'+name+'.txt'
        files[j], files[txt] = enc(data), ('\n'.join(lines)+'\n').encode('ascii')
        return dict(name=name, json=j, text=txt,
                    json_sha256=sha256(files[j]).hexdigest(), text_sha256=sha256(files[txt]).hexdigest())
    for pi, (n, m, c, t) in enumerate(PROFILES):
        pn = 'p'+str(pi)
        child(pn+'_compile', ['iverilog', '-g2012', '-Wall', '-s', 'tb_directed_minimum_arborescence', '-o', '{TMP}/'+pn+'.vvp',
              '-Ptb_directed_minimum_arborescence.N='+str(n), '-Ptb_directed_minimum_arborescence.M='+str(m),
              '-Ptb_directed_minimum_arborescence.C='+str(c), '-Ptb_directed_minimum_arborescence.T='+str(t),
              'rtl/directed_minimum_arborescence.sv', 'sim/tb_directed_minimum_arborescence.sv'])
        frames = main_frames(n, m, c, t)
        qs, excluded = targets(n)
        p = dict(name=pn, N=n, M=m, C=c, T=t, main=[], resets=[],
                 reset_ids=qs, excluded_reset_targets=excluded, latency_bound=bound(n, m))
        # Frozen complete-frame grouping, never selected using a measured HDL runtime.
        group_size = 16 if n == 12 else 32
        for k in range(0, len(frames), group_size):
            group = frames[k:k+group_size]
            lines = ['0 '+str(len(group))]
            for i, f in enumerate(group):
                lines += text_frame(f, group[i+1] if i+1 < len(group) else None)
            name = pn+'_main_'+str(k//group_size).zfill(3)
            z = fixture(name, dict(mode='main', profile=pn, frames=group), lines)
            z.update(frames=len(group), outputs=sum(x['expected_records'] for x in group),
                     queued=len(group)-1, oracle_combinations=sum(x['incoming_combinations'] for x in group))
            p['main'].append(z)
            child(name, ['vvp', '{TMP}/'+pn+'.vvp', '+INPUT='+z['text']])
        fresh = frame(n, m, c, t, 'full_capacity_fresh_nonzero_root', nested(n, c, root=n-1, full=m), root=n-1)
        for q in qs:
            owner_edges = nested(n, c, full=m)
            owner_root = 0
            owner_extra = None
            if q in (46, 61):
                owner_root = 0xffffffff
            if q == 60:
                owner_edges = [(0, 0, 0)]
            if q == 63:
                owner_edges = [(0, 0, 0)]*(m+2)
            if q == 48:
                owner_edges = [(u, v, 0) for u, v, cost in owner_edges]
            if q == 47:
                owner_extra = [dict(keep=0, src=0, dst=0, cost=0, error=0)]
            owner = frame(n, m, c, t, 'cancel_'+TARGETS[q], owner_edges,
                          root=owner_root, extra=owner_extra)
            prefix = 1 if q == 57 else n-2 if q == 58 else n-1 if q == 59 else 0
            assert 0 <= prefix < owner['expected_records']
            lines = ['1 1', str(q)+' '+str(prefix)] + text_frame(owner, fresh) + text_frame(fresh, None)
            name = pn+'_reset_'+str(q).zfill(3)
            z = fixture(name, dict(mode='reset', profile=pn, target=q,
                        owner=owner, fresh=fresh, owner_retired_prefix=prefix,
                        next_offered=fresh['records'][0]), lines)
            z.update(frames=1, outputs=fresh['expected_records'], queued=0, resets=1,
                     oracle_combinations=fresh['incoming_combinations']+owner['incoming_combinations'])
            p['resets'].append(z)
            child(name, ['vvp', '{TMP}/'+pn+'.vvp', '+INPUT='+z['text']])
        p.update(main_frames=len(frames), main_outputs=sum(x['expected_records'] for x in frames),
                 reset_count=len(qs), fresh_frames=len(qs), fresh_outputs=len(qs)*fresh['expected_records'],
                 main_queued=sum(z['queued'] for z in p['main']))
        profiles.append(p)
    rejects = [(p, v) for p, hi in [('NUM_NODES', 13), ('MAX_EDGES', 33), ('COST_W', 13), ('TAG_W', 33)] for v in [0, hi]]
    for p, v in rejects:
        child('reject_'+p+'_'+str(v), ['iverilog', '-g2012', '-Wall', '-tnull', '-s', 'directed_minimum_arborescence',
              '-Pdirected_minimum_arborescence.'+p+'='+str(v), '-f', 'files.f'], 'EXPECTED_REJECT')
    totals = {k: sum(p[k] for p in profiles) for k in ['main_frames', 'main_outputs', 'main_queued', 'reset_count', 'fresh_frames', 'fresh_outputs']}
    totals.update(children=len(children), expected_rejects=len(rejects), fixtures=len(files)//2,
                  fixture_files=len(files), simulations=sum(len(p['main'])+len(p['resets']) for p in profiles))
    plan = dict(schema=1, baseline=BASELINE, frozen_before_rtl=True, timeout_seconds=20,
                timeout_terminal=True, no_adaptive_splits=True,
                preparation_sha256=sha256(Path(__file__).read_bytes()).hexdigest(),
                algorithm='serial Chu-Liu/Edmonds contraction plus reverse expansion; stable original edge slots',
                oracle='exhaustive ORIGINAL incoming-edge combinations; parent-chain rootedness; exact minimum integer sum; any optimal witness accepted',
                input='32-bit unsigned root/endpoints validated before narrowing; kept loops and parallel edges consume MAX_EDGES; keep0 geometry ignored; first accepted root/tag snapshot; drain through LAST before error summary',
                output='N-1 parent-edge records ordered by child, then one summary; errors or infeasibility give only canonical zero-geometry/zero-total summary; total and flags repeated on every output',
                errors={'ROOT': 1, 'ENDPOINT': 2, 'CAPACITY': 4, 'UPSTREAM': 8},
                tie_rule='lowest original ordinal for equal local adjusted incoming costs; no globally lexicographic promise',
                numeric='adjusted edge cost stays unsigned COST_W because subtraction is by minimum incoming cost; total COST_W+ceil(log2(max(1,N-1)))',
                reset_observation='first falling-edge predicate occurrence cancels before next active edge; only explicit prefix targets retire owner edges; next offer is exact first fresh record and reset cancels it before reoffer',
                reset_fresh='every target has a complete full-capacity fresh graph and complete witness+summary; all RAM rows must be written in this post-reset owner before any read',
                states={str(i): x for i,x in enumerate(STATES)},
                reset_targets={str(i): x for i,x in enumerate(TARGETS)}, reset_predicates=PREDICATES,
                frozen_stalls='one input bubble before row index2 mod5; every output held for two cycles then accepted; hold exact next first record during solve/output; no acceptance before summary retirement',
                profiles=profiles, children=children, rejections=rejects, totals=totals,
                architecture={'edge_RAM': 'N*M rows x (1+2V+C)', 'node_RAM': 'N*N rows x (6+C+3V+2E)',
                              'ports': 'one synchronous read OR write per memory per cycle, no collision',
                              'default_RAM_bits': 3904, 'maximum_RAM_bits': 13824,
                              'provisional_scalar_upper_default': 256, 'provisional_scalar_upper_maximum': 384,
                              'arithmetic': 'one C-bit subtract, one total-width add; no data multiplier/divider'},
                excluded=['synthesis', 'PnR', 'STA', 'board', 'expanded regression', 'inherited matrix'])
    (ROOT/'fixtures').mkdir(exist_ok=False)
    for path, raw in files.items():
        (ROOT/path).write_bytes(raw)
    (ROOT/'TEST_PLAN.json').write_bytes(enc(plan))
    print(json.dumps(dict(plan_sha256=sha256((ROOT/'TEST_PLAN.json').read_bytes()).hexdigest(), **totals)))


if __name__ == '__main__':
    prepare()
