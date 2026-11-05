"""One authorized deterministic preparation; does not invoke HDL or network."""
from hashlib import sha256
import json
from pathlib import Path
from oracle import DRR

ROOT = Path(__file__).resolve().parent


def digest(raw):
    return sha256(raw).hexdigest()


def write(path, obj):
    path.write_text(json.dumps(obj, indent=2, sort_keys=True)+'\n', encoding='utf-8', newline='\n')


class Scenario:
    def __init__(self, p, kind):
        self.p = p
        self.kind = kind
        self.model = DRR(p)
        self.actions = []
        self.number = 0
        self.resets = 0
        self.selected = 0

    def action(self, kind, *fields):
        assert len(fields) <= 11
        self.actions.append([kind, *fields] + [0]*(11-len(fields)))

    def command(self, op, flow, cost=0, data=0, tag=None, flags=0):
        if tag is None:
            tag = (len(self.model.commands)*7+3) & ((1 << self.p['T'])-1)
        result = self.model.command(op, flow, cost, data, tag)
        self.action(0, op, flow, cost, data, tag, *result[2:], flags)
        if flags & 1:
            self.model.pop()
        return result[2]

    def enqueue(self, flow, cost):
        self.number += 1
        data = ((self.number*0x9E3779B97F4A7C15) ^ (flow << 11)) & ((1 << self.p['D'])-1)
        tag = (self.number*13+flow) & ((1 << self.p['T'])-1)
        assert self.command(0, flow, cost, data, tag) == 0

    def expect(self):
        self.action(2, *self.model.peek())
        self.selected += 1

    def pop(self):
        self.action(3)
        self.model.pop()

    def drain(self):
        self.action(1, 1)
        while any(self.model.queues):
            self.expect()
            self.pop()
        self.action(1, 0)

    def reset(self):
        self.action(4)
        self.resets += 1
        self.model.reset()

    def main(self):
        p, m = self.p, self.model
        # All admission/configuration checks occur while paused or at an
        # already held output, so oracle events do not depend on clock latency.
        self.reset()
        self.command(3, 0)
        self.command(0, 0xFFFFFFFF, 1)
        self.command(0, 0, 0)
        self.command(1, 0, 0)
        for f in range(p['F']):
            self.command(1, f, min(m.limit, p['Q']*(f+1)))
            for j in range(p['N']):
                cost = m.limit if j == 0 else [1, max(1, min(m.limit, p['Q']//2))][j % 2]
                self.enqueue(f, cost)
        assert self.command(0, 0, 1) == 4
        assert self.command(1, 0, 1) == 5
        self.action(1, 1)
        self.expect()
        f = m.pending[0]
        # Old-count FULL is retained even when that edge also retires a head.
        assert self.command(0, f, 1, flags=1) == 4
        # Pause after retirement, then replace the vacated tail. A depth-one
        # queue has become empty; deeper queues remain in their current visit.
        self.action(1, 0)
        self.enqueue(f, 1)
        self.drain()
        for f in range(p['F']):
            assert self.command(2, f) == 0
            assert m.d[f] == 0
        # Large Q, tiny descriptors: multiple outputs must share one visit.
        for f in range(p['F']):
            self.command(1, f, m.limit)
            for j in range(min(p['N'], 3)):
                self.enqueue(f, m.limit if j == 1 else 1)
        self.action(1, 1)
        self.expect()
        f = m.pending[0]
        self.action(1, 0)  # run=0 must preserve, and still allow retirement.
        self.command(2, f)
        self.pop()
        self.action(1, 1)
        while any(m.queues):
            self.expect()
            # With spare room, enqueue before the last pop tests continuous
            # visit ownership across simultaneous queue growth/retirement.
            self.pop()
        self.action(1, 0)
        # Last-pop + accepted same-flow enqueue on precisely the same edge.
        self.enqueue(0, 1)
        self.action(1, 1)
        self.expect()
        if p['N'] > 1:
            self.command(0, 0, 1, data=1, tag=1, flags=1)
            self.expect()
            self.pop()
        else:
            self.pop()
        self.action(1, 0)
        # Reset discards a held output and a distinct held command response.
        self.enqueue(0, m.limit)
        self.action(1, 1)
        self.expect()
        self.reset()
        self.command(0, 0, 1, data=1, tag=1, flags=2)
        self.reset()
        self.enqueue(p['F']-1, 1)
        self.drain()
        self.command(2, 0)

    def fairness(self):
        p, m = self.p, self.model
        assert p['N'] >= 3
        self.reset()
        for f in range(p['F']):
            self.command(1, f, min(m.limit, 3+2*f))
            for j in range(p['N']-1):
                self.enqueue(f, 1+((f*7+j*11) % min(m.limit, 31)))
        self.action(1, 1)
        for k in range(512):
            self.expect()
            f = m.pending[0]
            # Before every pop, another descriptor is accepted into the one
            # spare slot. Every flow remains nonempty over this entire window.
            self.enqueue(f, 1+((k*13+f*7) % min(m.limit, 31)))
            self.pop()
            if k % 32 == 31:
                m.fairness_certificate()
        self.reset()

    def finish(self):
        # Every abstract examination costs at most VISIT+READ+CHECK. Eight
        # clocks per examination covers transition alignment; every scripted
        # action has <=12 clocks of explicit drive/hold/ACK/reset overhead.
        bound = 128 + 12*len(self.actions) + 8*self.model.iterations
        ceiling = 100000 if self.p['name'] == 'max' else 40000
        assert bound <= ceiling, ('frozen cycle ceiling', self.p['name'], bound, ceiling)
        self.action(5, len(self.model.commands), len(self.model.outputs), self.resets, self.selected)
        return dict(schema=1, profile=self.p, kind=self.kind, actions=self.actions,
                    expected_commands=self.model.commands, expected_outputs=self.model.outputs,
                    resets=self.resets, selections=self.selected,
                    abstract_examinations=self.model.iterations, cycle_bound=bound,
                    cycle_ceiling=ceiling, fairness_certificates=self.model.round_certificates)


def main():
    assert not (ROOT/'fixtures').exists() and not (ROOT/'fixture_audit.json').exists(), 'one preparation only'
    plan = json.loads((ROOT/'TEST_PLAN.json').read_bytes())
    assert plan['hdl_children'] == 24 and len(plan['commands']) == 24
    (ROOT/'fixtures').mkdir()
    results = []
    for p in plan['profiles']:
        for kind in p['cases']:
            s = Scenario(p, kind)
            getattr(s, kind)()
            result = s.finish()
            name = p['name']+'_'+kind
            jp = ROOT/'fixtures'/(name+'.json')
            tp = ROOT/'fixtures'/(name+'.txt')
            write(jp, result)
            tp.write_text(''.join(' '.join(format(v, 'x') for v in row)+'\n' for row in result['actions']), encoding='ascii', newline='\n')
            results.append(dict(name=name, json=jp.relative_to(ROOT).as_posix(), text=tp.relative_to(ROOT).as_posix(),
                                json_sha256=digest(jp.read_bytes()), text_sha256=digest(tp.read_bytes()),
                                cycle_bound=result['cycle_bound'], actions=len(result['actions']),
                                commands=len(result['expected_commands']), outputs=len(result['expected_outputs']),
                                resets=result['resets'], selections=result['selections'],
                                abstract_examinations=result['abstract_examinations'],
                                fairness_certificates=len(result['fairness_certificates'])))
    write(ROOT/'fixture_audit.json', dict(schema=1, status='PASS', mode='pure-python-no-HDL',
          baseline=plan['baseline'], plan_sha256=digest((ROOT/'TEST_PLAN.json').read_bytes()),
          preparation_sha256=digest((ROOT/'prepare.py').read_bytes()),
          oracle_sha256=digest((ROOT/'oracle.py').read_bytes()), jobs=results,
          child_processes=0, numerical_weakening=False, repeated_preparation=False))
    print(json.dumps(dict(status='PREPARED', jobs=len(results), hdl_children=0,
          fixture_audit_sha256=digest((ROOT/'fixture_audit.json').read_bytes()))))


if __name__ == '__main__':
    main()
