"""New-package vector preparation only; never imports project code.

The fit oracle solves the full three-column design by Fraction Gaussian
elimination. It does not use the RTL's centered 2x2 Cramer's schedule.
The unchanged CORDIC dependency has a separately identified bit model, with
fresh Decimal constants and an ideal-trigonometric <=1 LSB check per phase.
"""
from decimal import Decimal, localcontext, ROUND_HALF_UP
from fractions import Fraction
from pathlib import Path
import argparse
import hashlib
import json
import random

Q = 1 << 16
PROFILES = {"minimum": (3, 1), "typical": (16, 8),
            "maximum": (256, 32), "example": (256, 8)}


def atan_series(x):
    term = x
    total = x
    for k in range(1, 400):
        term *= -x*x
        addition = term / (2*k+1)
        total += addition
        if abs(addition) < Decimal("1e-105"):
            return total
    raise AssertionError("bounded atan preparation did not converge")


def constants():
    with localcontext() as ctx:
        ctx.prec = 120
        pi = 16*atan_series(Decimal(1)/5)-4*atan_series(Decimal(1)/239)
        scale = Decimal(1 << 62)
        angles = []
        gain = Decimal(1)
        for k in range(20):
            theta = pi/4 if k == 0 else atan_series(Decimal(2)**(-k))
            angles.append(int((theta/(2*pi)*scale).to_integral_value(rounding=ROUND_HALF_UP)))
            gain *= (1+Decimal(2)**(-2*k)).sqrt()
        inverse = int((scale/gain).to_integral_value(rounding=ROUND_HALF_UP))
        return pi, angles, inverse


PI, ANGLES, INVERSE = constants()


def signed(value, width):
    value &= (1 << width)-1
    return value-(1 << width) if value >> (width-1) else value


def rne_shift(value, shift):
    quotient, remainder = divmod(value, 1 << shift)
    half = 1 << (shift-1)
    return quotient + int(remainder > half or (remainder == half and quotient & 1))


def ideal_trig(phase):
    with localcontext() as ctx:
        ctx.prec = 110
        angle = 2*PI*Decimal(phase)/Decimal(1 << 24)
        if angle > PI:
            angle -= 2*PI
        sin_term = angle
        cos_term = Decimal(1)
        sine, cosine = sin_term, cos_term
        for k in range(1, 100):
            sin_term *= -angle*angle/((2*k)*(2*k+1))
            cos_term *= -angle*angle/((2*k-1)*(2*k))
            sine += sin_term
            cosine += cos_term
        return cosine, sine


def basis(phase):
    """Dependency bit contract; not a new independent proof of CORDIC RTL."""
    phase &= (1 << 24)-1
    x, y = (INVERSE+(1 << 37)) >> 38, 0
    z = (phase & ((1 << 22)-1)) << 8
    for k, constant in enumerate(ANGLES):
        angle = (constant+(1 << 29)) >> 30
        if z < 0:
            x, y, z = signed(x+(y >> k), 26), signed(y-(x >> k), 26), signed(z+angle, 32)
        else:
            x, y, z = signed(x-(y >> k), 26), signed(y+(x >> k), 26), signed(z-angle, 32)
    x, y = rne_shift(x, 8), rne_shift(y, 8)
    quadrant = phase >> 22
    c, s = ((x, y), (-y, x), (-x, -y), (y, -x))[quadrant]
    ideal_c, ideal_s = ideal_trig(phase)
    assert abs(Decimal(c)-ideal_c*Q) <= 1
    assert abs(Decimal(s)-ideal_s*Q) <= 1
    assert abs(c) <= Q+1 and abs(s) <= Q+1
    return c, s


def determinant3(matrix):
    """Independent 3x3 cofactor identity, not centered 2x2 determinant."""
    a, b, c = matrix[0]
    d, e, f = matrix[1]
    g, h, i = matrix[2]
    return a*(e*i-f*h)-b*(d*i-f*g)+c*(d*h-e*g)


def solve3(matrix, rhs):
    rows = [[Fraction(v) for v in row]+[Fraction(b)] for row, b in zip(matrix, rhs)]
    for col in range(3):
        pivot = next((r for r in range(col, 3) if rows[r][col]), None)
        if pivot is None:
            return None
        rows[col], rows[pivot] = rows[pivot], rows[col]
        divisor = rows[col][col]
        rows[col] = [v/divisor for v in rows[col]]
        for r in range(3):
            if r != col:
                multiplier = rows[r][col]
                rows[r] = [v-multiplier*w for v, w in zip(rows[r], rows[col])]
    result = [row[3] for row in rows]
    assert all(sum(Fraction(a)*x for a, x in zip(row, result)) == b
               for row, b in zip(matrix, rhs))
    return result


def expected(samples):
    rows = [[c, s, 1] for _, phase, _ in samples for c, s in [basis(phase)]]
    values = [x for x, _, _ in samples]
    matrix = [[sum(row[i]*row[j] for row in rows) for j in range(3)] for i in range(3)]
    rhs = [sum(row[i]*x for row, x in zip(rows, values)) for i in range(3)]
    n = len(rows)
    # Pairwise covariance identities are independent of RTL sum centering.
    a = sum((rows[i][0]-rows[j][0])**2 for i in range(n) for j in range(i))
    b = sum((rows[i][0]-rows[j][0])*(rows[i][1]-rows[j][1])
            for i in range(n) for j in range(i))
    d = sum((rows[i][1]-rows[j][1])**2 for i in range(n) for j in range(i))
    denominator = n*determinant3(matrix)
    assert denominator >= 0 and denominator == a*d-b*b
    solution = solve3(matrix, rhs)
    if solution is None:
        assert denominator == 0
        return 3, 0, 0, 0, a, b, d
    assert denominator > 0
    i_num = solution[0]*Q*denominator
    q_num = -solution[1]*Q*denominator
    assert i_num.denominator == q_num.denominator == 1
    assert abs(i_num) <= 1 << 115 and abs(q_num) <= 1 << 115
    assert denominator <= 1 << 100
    # Every normal-equation residual is exactly zero in rational arithmetic.
    residuals = [Fraction(x)-sum(Fraction(v)*coef for v, coef in zip(row, solution))
                 for row, x in zip(rows, values)]
    assert all(sum(row[col]*r for row, r in zip(rows, residuals)) == 0 for col in range(3))
    return 0, int(i_num), int(q_num), denominator, a, b, d


