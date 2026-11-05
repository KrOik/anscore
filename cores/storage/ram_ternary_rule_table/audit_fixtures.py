"""Independent finite fixture/TXT audit. Does not import the generator or HDL."""
from collections import Counter
from hashlib import sha256
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def digest(path):
    return sha256(path.read_bytes()).hexdigest()


def recompute(command, before, n, k):
    op, slot, value, care, action, tag = command
    table = {row[0]: tuple(row[1:]) for row in before}
    out = dict(op=op, tag=tag, status=0, found=0, matches=0, match_count=0,
               slot=0, pattern=0, care=0, action=0)
    if op > 5:
        out['status'] = 3
    elif op in (1, 2, 3) and slot >= n:
        out['status'] = 2
    elif op == 0:
        hits = []
        for i, (pattern, mask, result) in sorted(table.items()):
            accepted = True
            for bit in range(k):
                place = 2**bit
                if (mask // place) % 2 and (value // place) % 2 != (pattern // place) % 2:
                    accepted = False
            if accepted:
                hits.append(i)
        out['matches'] = sum(2**i for i in hits)
        out['match_count'] = len(hits)
        if hits:
            out.update(found=1, slot=hits[0], action=table[hits[0]][2])
        else:
            out['status'] = 1
    elif op == 1:
        pattern = sum(2**b for b in range(k) if (value // 2**b) % 2 and (care // 2**b) % 2)
        table[slot] = pattern, care, action
        out.update(found=1, slot=slot, pattern=pattern, care=care, action=action)
    elif op in (2, 3):
        if slot not in table:
            out['status'] = 4
        elif op == 2:
            del table[slot]
        else:
            pattern, mask, result = table[slot]
            out.update(found=1, slot=slot, pattern=pattern, care=mask, action=result)
    elif op == 4:
        table.clear()
    after = [[i, *table[i]] for i in sorted(table)]
    out['live_count'] = len(after)
    return out, after


def audit_item(item, previous, profile, counter):
    n, k, d, t = profile
    assert item['before'] == previous
    op, slot, value, care, action, tag = item['command']
    assert 0 <= op < 8 and 0 <= slot < 2**32
    assert 0 <= value < 2**k and 0 <= care < 2**k
    assert 0 <= action < 2**d and 0 <= tag < 2**t
    for rows in (item['before'], item['after']):
        assert [r[0] for r in rows] == sorted(set(r[0] for r in rows))
        for i, p, m, a in rows:
            assert 0 <= i < n and 0 <= p < 2**k and 0 <= m < 2**k and 0 <= a < 2**d
            assert all(not ((p // 2**b) % 2) or ((m // 2**b) % 2) for b in range(k))
    expected, after = recompute(item['command'], previous, n, k)
    assert item['expected'] == expected and item['after'] == after
    counter['commands'] += 1
    counter['op_%d' % op] += 1
    counter['status_%d' % expected['status']] += 1
    counter['after_live_rows'] += len(after)
    counter['queries_multi'] += op == 0 and expected['match_count'] > 1
    counter['replacements_full'] += op == 1 and slot < n and len(previous) == n
    return after


def parse_command(lines, item, nxt):
    words = next(lines).split(); assert len(words) == 17
    vals = [int(x, 16 if i in (2, 3, 4, 5, 9, 12, 13, 14) else 10) for i, x in enumerate(words)]
    e = item['expected']
    wanted = item['command'] + [e[x] for x in ('status', 'live_count', 'found', 'matches',
              'match_count', 'slot', 'pattern', 'care', 'action')] + [len(item['before']), len(item['after'])]
    assert vals == wanted
    words = next(lines).split(); assert len(words) == 7
    vals = [int(x, 16 if i >= 3 else 10) for i, x in enumerate(words)]
    assert vals == [int(nxt is not None)] + (nxt if nxt is not None else [0]*6)
    for rows in (item['before'], item['after']):
        for row in rows:
            words = next(lines).split(); assert len(words) == 4
            assert [int(x, 10 if i == 0 else 16) for i, x in enumerate(words)] == row


def audit():
    plan = json.loads((ROOT/'TEST_PLAN.json').read_text())
    assert digest(ROOT/'prepare.py') == plan['preparation_sha256']
    assert len(plan['profiles']) == 6 and len(plan['commands']) == 191
    assert len({c['name'] for c in plan['commands']}) == 191
    assert all(c['timeout_seconds'] == 20 for c in plan['commands'])
    total = Counter(); profiles = []
    for p in plan['profiles']:
        profile = p['S'], p['K'], p['D'], p['T']; counts = Counter(); owners = Counter()
        for kind in ('main', 'resets'):
            for job in p[kind]:
                path = ROOT/job['json']; txt = ROOT/job['text']
                assert digest(path) == job['json_sha256'] and digest(txt) == job['text_sha256']
                data = json.loads(path.read_text()); lines = iter(txt.read_text().splitlines())
                length = len(data['items'] if kind == 'main' else data['units'])
                assert next(lines) == '%d %d' % (kind == 'resets', length)
                if kind == 'main':
                    sequences = [(data['items'], None)]
                else:
                    sequences = []
                    for unit in data['units']:
                        assert next(lines) == '%d %d %d' % (unit['id'], len(unit['setup']), len(unit['fresh']))
                        previous = []
                        for sequence, role in ((unit['setup'], 'setup'), ([unit['owner']], 'owner'), (unit['fresh'], 'fresh')):
                            if role == 'fresh': previous = []
                            for i, item in enumerate(sequence):
                                previous = audit_item(item, previous, profile, owners if role == 'owner' else counts)
                                nxt = sequence[i+1]['command'] if i+1 < len(sequence) else None
                                if role == 'owner': nxt = unit['fresh'][0]['command']
                                parse_command(lines, item, nxt)
                        assert not previous and unit['owner_retired_prefix'] == 0
                        assert len(unit['fresh']) == 2*p['S']+5
                        total['resets'] += 1
                    sequences = []
                for sequence, unused in sequences:
                    previous = []
                    for i, item in enumerate(sequence):
                        previous = audit_item(item, previous, profile, counts)
                        parse_command(lines, item, sequence[i+1]['command'] if i+1 < len(sequence) else None)
                    assert not previous
                assert next(lines, None) is None
        assert counts['commands'] == p['completed_commands']
        assert owners['commands'] == p['reset_count']
        profiles.append(dict(name=p['name'], completed=counts, cancelled_owners=owners['commands']))
        total.update(counts)
    assert total['commands'] == 17675 and total['resets'] == 205
    return dict(schema=1, status='PASS', method='independent per-position binary relation and separate TXT parser',
                plan_sha256=digest(ROOT/'TEST_PLAN.json'), totals=total, profiles=profiles)


if __name__ == '__main__':
    result = audit()
    (ROOT/'fixture_audit.json').write_text(json.dumps(result, sort_keys=True, indent=2)+'\n', encoding='utf-8', newline='\n')
    print(json.dumps(result['totals'], sort_keys=True))
