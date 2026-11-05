"""Packet/visit DRR reference, independent of RTL clock states and RAM latency."""
from collections import deque


class DRR:
    def __init__(self, profile):
        self.p = profile
        self.limit = (1 << profile['C']) - 1
        self.commands = []
        self.outputs = []
        self.iterations = 0
        self.round_certificates = []
        self.reset()

    def reset(self):
        f = self.p['F']
        self.queues = [deque() for _ in range(f)]
        self.q = [self.p['Q']] * f
        self.d = [0] * f
        self.visits = [0] * f
        self.served = [0] * f
        self.cursor = 0
        self.open = False
        self.pending = None

    def command(self, op, flow, cost, data, tag):
        valid = 0 <= flow < self.p['F']
        snapshot = [len(self.queues[flow]), self.q[flow], self.d[flow]] if valid else [0, 0, 0]
        status = 0
        if op == 3:
            status = 1
        elif not valid:
            status = 2
        elif op == 0:
            if cost == 0:
                status = 3
            elif len(self.queues[flow]) == self.p['N']:
                status = 4
            else:
                self.queues[flow].append((flow, cost, data, tag))
        elif op == 1:
            if cost == 0:
                status = 6
            elif self.queues[flow]:
                status = 5
            else:
                self.q[flow] = cost
                self.d[flow] = 0
        assert all(0 <= x < 1 << (self.p['C']+1) for x in self.d)
        result = [flow, tag, status] + snapshot
        self.commands.append(result)
        return result

    def peek(self):
        if self.pending is not None:
            return self.pending
        assert any(self.queues), 'an empty system has no next packet'
        while True:
            self.iterations += 1
            i = self.cursor
            queue = self.queues[i]
            if not queue:
                self.d[i] = 0
                self.cursor = (i+1) % self.p['F']
                self.open = False
                continue
            if not self.open:
                assert self.d[i] < queue[0][1], 'visit-entry residual invariant'
                self.d[i] += self.q[i]
                self.visits[i] += 1
                self.open = True
            assert 0 <= self.d[i] <= 2*self.limit-1
            if queue[0][1] <= self.d[i]:
                self.pending = queue[0]
                return self.pending
            # An ended, backlogged visit retains strictly less than head cost.
            assert self.d[i] < queue[0][1] <= self.limit
            self.cursor = (i+1) % self.p['F']
            self.open = False

    def pop(self):
        packet = self.peek()
        i, cost, _, _ = packet
        assert self.queues[i].popleft() == packet
        self.d[i] -= cost
        self.served[i] += cost
        self.outputs.append(list(packet))
        self.pending = None
        if not self.queues[i]:
            self.d[i] = 0
            self.cursor = (i+1) % self.p['F']
            self.open = False
        return packet

    def fairness_certificate(self):
        """A snapshot in an explicitly continuous-backlog, fixed-Q window."""
        assert all(self.queues)
        packet_bound = min(self.limit, 31)
        assert all(all(p[1] <= packet_bound for p in queue) for queue in self.queues)
        for i in range(self.p['F']):
            assert self.served[i] + self.d[i] == self.visits[i]*self.q[i]
            assert self.d[i] <= packet_bound+self.q[i]-1
        pairs = []
        for i in range(self.p['F']):
            for j in range(i):
                # Visits differ by at most one for this cyclic active set.
                assert abs(self.visits[i]-self.visits[j]) <= 1
                lhs = abs(self.served[i]*self.q[j]-self.served[j]*self.q[i])
                # Exact credit conservation plus the proven finite D bound.
                bound = (self.q[i]*self.q[j] + (packet_bound+self.q[i]-1)*self.q[j]
                         + (packet_bound+self.q[j]-1)*self.q[i])
                assert lhs <= bound
                pairs.append([i, j, lhs, bound])
        result = dict(packet_cost_bound=packet_bound, visits=self.visits[:], quantum=self.q[:],
                      served=self.served[:], deficit=self.d[:], pair_checks=pairs)
        self.round_certificates.append(result)
        return result
