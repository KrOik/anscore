"""Independent models for the asynchronous Stream FIFO / CDC bridge.

Two layers, matching goal.md's "model must not read DUT output" rule:

- AsyncFifoModel / HandshakeModel are bit-exact register-level models. They
  replicate the RTL pointer, Gray-code, 2-FF synchronizer and reset-toggle
  detection state per clock edge on an integer time grid. Given identical
  stimulus they must reproduce every s_tready/m_tvalid/m_tdata/level cycle
  exactly; any mismatch is an RTL error, not model tolerance. Updates are
  staged and committed after all same-time edges evaluate, reproducing
  Verilog NBA semantics when both domains have a posedge at one timestamp.

- QueueOracle is a transaction-order oracle: accepted pushes append, emitted
  pops must equal the head, occupancy may never exceed capacity, a reset
  quarantine discards the remainder. It knows nothing about pointers or Gray
  codes; it fails any lost/duplicated/reordered/corrupted beat.

Values are opaque integers; no numeric contract applies.
"""
from collections import deque

CLAMP_LEN = 4


def _g2b(g, aw):
    b = (g >> aw & 1) << aw
    for i in range(aw - 1, -1, -1):
        b |= (((b >> (i + 1)) & 1) ^ ((g >> i) & 1)) << i
    return b


def _b2g(b):
    return (b >> 1) ^ b