def make_cases(profile):
    maximum, tag_width = PROFILES[profile]
    rng = random.Random(0xB500+maximum+tag_width)
    cases = []

    def add(name, count, data, status=None):
        index = len(cases)
        tag = ((1 << tag_width)-1-index) & ((1 << tag_width)-1)
        if status is None:
            result = expected(data)
        else:
            result = (status, 0, 0, 0, 0, 0, 0)
        cases.append(dict(name=name, requested=count, tag=tag, samples=data, result=result))

    def frame(phases, kind="random"):
        data = []
        for k, phase in enumerate(phases):
            c, s = basis(phase)
            if kind == "dc":
                x = -32768
            elif kind == "cos":
                x = c
            elif kind == "negative_sin":
                x = -s
            elif kind == "minmax":
                x = -32768 if k & 1 else 32767
            else:
                x = rng.randrange(-32768, 32768)
            assert -32768 <= x <= 32767
            data.append((x, phase & ((1 << 24)-1), int(k == len(phases)-1)))
        return data

    add("invalid_zero", 0, [], 1)
    add("invalid_two", 2, [], 1)
    add("invalid_above_max", maximum+1, [], 1)
    add("invalid_u32max", 0xFFFFFFFF, [], 1)
    add("early_last", 3, [(32767, 0, 1)], 2)
    add("missing_last", 3, [(1, 0, 0), (-2, 1 << 22, 0), (3, 1 << 23, 0)], 2)
    add("rank_one_phase", 3, frame([0, 0, 0], "minmax"))
    add("rank_two_phases", 3, frame([0, 1 << 22, 0]))
    add("three_points_full_rank", 3, frame([0, 1 << 22, 1 << 23], "minmax"))
    add("dc_elimination", 3, frame([0, 1 << 22, 1 << 23], "dc"))
    add("nonorthogonal_near_rank", 3, frame([0, 1 << 17, 1 << 18]))
    if maximum >= 16:
        phases = [(1 << 22)+(k-2)*(1 << 17) for k in range(5)]
        add("known_cosine_exact_rational", 5, frame(phases, "cos"))
        phases = [(k-2)*(1 << 17) for k in range(5)]
        add("known_negative_sine_exact_rational", 5, frame(phases, "negative_sin"))
        add("arbitrary_nonpower_length", 13, frame([rng.randrange(1 << 24) for _ in range(13)]))
        add("phase_wrap", 16, frame([((1 << 24)-91+k*17321) & ((1 << 24)-1) for k in range(16)]))
        add("full_width_samples", 16, frame([rng.randrange(1 << 24) for _ in range(16)], "minmax"))
    if maximum == 256:
        add("maximum_noncoherent", 256, frame([(k*123457+0xF10001) & 0xFFFFFF for k in range(256)], "minmax"))
        add("maximum_dc", 256, frame([(k*65537+123) & 0xFFFFFF for k in range(256)], "dc"))
        add("maximum_arbitrary_phase", 256, frame([rng.randrange(1 << 24) for _ in range(256)]))
    return cases


def hexword(value, width):
    return format(value & ((1 << width)-1), f"0{(width+3)//4}x")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--profile", choices=PROFILES, required=True)
    parser.add_argument("--out", required=True)
    args = parser.parse_args()
    output = Path(args.out)
    output.mkdir(parents=True, exist_ok=False)
    cases = make_cases(args.profile)
    lines = []
    for case in cases:
        status, ni, nq, denominator, a, b, d = case["result"]
        fields = [(case["requested"], 32), (len(case["samples"]), 32),
                  (case["tag"], 32), (status, 3), (len(case["samples"]), 9),
                  (ni, 128), (nq, 128), (denominator, 112), (a, 56), (b, 56), (d, 56)]
        lines.append(" ".join(hexword(value, width) for value, width in fields))
        for sample, phase, last in case["samples"]:
            lines.append(f"{hexword(sample, 16)} {hexword(phase, 24)} {last:x}")
    payload = ("\n".join(lines)+"\n").encode("ascii")
    (output/"vectors.txt").write_bytes(payload)
    manifest = dict(profile=args.profile, maximum_samples=PROFILES[args.profile][0],
                    tag_width=PROFILES[args.profile][1], cases=len(cases),
                    sample_beats=sum(len(c["samples"]) for c in cases),
                    names=[c["name"] for c in cases],
                    oracle="Fraction full-3-column Gaussian elimination; pairwise Gram diagnostics",
                    basis="independent Decimal constants plus dependency integer bit contract; per-phase ideal <=1 LSB",
                    vectors_sha256=hashlib.sha256(payload).hexdigest(), vectors_bytes=len(payload))
    (output/"manifest.json").write_text(json.dumps(manifest, indent=2)+"\n", encoding="utf-8")
    print("TONE_FIT_PREP_PASS "+json.dumps(manifest, sort_keys=True))


if __name__ == "__main__":
    main()
