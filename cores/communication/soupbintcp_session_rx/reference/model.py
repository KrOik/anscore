"""Whole-packet SoupBinTCP server oracle; no clock, FIFO, or RTL state machine."""
import re

MAX64 = (1 << 64) - 1


def initial():
    return dict(session=0, next=0, logged=0, closed=0, fault=0, exhausted=0)


def receive(wire, state, depth, tag):
    assert not state['closed'] and not state['fault']
    length = int.from_bytes(wire[:2], 'big')
    assert len(wire) == length + 2
    kind = wire[2] if length else 0
    body = wire[3:]
    status = 0
    sequence = reason = 0
    payload = b''
    after = dict(state)
    if length == 0:
        status = 2
    elif kind not in b'+AJSHZ':
        status = 1
    elif kind in b'AJHZ' and length != {65:31, 74:2, 72:1, 90:1}[kind]:
        status = 2
    elif kind == ord('S') and length > depth:
        status = 3
    elif kind in b'AJ' and state['logged']:
        status = 5
    elif kind in b'SHZ' and not state['logged']:
        status = 5
    elif kind == ord('S') and state['exhausted']:
        status = 6
    elif kind == ord('A'):
        text = body[10:]
        number = int(text) if re.fullmatch(rb' *[0-9]+', text) else 0
        if not 1 <= number <= MAX64:
            status = 4
        else:
            after.update(session=int.from_bytes(body[:10], 'big'), next=number, logged=1, exhausted=0)
    elif kind == ord('J'):
        if body not in (b'A', b'S'):
            status = 4
        else:
            reason = body[0]
            after.update(logged=0, closed=1)
    elif kind == ord('Z'):
        after.update(logged=0, closed=1)
    elif kind == ord('S'):
        sequence = state['next']
        payload = body
        if sequence == MAX64:
            after['exhausted'] = 1
        else:
            after['next'] = sequence + 1
    if status:
        after['fault'] = 1
    result = dict(status=status, type=kind, length=length, sequence=sequence,
                  reason=reason, tag=tag, payload=payload, **after)
    return result, after
