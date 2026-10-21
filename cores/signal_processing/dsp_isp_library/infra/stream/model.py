"""Lossless transaction queue model; no pointers or RAM representation.

Values are opaque integers, so floating-point arithmetic is not applicable.
The queue entry's earliest output cycle represents synchronous read latency.
"""
from collections import deque

class StreamModel:
    def __init__(self, depth=None):
        self.depth=depth
        self.q=deque()
        self.cycle=0

    def outputs(self, ready):
        valid=bool(self.q and self.q[0][0] <= self.cycle)
        # FIFO output slot holds one eligible head outside RAM.
        accept=(not valid or ready) if self.depth is None else len(self.q)-int(valid)<self.depth
        return int(accept),int(valid),self.q[0][1] if valid else None

    def step(self, reset_n, valid, beat, ready):
        accept,outvalid,outbeat=self.outputs(ready)
        if not reset_n:
            self.q.clear()
        else:
            if outvalid and ready:
                self.q.popleft()
            if valid and accept:
                self.q.append((self.cycle+(1 if self.depth is None else 2),beat))
        self.cycle+=1
        return accept,outvalid,outbeat

def verify_transactions(stimuli, rows):
    """Independent transaction-only oracle also checks stalled output stability."""
    q=deque(); stalled=None; accepted=emitted=0
    for st,row in zip(stimuli,rows,strict=True):
        rst,sv,data,user,last,mr=st
        sr,mv,md,mu,ml=row
        if not rst:
            q.clear();stalled=None;continue
        if stalled is not None:
            assert mv and (md,mu,ml)==stalled,"stalled output changed"
        if mv:
            assert q and q[0]==(md,mu,ml),"data/order/sideband mismatch"
        if mv and mr:
            q.popleft();emitted+=1
        if sv and sr:
            q.append((data,user,last));accepted+=1
        stalled=(md,mu,ml) if mv and not mr else None
    assert not q,"missing output transactions"
    return accepted,emitted
