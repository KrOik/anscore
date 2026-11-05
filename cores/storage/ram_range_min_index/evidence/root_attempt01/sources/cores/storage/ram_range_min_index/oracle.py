"""Independent dense-list reference. Evaluated only during future approved preparation."""
from __future__ import annotations

def evaluate(commands, buckets):
    values = [0] * buckets
    rows = []
    for name, op, lo, hi, value, tag in commands:
        status = index = result = 0
        if op == 3:
            status = 2
        elif op == 2:
            values = [0] * buckets
        elif not (0 <= lo <= hi < buckets):
            status = 1
        elif op == 0:
            for i in range(lo, hi + 1):
                values[i] = value
            index, result = lo, value
        else:
            result = min(values[lo:hi + 1])
            index = next(i for i in range(lo, hi + 1) if values[i] == result)
        rows.append(dict(name=name, command=[op,lo,hi,value,tag],
                         response=[op,status,index,result,tag]))
    return rows