class AsyncFifoModel:
    """Bit-exact model of async_stream_fifo (WIDTH is irrelevant here)."""

    def __init__(self, depth):
        assert depth >= 2 and depth & (depth - 1) == 0, "DEPTH power of two >=2"
        self.depth = depth
        self.aw = depth.bit_length() - 1
        self.mask = (1 << (self.aw + 1)) - 1
        # level outputs are AW+2 bits wide; pointer differences wrap modulo it
        self.lmask = (1 << (self.aw + 2)) - 1
        self.mem = [None] * depth
        # write domain
        self.wptr_bin = self.wptr_gray = 0
        self.rptr_w = [0, 0]
        self.m_tog_w = [0, 0]
        self.m_tog_seen = 0
        self.clamp_s = 0
        self.s_rst_d = 0
        self.s_rst_tog = 0
        # read domain
        self.rptr_bin = self.rptr_gray = 0
        self.wptr_r = [0, 0]
        self.s_tog_r = [0, 0]
        self.s_tog_seen = 0
        self.clamp_m = 0
        self.m_rst_d = 0
        self.m_rst_tog = 0
        self.m_tvalid = 0
        self.m_tdata = None
        self._p = {}

    def _wr_clamp(self):
        return self.m_tog_w[1] != self.m_tog_seen or self.clamp_s > 0

    def _rd_clamp(self):
        return self.s_tog_r[1] != self.s_tog_seen or self.clamp_m > 0

    def s_edge(self, s_rst_n, s_tvalid, s_tdata):
        """Stage one s_clk posedge; returns (s_tready, push, s_level)."""
        rbin = _g2b(self.rptr_w[1], self.aw)
        full = ((self.wptr_bin - rbin) & self.mask) == self.depth
        clamp = self._wr_clamp()
        sready = int(bool(s_rst_n) and not clamp and not full)
        push = int(bool(s_tvalid) and sready)
        p = self._p
        if not s_rst_n:
            if self.s_rst_d:
                p['s_rst_tog'] = self.s_rst_tog ^ 1
            p.update(s_rst_d=0, wptr_bin=0, wptr_gray=0, rptr_w=[0, 0],
                     m_tog_w=[0, 0], m_tog_seen=0, clamp_s=0)
        else:
            p['s_rst_d'] = 1
            p['m_tog_w'] = [self.m_rst_tog, self.m_tog_w[0]]
            p['rptr_w'] = [self.rptr_gray, self.rptr_w[0]]
            if self.m_tog_w[1] != self.m_tog_seen:
                p['m_tog_seen'] = self.m_tog_w[1]
                p['clamp_s'] = CLAMP_LEN
            elif self.clamp_s > 0:
                p['clamp_s'] = self.clamp_s - 1
            if clamp:
                p['wptr_bin'] = 0
                p['wptr_gray'] = 0
            else:
                p['wptr_bin'] = (self.wptr_bin + push) & self.mask
                p['wptr_gray'] = _b2g(p['wptr_bin'])
            if push:
                p.setdefault('mem', {})[self.wptr_bin & (self.depth - 1)] = \
                    s_tdata
        return sready, push, (self.wptr_bin - rbin) & self.lmask

    def m_edge(self, m_rst_n, m_tready):
        """Stage one m_clk posedge; returns (m_tvalid, m_tdata, pop, m_level)."""
        wbin = _g2b(self.wptr_r[1], self.aw)
        empty = wbin == self.rptr_bin
        slot_free = not self.m_tvalid or m_tready
        clamp = self._rd_clamp()
        fetch = bool(m_rst_n) and not clamp and not empty and slot_free
        pop = int(self.m_tvalid and m_tready and m_rst_n)
        row = (self.m_tvalid, self.m_tdata, pop,
               ((wbin - self.rptr_bin) + self.m_tvalid) & self.lmask)
        p = self._p
        if not m_rst_n:
            if self.m_rst_d:
                p['m_rst_tog'] = self.m_rst_tog ^ 1
            p.update(m_rst_d=0, rptr_bin=0, rptr_gray=0, wptr_r=[0, 0],
                     s_tog_r=[0, 0], s_tog_seen=0, clamp_m=0, m_tvalid=0)
        else:
            p['m_rst_d'] = 1
            p['s_tog_r'] = [self.s_rst_tog, self.s_tog_r[0]]
            p['wptr_r'] = [self.wptr_gray, self.wptr_r[0]]
            if self.s_tog_r[1] != self.s_tog_seen:
                p['s_tog_seen'] = self.s_tog_r[1]
                p['clamp_m'] = CLAMP_LEN
            elif self.clamp_m > 0:
                p['clamp_m'] = self.clamp_m - 1
            if clamp:
                p['rptr_bin'] = 0
                p['rptr_gray'] = 0
                p['m_tvalid'] = 0
            else:
                if fetch:
                    idx = self.rptr_bin & (self.depth - 1)
                    assert self.mem[idx] is not None, "read of unwritten slot"
                    p['m_tdata'] = self.mem[idx]
                    p['m_tvalid'] = 1
                    p['rptr_bin'] = (self.rptr_bin + 1) & self.mask
                    p['rptr_gray'] = _b2g(p['rptr_bin'])
                elif m_tready:
                    p['m_tvalid'] = 0
        return row

    def commit(self):
        """Apply all staged NBA updates (call once all same-time edges ran)."""
        for key, val in self._p.items():
            if key == 'mem':
                self.mem = [val.get(i, self.mem[i]) for i in range(self.depth)]
            else:
                setattr(self, key, val)
        self._p.clear()


