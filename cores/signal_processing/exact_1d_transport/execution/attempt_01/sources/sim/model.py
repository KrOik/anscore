"""Future once-only fixed preparation; no imports or execution during authoring/HDL."""
# SPDX-License-Identifier: Apache-2.0
from __future__ import annotations
import hashlib
import json
from pathlib import Path


def expand(value, count: int) -> list[int]:
    if isinstance(value, list):
        assert len(value) == count and all(type(x) is int for x in value)
        return value[:]
    kind = value['kind']
    if kind == 'affine':
        return [value['start']+value['step']*i for i in range(count)]
    if kind == 'range':
        return [value['value'] if value['lo'] <= i < value['hi'] else 0 for i in range(count)]
    if kind == 'mod':
        return [i % value['modulus'] for i in range(count)]
    if kind == 'parity':
        return [int(i % 2 == value['parity']) for i in range(count)]
    if kind == 'at':
        return [value['value'] if i == value['index'] else 0 for i in range(count)]
    if kind == 'constant':
        return [value['value'] for _ in range(count)]
    if kind == 'ends':
        return [value['first']]+[value['middle']]*(count-2)+[value['last']]
    if kind == 'extreme64':
        assert count == 64
        return [-8388608]+[i-32 for i in range(1,63)]+[8388607]
    raise AssertionError('unknown fixed descriptor')


def prepare(spec_path: Path) -> tuple[dict, dict[str,str]]:
    spec = json.loads(spec_path.read_bytes())
    assert spec['schema'] == 'anscore-transport-fixed-spec-v1'
    assert len(spec['profiles']) == 4 and len(spec['cases']) == 16
    profiles = {p['name']:p for p in spec['profiles']}
    records = []
    for case in spec['cases']:
        p = profiles[case['profile']]
        count, width, mass = p['B'],p['X'],p['C']
        x,a,b = [expand(case[key],count) for key in ('keys','source','target')]
        assert all(-(1 << (width-1)) <= v < (1 << (width-1)) for v in x)
        assert all(0 <= v < (1 << mass) for v in a+b)
        assert 0 <= case['tag'] < (1 << p['TAG'])
        ta,tb = sum(a),sum(b)
        error = int(ta != tb) | (2 if any(x[i] >= x[i+1] for i in range(count-1)) else 0)
        cells, cuts, cost = [], [], 0
        if not error:
            # Independent cut lower bound; no RTL pointer algorithm here.
            prefix = 0
            for i in range(count-1):
                prefix += a[i]-b[i]
                contribution = abs(prefix)*(x[i+1]-x[i])
                cuts.append([i,prefix,x[i+1]-x[i],contribution])
            cut_cost = sum(row[3] for row in cuts)
            ac,bc = [0],[0]
            for value in a: ac.append(ac[-1]+value)
            for value in b: bc.append(bc[-1]+value)
            # B^2 interval cells independently fix the canonical coupling.
            for i in range(count):
                for j in range(count):
                    q = max(0,min(ac[i+1],bc[j+1])-max(ac[i],bc[j]))
                    if q:
                        cells.append([i,j,q,q*abs(x[i]-x[j])])
            assert [sum(row[2] for row in cells if row[0] == i) for i in range(count)] == a
            assert [sum(row[2] for row in cells if row[1] == j) for j in range(count)] == b
            assert cells == sorted(cells) and len(cells) <= 2*count-1
            assert sum(row[2] for row in cells) == ta
            cost = sum(row[3] for row in cells)
            assert cost == cut_cost
        assert (cost,len(cells),error) == (case['hand_cost'],case['hand_flows'],case['hand_error'])
        running, tokens = 0, []
        # tuple: summary,last,src,dst,src_key,dst_key,q,cost,count,error,ta,tb,tag
        for ordinal,(i,j,q,term) in enumerate(cells,1):
            running += term
            tokens.append([0,0,i,j,x[i],x[j],q,running,ordinal,0,ta,tb,case['tag']])
        tokens.append([1,1,0,0,0,0,0,cost,len(cells),error,ta,tb,case['tag']])
        assert running == cost
        records.append(dict(id=case['id'],name=case['name'],profile=case['profile'],tag=case['tag'],
                            inputs=[[x[i],a[i],b[i]] for i in range(count)],tokens=tokens,
                            source_total=ta,target_total=tb,error=error,cost=cost,
                            cut_certificate=cuts,overlap_cells=cells))
    assert [c['id'] for c in records] == list(range(16))
    fixtures = {}
    for name,p in profiles.items():
        selected = [records[i] for i in p['ids']]
        assert sum(len(c['inputs']) for c in selected) == p['inputs']
        assert sum(len(c['tokens']) for c in selected) == p['outputs']
        lines = [' '.join(map(str,[p['B'],p['X'],p['C'],p['TAG'],len(selected)]))]
        for c in selected:
            lines.append(' '.join(map(str,[c['id'],c['tag'],len(c['tokens'])])))
            lines.extend(' '.join(map(str,row)) for row in c['inputs'])
            lines.extend(' '.join(map(str,row)) for row in c['tokens'])
        fixtures[name] = '\n'.join(lines)+'\n'
    bundle = dict(schema='anscore-transport-stored-certificates-v1',fixed_base_frames=16,
                  profiles=4,model_invocations=1,spec_sha256=hashlib.sha256(spec_path.read_bytes()).hexdigest(),
                  cases=records,reset_jobs=spec['reset_jobs'],optimizer_reexecution_for_hdl=False)
    return bundle,fixtures
