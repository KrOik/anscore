"""Quantized direct-form-I integer reference for reproducible simulation."""
import random


def fixture(folder):
    rng = random.Random(0xB10A)
    rows = []
    checks = 0
    # Identity, feed-forward cancellation, stable recursive smoothing,
    # deliberate saturation, and signed-coefficient limits.
    for coeff in [(64, 0, 0, 0, 0), (32, -64, 32, 0, 0),
                  (16, 16, 0, -32, 0), (127, 127, 127, -100, 50),
                  (-128, 127, -128, 127, -128)]:
        rows.append("2 0 0 0 0 0 0\n")
        for addr, value in enumerate(coeff):
            rows.append(f"0 {addr} {value} 0 0 0 0\n")
        x1 = x2 = y1 = y2 = 0
        for index in range(240):
            x = [127, -128, 0, 1, -1, rng.randrange(-128, 128)][rng.randrange(6)]
            last = int(index % 31 == 30 or index == 239)
            y = (coeff[0]*x + coeff[1]*x1 + coeff[2]*x2
                 - coeff[3]*y1 - coeff[4]*y2) >> 6
            y = max(-128, min(127, y))
            x2, x1, y2, y1 = x1, x, y1, y
            if last:
                x1 = x2 = y1 = y2 = 0
            rows.append(f"1 {x} {last} {y} {rng.randrange(4)} {rng.randrange(5)} {rng.randrange(1,4)}\n")
            checks += 1
    path = folder / "iir_fixture.txt"
    path.write_text("".join(rows), encoding="ascii")
    return path, checks
