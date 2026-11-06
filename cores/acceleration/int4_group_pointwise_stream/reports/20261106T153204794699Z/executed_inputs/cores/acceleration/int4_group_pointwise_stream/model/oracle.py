"""Independent integer specification. No RTL, simulator or workflow imports."""
def rounded(numerator, shift):
    magnitude = abs(numerator)
    quotient, remainder = divmod(magnitude, 1 << shift)
    divisor = 1 << shift
    if 2 * remainder > divisor or (2 * remainder == divisor and quotient % 2):
        quotient += 1
    return (-quotient if numerator < 0 else quotient), int(remainder != 0)


def evaluate(samples, groups, inputs, outputs, xzero, shuffle, matrix):
    result = []
    for values in samples:
        order = [(g, o) for g in range(groups) for o in range(outputs)]
        if shuffle:
            order = [(g, o) for o in range(outputs) for g in range(groups)]
        for group, row in order:
            bias, scale, shift, zero, weights = matrix[group][row]
            exact = bias + sum((values[group * inputs + i] - xzero) * weights[i]
                               for i in range(inputs))
            quantized, inexact = rounded(exact * scale, shift)
            value = quantized + zero
            result.append((min(127, max(-128, value)), int(not -128 <= value <= 127),
                           inexact, group, row))
    return result


def rgb_projection(values):
    result = []
    for weights, shift in [([2, 4, 1], 3), ([1, -1, 0], 0)]:
        for group in range(2):
            exact = sum((values[3 * group + i] - 128) * weights[i] for i in range(3))
            value, _ = rounded(exact, shift)
            result.append(min(127, max(-128, value)))
    return sum((value & 255) << (8 * i) for i, value in enumerate(result))
