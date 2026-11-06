"""SPDX-License-Identifier: Apache-2.0. Independent exact rational oracle."""
def nearest_even(numerator, denominator):
    quotient, remainder = divmod(numerator, denominator)
    return quotient + (2 * remainder > denominator or
                       (2 * remainder == denominator and quotient % 2 != 0))

def fuse(a, b, meta):
    sa, sb, shift, za, zb, zo, lower, upper = meta
    exact = (a - za) * sa + (b - zb) * sb
    rounded = nearest_even(exact, 2 ** shift) + zo
    return (max(lower, min(upper, rounded)),
            int(rounded < lower or rounded > upper),
            int(exact % (2 ** shift) != 0))
