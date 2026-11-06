"""Independent dense reconstruction and arbitrary precision rational rounding."""
PAIRS = ((0, 1), (0, 2), (0, 3), (1, 2), (1, 3), (2, 3))


def quantize(value, scale, shift, zero):
    numerator = value * scale
    quotient, remainder = divmod(numerator, 1 << shift)
    rounded = quotient + (2 * remainder > (1 << shift) or
                          (2 * remainder == (1 << shift) and quotient % 2 != 0))
    translated = rounded + zero
    return max(-128, min(127, translated)), int(translated < -128 or translated > 127), int(remainder != 0)


def evaluate(vector, xzero, matrix):
    results = []
    for bias, scale, shift, zero, groups in matrix:
        # Reconstruct dense row, then dot every original input coordinate.
        dense = [0] * (4 * len(groups))
        for group, (pattern, weight0, weight1) in enumerate(groups):
            a, b = PAIRS[pattern]
            dense[4 * group + a] = weight0
            dense[4 * group + b] = weight1
        acc = bias + sum((x - xzero) * dense[i] for i, x in enumerate(vector))
        results.append(quantize(acc, scale, shift, zero))
    return results


def example(vector):
    scores = [quantize(vector[a] - vector[b], 1, 1, 0)[0]
              for a, b in ((0, 1), (0, 2), (1, 3), (2, 3))]
    return [(scores[i], i) for i in sorted(range(4), key=lambda i: (-scores[i], i))[:2]]
