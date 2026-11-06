"""Only the explicitly reviewed preparation child imports the local oracle once."""
from pathlib import Path
import argparse, hashlib, importlib.util, json, random


def core_cases(n, p, q, t):
    pm, qm, tm = (1 << p)-1, (1 << q)-1, (1 << t)-1
    raw = [([], 0, 0), ([], pm, n+1), ([], pm, 0xffffffff),
           ([(0, 0, 1)], 0, 1), ([(1, pm, qm)], pm, 1),
           ([(0, pm, 0)], pm, 1)]
    if n >= 2:
        fixed = [([(0, pm, qm), (1, 0, qm)], pm//2),
                 ([(0, 0, 1), (1, pm, 1)], pm),
                 ([(0, pm, qm), (1, pm, 1)], pm),
                 ([(0, 0, 1), (1, 0, qm)], 0)]
        for rows, ref in fixed:
            raw.append((rows, ref, len(rows)))
    else:
        raw += [([(side, price, qty)], ref, 1) for side, price, qty, ref in
                [(0, pm, qm, 0), (1, 0, 1, pm), (0, pm, 1, pm), (1, pm, qm, 0)]]
    # These directed cases exercise eligibility, distance and lowest-price ties.
    special = [([(0, 10, 9), (0, 5, 1), (1, 0, 5)], 5),
               ([(0, 10, 5), (1, 0, 5)], 5),
               ([(0, 10, 5), (1, 0, 5)], 9),
               ([(0, 10, 5), (1, 0, 5)], 0),
               ([(0, 10, 3), (0, 10, 2), (1, 0, 5)], 5),
               ([(0, 10, 2), (1, 0, 5)], 5)]
    for rows, ref in special:
        rows = [(s, price & pm, min(qty, qm)) for s, price, qty in rows][:n]
        raw.append((rows, ref & pm, len(rows)))
    rng = random.Random(440310+n*100+p+q+t)
    for case in range(32):
        count = n if case % 4 == 0 else rng.randrange(n+1)
        rows = [(rng.randrange(2), rng.getrandbits(p), rng.randrange(1, qm+1)) for _ in range(count)]
        if count and case % 7 == 0:
            j = case % count
            rows[j] = (rows[j][0], rows[j][1], 0)
        rng.shuffle(rows)
        raw.append((rows, rng.getrandbits(p), count))
    return [(rows, ref, (index*31) & tm, count) for index, (rows, ref, count) in enumerate(raw)]


def book_cases(levels, p, q, t, oracle):
    book = oracle.Book(levels, p, q)
    pm, qm, tm = (1 << p)-1, (1 << q)-1, (1 << t)-1
    commands = []
    def maint(op, side=0, price=0, qty=0, rank=0):
        result = book.command(op, side, price, qty, rank)
        commands.append([0, op, side, price, qty, rank, 0, (len(commands)*19)&tm,
                         result['status'], result['found'], result['price'], result['quantity'], result['previous'],
                         result['bids'], result['asks'], 0, 0, 0, 0, 0])
    def auction(ref):
        before = [dict(s) for s in book.sides]
        result = book.auction(ref)
        assert book.sides == before
        commands.append([1, 0, 0, 0, 0, 0, ref, (len(commands)*19)&tm,
                         result['status'], 0, result['price'], 0, 0, result['bids'], result['asks'],
                         result['rows'], result['matched'], result['buy'], result['sell'], result['imbalance']])
    auction(0)
    maint(0, 0, pm, qm); maint(0, 1, 0, qm)
    auction(pm//2); auction(pm); auction(0)
    maint(4, 0); maint(4, 1); maint(5, 0, rank=0); maint(5, 1, rank=0)
    maint(1, 0, pm, 1); maint(2, 1, 0, 0); maint(5, 0, rank=0xffffffff); maint(8)
    for side in (0, 1):
        maint(6, side)
        for i in range(levels):
            maint(0, side, (pm-i) if side == 0 else i, qm)
    auction(pm//2); auction(pm)
    for side in (0, 1):
        for rank in range(levels):
            maint(5, side, rank=rank)
        maint(0, side, pm if side == 0 else 0, 1)
        maint(0, side, levels if side else pm-levels, 1)
    auction(0)
    maint(7)
    # Reset is a public cancellation/empty-book event, not a response transaction.
    commands.append([2]+[0]*19); book.reset(); auction(pm)
    rng = random.Random(440811+levels)
    for i in range(72):
        if i % 3 == 0:
            auction(rng.getrandbits(p))
        else:
            op = rng.choice([0, 0, 1, 2, 3, 4, 5, 6])
            maint(op, rng.randrange(2), rng.randrange(min(pm+1, levels+3)),
                  rng.choice([0, 1, qm, max(1, qm//2)]), rng.choice([0, levels-1, levels, 0xffffffff]))
    auction(pm); maint(4, 0); maint(4, 1); maint(7)
    return commands


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', required=True)
    args = parser.parse_args()
    here = Path(__file__).resolve().parent
    spec = importlib.util.spec_from_file_location('b44_call_auction_independent_oracle', here/'reference_model.py')
    oracle = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(oracle)
    out = Path(args.output); out.mkdir(parents=True, exist_ok=False)
    records = []
    profiles = [('core_n1_p1_q1_t1', 'core', [1, 1, 1, 1]),
                ('core_n9_p12_q8_t5', 'core', [9, 12, 8, 5]),
                ('core_n64_p32_q32_t32', 'core', [64, 32, 32, 32]),
                ('book_l1_p1_q1_t1', 'book', [1, 1, 1, 1]),
                ('book_l8_p32_q32_t8', 'book', [8, 32, 32, 8])]
    for label, kind, parameters in profiles:
        n, p, q, t = parameters
        counts = dict(cases=0, rows=0, snapshots=0, maintenance=0, vector_resets=0)
        lines = []
        if kind == 'core':
            cases = core_cases(n, p, q, t)
            counts.update(cases=len(cases), snapshots=len(cases), rows=sum(len(rows) for rows, ref, tag, requested in cases))
            for rows, ref, tag, requested in cases:
                result = oracle.clear(rows, ref, n, requested)
                lines.append(' '.join(map(str, [requested, ref, tag, result['status'], result['price'], result['matched'], result['buy'], result['sell'], result['imbalance']])))
                lines.extend(' '.join(map(str, row)) for row in rows)
        else:
            cases = book_cases(n, p, q, t, oracle)
            counts.update(cases=len(cases), maintenance=sum(r[0] == 0 for r in cases), snapshots=sum(r[0] == 1 for r in cases), vector_resets=sum(r[0] == 2 for r in cases))
            lines = [' '.join(map(str, row)) for row in cases]
        raw = ('\n'.join([str(len(cases))]+lines)+'\n').encode()
        path = out/(label+'.txt'); path.write_bytes(raw)
        records.append(dict(label=label, kind=kind, parameters=parameters, counts=counts,
                            path=path.name, bytes=len(raw), sha256=hashlib.sha256(raw).hexdigest()))
    summary = dict(schema='anscore-b44-call-auction-vectors-v1', oracle_imports=1,
                   oracle_preparations=1, profiles=records)
    (out/'receipt.json').write_bytes((json.dumps(summary, indent=2)+'\n').encode())
    print('B44_A_PREP_PASS profiles=5 oracle_imports=1 oracle_preparations=1')


if __name__ == '__main__':
    main()
