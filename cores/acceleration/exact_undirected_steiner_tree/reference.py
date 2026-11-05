"""Independent induced-vertex-set/Kruskal reference: preparation phase only.

This module has no top-level model invocation. HDL/checker code must not import it.
Source authoring has not executed materialize(), optimum() or validate_witness().
"""
from itertools import combinations


def materialize(profile, case):
    n, w = profile['N'], profile['W']
    maximum = (1 << w) - 1
    edges = {tuple(sorted((u, v))): weight for u, v, weight in case.get('edges', [])}
    recipe = case.get('edge_recipe')
    if recipe in ('unit_chain', 'unit_chain_zero_last'):
        edges = {(i, i + 1): 1 for i in range(n - 1)}
        if recipe == 'unit_chain_zero_last':
            edges[n - 2, n - 1] = 0
    elif recipe == 'shared_branch_max':
        assert n == 8
        edges = {(i, i + 1): maximum for i in range(5)}
        edges[5, 6] = edges[5, 7] = maximum
    elif recipe == 'weighted_chain':
        edges = {(i, i + 1): i + 1 for i in range(n - 1)}
    elif recipe == 'weighted_star':
        leaves = set(case['terminals'])
        edges = {(0, i): i + 1 if i in leaves else 100 + i for i in range(1, n)}
    elif recipe == 'max_chain_bypass':
        assert n == 16
        edges = {(i, i + 1): maximum for i in range(n - 1)}
        edges.update({(0, 15): 1, (0, 3): 2, (0, 6): 3, (0, 9): 4, (0, 12): 5})
    elif recipe == 'split_chain':
        edges = {(i, i + 1): 1 for i in range(n - 1) if i != 7}
    else:
        assert recipe is None, recipe
    assert all(0 <= u < v < n and 0 <= weight <= maximum for (u, v), weight in edges.items())
    terminals = tuple(case['terminals'])
    assert len(set(terminals)) == len(terminals) and all(0 <= v < n for v in terminals)
    absent = maximum if case.get('absent_weight') == 'MAX' else 0
    pairs = list(combinations(range(n), 2))
    inputs = []
    last_mode = case.get('last_mode', 'correct')
    assert last_mode in ('correct', 'missing', 'early_and_final')
    for index, pair in enumerate(pairs):
        last = int(index == len(pairs) - 1 and last_mode != 'missing')
        if last_mode == 'early_and_final' and index == 0:
            assert len(pairs) > 1
            last = 1
        inputs.append((int(pair in edges), edges.get(pair, absent), last))
    error = int(not 1 <= len(terminals) <= profile['K'])
    error |= 2 * int(any(weight == 0 for weight in edges.values()))
    error |= 4 * int(last_mode != 'correct')
    assert error == case.get('error', 0), (case['name'], error)
    return dict(name=case['name'], n=n, terminals=terminals, edges=edges, inputs=inputs,
                terminal_mask=sum(1 << v for v in terminals), error=error)


def optimum(graph):
    """Enumerate optional vertex sets; each connected induced MST is feasible."""
    if graph['error']:
        return dict(feasible=False, cost=0, edges=(), error=graph['error'])
    terminals = frozenset(graph['terminals'])
    if len(terminals) == 1:
        return dict(feasible=True, cost=0, edges=(), error=0)
    optional = [v for v in range(graph['n']) if v not in terminals]
    # Named max profiles have six terminals and at most1024 trials. This limit
    # rejects accidental broad preparation work instead of hiding an expansion.
    assert len(optional) <= 10
    ordered = sorted((weight, u, v) for (u, v), weight in graph['edges'].items())
    best = None
    for choice in range(1 << len(optional)):
        retained = set(terminals) | {v for i, v in enumerate(optional) if choice & (1 << i)}
        parent = {v: v for v in retained}

        def find(v):
            while parent[v] != v:
                v = parent[v]
            return v

        cost, selected = 0, []
        for weight, u, v in ordered:
            if u not in retained or v not in retained:
                continue
            a, b = find(u), find(v)
            if a != b:
                parent[a] = b
                selected.append((u, v, weight))
                cost += weight
        if len(selected) != len(retained) - 1:
            continue
        if best is None or cost < best['cost']:
            best = dict(feasible=True, cost=cost, edges=tuple(sorted(selected)), error=0)
    return best if best is not None else dict(feasible=False, cost=0, edges=(), error=0)


def validate_witness(graph, target, edges):
    """Direct supplied-certificate checks, not another optimality search."""
    assert not graph['error'] and target['feasible']
    assert list(edges) == sorted(edges)
    assert len(edges) <= graph['n'] - 1
    parent = list(range(graph['n']))

    def find(v):
        while parent[v] != v:
            v = parent[v]
        return v

    vertices, cost = set(), 0
    for u, v, weight in edges:
        assert 0 <= u < v < graph['n']
        assert graph['edges'].get((u, v)) == weight and weight > 0
        a, b = find(u), find(v)
        assert a != b
        parent[a] = b
        vertices.update((u, v))
        cost += weight
    if len(graph['terminals']) == 1:
        assert not edges
        vertices = set(graph['terminals'])
    root = find(graph['terminals'][0])
    assert all(find(v) == root for v in vertices | set(graph['terminals']))
    assert cost == target['cost']
    return sum(1 << v for v in vertices)
