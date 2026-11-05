"""Finite reset-witness scheduler, deliberately separate from the sorted oracle.

Only used by the separately approved preparer to freeze actual-state predicates.
It supplies no expected output values: those always come from oracle.py.
"""
LOAD, INITIALIZE, PASS_READ, PASS_MULT, PASS_CHECK, PASS_END, OUTPUT_READ, OUTPUT_MULT, OUTPUT_CHECK, HOLD = range(10)
TARGETS = ['partial_load', 'initialize_zero', 'initialize_positive',
           'first_pass_read', 'first_pass_mult', 'strict_retain',
           'strict_delete', 'threshold_equality_delete', 'pass_end_drop',
           'pass_end_fixed', 'later_pass_read', 'output_read', 'output_mult',
           'output_check', 'held_nonlast', 'held_last',
           'after_prefix_output_read', 'actual_next_offer_held_last']
N1_EXCLUDED = [0, 6, 7, 8, 10, 14, 16]


def walk(values, mass):
    n = len(values)
    acc = sum(values)
    yield dict(state=INITIALIZE, index=0, prefix=0, mask=16, acc=acc)
    k, round_number, t, active, kept, acc = n, 0, 0, 0, 0, 0
    if mass == 0:
        k = 1
    else:
        k, round_number, t, active = n, 1, sum(values)-mass, (1 << n)-1
        while True:
            for i, value in enumerate(values):
                base = dict(index=i, prefix=0, k=k, round=round_number,
                            threshold=t, acc=acc, kept=kept, active=active)
                yield dict(base, state=PASS_READ, mask=1)
                yield dict(base, state=PASS_MULT, mask=3, read=value)
                product = k*value
                yield dict(base, state=PASS_CHECK, mask=7, read=value, product=product)
                if active & (1 << i) and product > t:
                    acc += value
                    kept += 1
                else:
                    active &= ~(1 << i)
            yield dict(state=PASS_END, index=n-1, prefix=0, mask=1, k=k,
                       round=round_number, threshold=t, acc=acc, kept=kept, active=active)
            assert kept > 0 and round_number <= n
            if kept == k:
                break
            k, round_number, t, acc, kept = kept, round_number+1, acc-mass, 0, 0
    assert round_number <= n
    for i, value in enumerate(values):
        base = dict(index=i, prefix=i, k=k, round=round_number,
                    threshold=t, acc=acc, kept=kept, active=active)
        yield dict(base, state=OUTPUT_READ, mask=1)
        yield dict(base, state=OUTPUT_MULT, mask=3, read=value)
        yield dict(base, state=OUTPUT_CHECK, mask=7, read=value, product=k*value)
        # Numerator deliberately omitted; TB/runner use only the independent certificate.
        yield dict(base, state=HOLD, mask=7, read=value, product=k*value)


def matches(target, e, values, mass):
    state, i = e['state'], e['index']
    if target == 0:
        return False  # Explicit partial-load witness is constructed before full loading.
    if target == 1: return state == INITIALIZE and mass == 0
    if target == 2: return state == INITIALIZE and mass > 0
    if target == 3: return state == PASS_READ and e['round'] == 1 and i == 0
    if target == 4: return state == PASS_MULT and e['round'] == 1 and i == 0
    if target in (5, 6, 7):
        if state != PASS_CHECK or not e['active'] & (1 << i): return False
        a, b = e['product'], e['threshold']
        return a > b if target == 5 else a < b if target == 6 else a == b
    if target == 8: return state == PASS_END and e['kept'] < e['k']
    if target == 9: return state == PASS_END and e['kept'] == e['k']
    if target == 10: return state == PASS_READ and e['round'] > 1
    if target in (11, 12, 13): return state == target-5 and i == 0
    if target == 14: return state == HOLD and i < len(values)-1
    if target in (15, 17): return state == HOLD and i == len(values)-1
    if target == 16: return state == OUTPUT_READ and i == 1
    raise AssertionError('unknown fixed target')


def reset_witness(target, values, mass, cert):
    if target == 0:
        assert len(values) > 1
        return dict(state=LOAD, index=1, prefix=0, mask=16, acc=values[0])
    chosen = None
    for event in walk(values, mass):
        if event['state'] == OUTPUT_READ and event['index'] == 0:
            assert event['k'] == cert['denominator']
            assert mass == 0 or event['threshold'] == cert['threshold_numerator']
        if chosen is None and matches(target, event, values, mass):
            chosen = event
    assert chosen is not None, 'fixed witness failed: stop; do not search another owner'
    return chosen


def always_ready_bound(n):
    # INITIALIZE + <=N*(3*N+1) passes + 4*N output cycles.
    return 1+n*(3*n+1)+4*n
