"""Run each family's own reference checks plus algebraic cross-verification.

The family models are the source of truth for the generated vectors, so a model
bug would otherwise be invisible: RTL, testbench and board expectation all come
from the same function. These checks attack it from a different direction --
published check values, exhaustive small-domain round trips, and identities.
"""
from catalog import CORES, SELFTESTS
from golden import MASK, step, vectors


def cross_checks():
    """Family-independent properties that must hold for every catalog core."""
    checks = 0
    for entry in CORES:
        name = entry['name']
        responses = set()
        # Thread state exactly like generate.py and the board harness do: a
        # stateful core's responses are only distinct across the sequential run,
        # and pinning state to 0 here would grade a different experiment.
        state = 0
        for index, (a, b, c) in enumerate(vectors(name, 320)):
            r, x, f, state = step(name, a, b, c, state)
            assert 0 <= r <= MASK and 0 <= x <= MASK and f in (0, 1)
            if not entry['stateful']:
                assert step(name, a, b, c, 0)[:3] == (r, x, f), f'{name}: not a function'
            checks += 1
            if index < 128:
                responses.add((r, x, f))
        assert len(responses) >= 96, f'{name}: board set cannot discriminate'
    return checks


def main():
    # Each family registers the same callable for all of its cores: dedupe by id.
    seen, families = set(), []
    for function in SELFTESTS.values():
        if id(function) not in seen:
            seen.add(id(function))
            families.append(function)
    checks = 0
    for function in families:
        count = function()
        checks += count
        print(f'SELF {function.__module__}: {count} checks', flush=True)
    cross = cross_checks()
    print(f'PASS independent model self={checks} cross={cross} families={len(families)}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