class HandshakeModel:
    """Bit-exact model of stream_cdc_handshake."""

    def __init__(self):
        self.req_t = 0
        self.sbuf = None
        self.ack_w = [0, 0]
        self.m_tog_w = [0, 0]
        self.m_tog_seen = 0
        self.clamp_s = 0
        self.s_rst_d = 0
        self.s_rst_tog = 0
        self.ack_t = 0
        self.req_seen = 0
        self.req_m = [0, 0]
        self.s_tog_r = [0, 0]
        self.s_tog_seen = 0
        self.clamp_m = 0
        self.m_rst_d = 0
        self.m_rst_tog = 0
        self.m_tvalid = 0
        self.m_tdata = None
        self._p = {}

    def s_edge(self, s_rst_n, s_tvalid, s_tdata):
        """Stage one s_clk posedge; returns (s_tready, push)."""
        clamp = (self.m_tog_w[1] != self.m_tog_seen) or self.clamp_s > 0
        sready = int(bool(s_rst_n) and not clamp
                     and self.req_t == self.ack_w[1])
        push = int(bool(s_tvalid) and sready)
        p = self._p
        if not s_rst_n:
            if self.s_rst_d:
                p['s_rst_tog'] = self.s_rst_tog ^ 1
            p.update(s_rst_d=0, req_t=0, ack_w=[0, 0], m_tog_w=[0, 0],
                     m_tog_seen=0, clamp_s=0)
        else:
            p['s_rst_d'] = 1
            p['m_tog_w'] = [self.m_rst_tog, self.m_tog_w[0]]
            p['ack_w'] = [self.ack_t, self.ack_w[0]]
            if self.m_tog_w[1] != self.m_tog_seen:
                p['m_tog_seen'] = self.m_tog_w[1]
                p['clamp_s'] = CLAMP_LEN
            elif self.clamp_s > 0:
                p['clamp_s'] = self.clamp_s - 1
            if clamp:
                p['req_t'] = 0
            elif push:
                p['sbuf'] = s_tdata
                p['req_t'] = self.req_t ^ 1
        return sready, push

    def m_edge(self, m_rst_n, m_tready):
        """Stage one m_clk posedge; returns (m_tvalid, m_tdata, pop)."""
        got_req = self.req_m[1] != self.req_seen
        clamp = (self.s_tog_r[1] != self.s_tog_seen) or self.clamp_m > 0
        row = (self.m_tvalid, self.m_tdata,
               int(self.m_tvalid and m_tready and m_rst_n))
        p = self._p
        if not m_rst_n:
            if self.m_rst_d:
                p['m_rst_tog'] = self.m_rst_tog ^ 1
            p.update(m_rst_d=0, req_m=[0, 0], req_seen=0, ack_t=0,
                     s_tog_r=[0, 0], s_tog_seen=0, clamp_m=0, m_tvalid=0)
        else:
            p['m_rst_d'] = 1
            p['s_tog_r'] = [self.s_rst_tog, self.s_tog_r[0]]
            p['req_m'] = [self.req_t, self.req_m[0]]
            if self.s_tog_r[1] != self.s_tog_seen:
                p['s_tog_seen'] = self.s_tog_r[1]
                p['clamp_m'] = CLAMP_LEN
            elif self.clamp_m > 0:
                p['clamp_m'] = self.clamp_m - 1
            if clamp:
                p['req_seen'] = self.req_m[1]
                p['ack_t'] = self.req_m[1]
                p['m_tvalid'] = 0
            elif not self.m_tvalid and got_req:
                assert self.sbuf is not None, "request without payload"
                p['m_tdata'] = self.sbuf
                p['m_tvalid'] = 1
                p['req_seen'] = self.req_m[1]
                p['ack_t'] = self.req_m[1]
            elif self.m_tvalid and m_tready:
                p['m_tvalid'] = 0
        return row

    def commit(self):
        for key, val in self._p.items():
            setattr(self, key, val)
        self._p.clear()


class QueueOracle:
    """Order/capacity oracle; capacity counts accepted-not-yet-emitted beats."""

    def __init__(self, capacity):
        self.capacity = capacity
        self.q = deque()
        self.accepted = 0
        self.emitted = 0
        self.discarded = 0

    def push(self, data, relaxed=False):
        """relaxed=True inside a reset quarantine: the beat may exceed nominal
        capacity because it is guaranteed to be discarded by the peer clamp
        before it can ever be emitted."""
        assert relaxed or len(self.q) < self.capacity, \
            "accepted beat beyond capacity"
        self.q.append(data)
        self.accepted += 1

    def pop(self, data):
        assert self.q, "emitted beat with empty queue"
        assert self.q[0] == data, \
            "data/order mismatch: got %r expected %r" % (data, self.q[0])
        self.q.popleft()
        self.emitted += 1

    def reset_discard(self):
        """Reset quarantine elapsed: all remaining queued beats are dropped."""
        self.discarded += len(self.q)
        self.q.clear()

    def finish(self):
        assert not self.q, \
            "%d accepted beats never emitted/discarded" % len(self.q)
