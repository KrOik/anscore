"""Dispatch to the per-family independent models. Never reads RTL or simulator output."""
from catalog import MODELS, VECTOR_SOURCES, TABLE_SOURCES

MASK = (1 << 32) - 1
STATE_BITS = 256


def signed(x):
    return x if x < 1 << 31 else x - (1 << 32)


def s12(x):
    x &= (1 << 12) - 1
    return x - (1 << 12) if x >> 11 else x


def bytes_of(value, count):
    return value.to_bytes(count, 'little')


def step(name, a, b, c, state=0):
    r, x, f, new_state = MODELS[name](name, a & MASK, b & MASK, c & MASK, state)
    if not 0 <= r <= MASK or not 0 <= x <= MASK or f not in (0, 1):
        raise ValueError(f'{name}: model output out of interface range')
    if new_state >> STATE_BITS:
        raise ValueError(f'{name}: model state wider than the 256-bit RTL state register')
    return r & MASK, x & MASK, int(bool(f)), new_state


def vectors(name, count=320):
    rows = VECTOR_SOURCES[name](name, count)
    for a, b, c in rows:
        if not (0 <= a <= MASK and 0 <= b <= MASK and 0 <= c <= MASK):
            raise ValueError(f'{name}: vector stimulus outside 32-bit interface')
    return rows


def tables(name):
    source = TABLE_SOURCES.get(name)
    return source(name) if source else {}
