"""Independent array-mathematics oracle and deterministic finite vectors.

This file has not executed during authoring. It imports no project module and
uses no RTL address/state schedule. Runtime output is an append-only root gate.
"""
from __future__ import annotations
import argparse
from decimal import Decimal, localcontext, ROUND_HALF_EVEN
from functools import lru_cache
import hashlib
import json
from pathlib import Path
import random

PI = Decimal('3.1415926535897932384626433832795028841971693993751058209749445923078164062862089986280348253421170679')


def rne(value: int, shift: int, width: int) -> tuple[int, bool, bool]:
    """Sign/magnitude nearest-even, then signed saturation; no floor-bit model."""
    magnitude = abs(value)
    q, rem = divmod(magnitude, 1 << shift)
    twice = rem * 2
    if twice > (1 << shift) or (twice == (1 << shift) and q % 2):
        q += 1
    rounded = -q if value < 0 else q
    lo, hi = -(1 << (width - 1)), (1 << (width - 1)) - 1
    clipped = min(hi, max(lo, rounded))
    overflow = rounded != clipped
    return clipped, overflow, bool(rem) or overflow


@lru_cache(maxsize=None)
def root(n: int, k: int, inverse: bool) -> tuple[int, int]:
    """Direct high-precision sin/cos, independent of RTL's folded case ROM."""
    with localcontext() as context:
        context.prec = 85
        angle = 2 * PI * Decimal(k) / Decimal(n)
        square = angle * angle
        cosine = term_c = Decimal(1)
        sine = term_s = angle
        for j in range(1, 180):
            term_c *= -square / Decimal((2 * j - 1) * (2 * j))
            term_s *= -square / Decimal((2 * j) * (2 * j + 1))
            cosine += term_c
            sine += term_s
            if abs(term_c) < Decimal('1e-80') and abs(term_s) < Decimal('1e-80'):
                break
        re = int((65536 * cosine).to_integral_value(rounding=ROUND_HALF_EVEN))
        im = int((65536 * sine).to_integral_value(rounding=ROUND_HALF_EVEN))
        return re, im if inverse else -im


