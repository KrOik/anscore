"""SPDX-License-Identifier: Apache-2.0. Independent floor/remainder oracle."""
def mean(values):
    total = sum(values)
    q, r = divmod(total, len(values))
    return q + int(2*r > len(values) or (2*r == len(values) and q % 2)), total, int(r != 0)

def classify(means):
    raw = [means[0]+means[1], means[2]-means[3]]
    return [(max(-128,min(127,v)), int(v < -128 or v > 127)) for v in raw]