def transform(values: list[tuple[int, int]], width: int, inverse: bool,
              scale_mask: int) -> tuple[list[tuple[int, int]], bool, bool]:
    """Recursive even/odd Cooley-Tukey; natural arrays and no RTL FSM mapping."""
    roots: dict[tuple[int, int], tuple[int, int]] = {}

    def recurse(data: list[tuple[int, int]]) -> tuple[list[tuple[int, int]], bool, bool]:
        n = len(data)
        if n == 1:
            return data[:], False, False
        even, eo, ei = recurse(data[::2])
        odd, oo, oi = recurse(data[1::2])
        result = [(0, 0)] * n
        overflow, inexact = eo or oo, ei or oi
        stage = n.bit_length() - 2
        shift = 16 + ((scale_mask >> stage) & 1)
        for k, ((ar, ai), (br, bi)) in enumerate(zip(even, odd)):
            wr, wi = roots.setdefault((n, k), root(n, k, inverse))
            tr, ti = br * wr - bi * wi, br * wi + bi * wr
            for index, sign in ((k, 1), (k + n // 2, -1)):
                re, ro, ri = rne(ar * 65536 + sign * tr, shift, width)
                im, io, ii = rne(ai * 65536 + sign * ti, shift, width)
                result[index] = re, im
                overflow |= ro or io
                inexact |= ri or ii
        return result, overflow, inexact

    return recurse(values)


class Filter:
    def __init__(self, log_n: int, width: int):
        self.n, self.width = 1 << log_n, width
        self.log_n = log_n
        self.taps: list[tuple[int, int]] | None = None
        self.h: list[tuple[int, int]] = []
        self.frac = 0
        self.co = self.ci = False
        self.history: list[tuple[int, int]] = []
        self.active = False

    def reset(self) -> None:
        self.taps = None
        self.h = []
        self.history = []
        self.active = False

    def publish(self, taps: list[tuple[int, int]], frac: int) -> tuple[bool, bool]:
        self.taps, self.frac = taps[:], frac
        self.h, self.co, self.ci = transform(taps + [(0, 0)] * (self.n - len(taps)),
                                            self.width, False, 0)
        self.history = [(0, 0)] * (len(taps) - 1)
        self.active = False
        return self.co, self.ci

    def run(self, values: list[tuple[int, int]], end: bool, restart: bool
            ) -> list[tuple[tuple[int, int], bool, bool]]:
        assert self.taps is not None
        m, n = len(self.taps), self.n
        b = n - m + 1
        if restart or not self.active:
            self.history = [(0, 0)] * (m - 1)
        if end and not values and (restart or not self.active or m == 1):
            self.history = [(0, 0)] * (m - 1)
            self.active = False
            return []
        wanted = len(values) + m - 1 if end else b
        out: list[tuple[tuple[int, int], bool, bool]] = []
        co, ci = self.co, self.ci
        fresh = values + [(0, 0)] * (b - len(values))
        while len(out) < wanted:
            block = self.history + fresh
            spectrum, fo, fi = transform(block, self.width, False, 0)
            product = []
            co, ci = co or fo, ci or fi
            for (xr, xi), (hr, hi) in zip(spectrum, self.h):
                re, ro, ri = rne(xr * hr - xi * hi, self.frac, self.width)
                im, io, ii = rne(xr * hi + xi * hr, self.frac, self.width)
                product.append((re, im))
                co, ci = co or ro or io, ci or ri or ii
            result, io, ii = transform(product, self.width, True, n - 1)
            co, ci = co or io, ci or ii
            for value in result[m - 1:]:
                if len(out) == wanted:
                    break
                out.append((value, co, ci))
            self.history = block[b:] if m > 1 else []
            fresh = [(0, 0)] * b
        self.active = not end
        if end:
            self.history = [(0, 0)] * (m - 1)
        return out


class Vectors:
    def __init__(self, log_n: int, width: int, tag_w: int, real: bool):
        self.f = Filter(log_n, width)
        self.width, self.tag_mask, self.real = width, (1 << tag_w) - 1, real
        self.lines: list[str] = []
        self.counts = dict(configs=0, commands=0, taps=0, samples=0, outputs=0,
                           markers=0, resets=0, sanity_cases=0, sanity_samples=0)
        self.tag = (1 << (tag_w - 1)) if tag_w > 1 else 0

    def next_tag(self) -> int:
        self.tag = (self.tag + 1) & self.tag_mask
        return self.tag

    def add(self, *fields: object) -> None:
        self.lines.append(' '.join(str(int(x)) for x in fields))

    def reset(self) -> None:
        self.add(9)
        self.f.reset()
        self.counts['resets'] += 1

    def config(self, taps: list[tuple[int, int]], frac: int, *,
               count: int | None = None, damage: str = '') -> None:
        n = self.f.n
        count = len(taps) if count is None else count
        tag = self.next_tag()
        self.add(1, count, frac, tag)
        received, status, ov, ix = 0, 0, False, False
        if not 1 <= count <= n:
            status = 1
        elif not 0 <= frac < self.width:
            status = 2
        else:
            for i, (re, im) in enumerate(taps):
                last = i == count - 1
                invalid = damage == 'invalid' and i == 0
                if damage == 'early' and i == 0:
                    last = True
                if damage == 'missing' and i == count - 1:
                    last = False
                self.add(2, re, im, last, invalid)
                received += 1
                if invalid or last != (i == count - 1):
                    status = 3 if invalid else 4 if last else 5
                    break
            if status == 0:
                assert received == count
                ov, ix = self.f.publish(taps, frac)
        self.add(3, status, count, frac, received, ov, ix, tag)
        self.counts['configs'] += 1
        self.counts['taps'] += received

    def command(self, values: list[tuple[int, int]], *, end: bool = False,
                restart: bool = False, count: int | None = None,
                damage: str = '') -> list[tuple[int, int]]:
        count = len(values) if count is None else count
        tag = self.next_tag()
        self.add(4, count, end, restart, tag)
        status, received = 0, 0
        output: list[tuple[tuple[int, int], bool, bool]] = []
        if self.f.taps is None:
            status = 2
        else:
            b = self.f.n - len(self.f.taps) + 1
            if (not end and count != b) or (end and not 0 <= count <= b):
                status = 3
            else:
                for i, (re, im) in enumerate(values):
                    last = i == count - 1
                    invalid = damage == 'invalid' and i == 0
                    if damage == 'early' and i == 0:
                        last = True
                    if damage == 'missing' and i == count - 1:
                        last = False
                    self.add(5, re, im, last, invalid)
                    received += 1
                    if invalid or last != (i == count - 1):
                        status = 4 if invalid else 5 if last else 6
                        self.f.active = False
                        self.f.history = [(0, 0)] * (len(self.f.taps) - 1)
                        break
                if status == 0:
                    assert received == count
                    output = self.f.run(values, end, restart)
                    if not output:
                        status = 1
        if status:
            self.add(6, 0, 0, 0, 1, status != 1, status, 0, 0, 0, count, 0, received, tag)
            self.counts['markers'] += 1
        else:
            for i, (value, ov, ix) in enumerate(output):
                self.add(6, *value, 1, i == len(output) - 1, 0, 0, ov, ix,
                         i, count, len(output), received, tag)
        self.counts['commands'] += 1
        self.counts['samples'] += received
        self.counts['outputs'] += len(output)
        return [item[0] for item in output]


def ideal(values: list[tuple[int, int]], taps: list[tuple[int, int]], frac: int
          ) -> list[tuple[int, int]]:
    """Separate exact time-domain convolution for selected representable sanity."""
    out = []
    for t in range(len(values) + len(taps) - 1):
        re = im = 0
        for j, (hr, hi) in enumerate(taps):
            if 0 <= t - j < len(values):
                xr, xi = values[t - j]
                re += xr * hr - xi * hi
                im += xr * hi + xi * hr
        assert re % (1 << frac) == 0 and im % (1 << frac) == 0
        out.append((re // (1 << frac), im // (1 << frac)))
    return out


def build(log_n: int, width: int, tag_w: int, seed: int, real: bool) -> Vectors:
    v, rng = Vectors(log_n, width, tag_w, real), random.Random(seed)
    n = 1 << log_n
    def z(re: int, im: int = 0) -> tuple[int, int]:
        return re, 0 if real else im
    def noise(length: int, bound: int = 5) -> list[tuple[int, int]]:
        return [z(rng.randint(-bound, bound), rng.randint(-bound, bound)) for _ in range(length)]
    v.command([], count=n)
    v.config([], 0, count=0)
    v.config([], 0, count=n + 1)
    v.config([], 0, count=0xffffffff)
    v.config([z(1)], width)
    v.config([z(1)], 0xffffffff)
    for damage in ('invalid', 'early', 'missing'):
        v.config([z(1), z(-1)], 0, damage=damage)
    # Independent exact known responses: zero, unity, sign, gain, delay and
    # a two-tap moving sum on an impulse. No floating-point tolerance is used.
    impulse = [z(16)] + [z(0)] * (n - 1)
    half_delay = [z(0)] * (n // 2) + [z(1)]
    half_sum = [z(1)] + [z(0)] * (n // 2 - 1) + [z(1)]
    half_impulse = [z(16)] + [z(0)] * (n // 2 - 1)
    # Half-frame roots are exactly +/-1: these delay/sum checks do not assume
    # arbitrary irrational roots or the round-trip FFT are exact on integers.
    known = [([z(0)], noise(n)), ([z(1)], impulse), ([z(-1)], impulse),
             ([z(2)], impulse), (half_delay, half_impulse), (half_sum, half_impulse)]
    if n <= (1 << (width - 1)) - 1:
        known.append(([z(1)], [z(1)] * n))
    for taps, values in known:
        v.config(taps, 0)
        observed = v.command(values, end=True)
        expected = ideal(values, taps, 0)
        assert observed == expected, ('known time response', log_n, width, taps, observed, expected)
        v.counts['sanity_cases'] += 1
        v.counts['sanity_samples'] += len(expected)
    # Complex unit multiplication is also an exact known time-domain response.
    if not real:
        taps, values = [z(0, 1)], impulse
        v.config(taps, 0)
        observed = v.command(values, end=True)
        assert observed == ideal(values, taps, 0)
        v.counts['sanity_cases'] += 1
        v.counts['sanity_samples'] += len(values)
    # Fractional coefficient RNE ties, negative extrema, positive clipping.
    lo, hi = -(1 << (width - 1)), (1 << (width - 1)) - 1
    for coefficient, fractional in ((1, 1), (-1, 1), (hi, width - 1), (lo, 0)):
        v.config([z(coefficient)], fractional)
        v.command([z((lo, hi, -3, -1, 1, 3)[i % 6]) for i in range(n)], end=True)
    # Persistent blocks, non-power-of-two taps, short final, zero-input tail,
    # restart, failed reconfiguration preservation and accepted damage recovery.
    for m in sorted({1, min(3, n), n // 2 + 1, n}):
        b = n - m + 1
        taps = noise(m, 2)
        v.config(taps, 1)
        v.command([], end=True)
        v.command(noise(b))
        v.config([z(1), z(2)], 0, damage='invalid')
        v.command(noise(b))
        if n > 64 and m == n:
            # Maximum extent/history is covered; a whole N-block tail here is
            # deliberately outside this 20-second child's prospective scope.
            # Complete M=N flushes run at N2/N8/N64, not inferred at N256.
            v.command(noise(b), restart=True)
            v.command([], count=0xffffffff)
            v.command([], end=True, count=0xffffffff)
            for damage in ('invalid', 'missing'):
                v.command(noise(b), damage=damage)
                v.command(noise(b))
            continue
        v.command([], end=True)
        v.command(noise(b), restart=True)
        v.command(noise(max(1, b // 2)), end=True)
        v.command([], end=True)
        v.command([], count=b + 1)
        v.command([], end=True, count=b + 1)
        v.command([], count=0xffffffff)
        v.command([], end=True, count=0xffffffff)
        for damage in ('invalid', 'missing'):
            v.command(noise(b), damage=damage)
            v.command(noise(b), end=True)
        if b > 1:
            v.command(noise(b), damage='early')
            v.command(noise(b), end=True)
    v.reset()
    v.command([], count=n)
    v.config([z(1)], 0)
    v.command(noise(n), end=True, restart=True)
    v.add(0)
    return v


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--log-n', type=int, required=True)
    parser.add_argument('--width', type=int, required=True)
    parser.add_argument('--tag-w', type=int, required=True)
    parser.add_argument('--seed', type=int, required=True)
    parser.add_argument('--real', action='store_true')
    args = parser.parse_args()
    if not 1 <= args.log_n <= 8 or not 8 <= args.width <= 24 or not 1 <= args.tag_w <= 32:
        raise ValueError('unsupported finite profile')
    result = build(args.log_n, args.width, args.tag_w, args.seed, args.real)
    args.output.mkdir(parents=True, exist_ok=False)
    payload = ('\n'.join(result.lines) + '\n').encode('ascii')
    (args.output / 'vectors.txt').write_bytes(payload)
    manifest = dict(schema='fft-overlap-save-vectors-v1', log_n=args.log_n,
                    width=args.width, tag_w=args.tag_w, seed=args.seed, real=args.real,
                    counts=result.counts, vector_bytes=len(payload),
                    vector_sha256=hashlib.sha256(payload).hexdigest())
    (args.output / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    print('PASS_VECTOR_PREPARATION', json.dumps(result.counts, sort_keys=True))


if __name__ == '__main__':
    main()
