# SPDX-License-Identifier: Apache-2.0
"""Independent arbitrary-integer/Fraction oracle; no RTL/helper imports or tools."""
from fractions import Fraction


def nearest_even(value: Fraction) -> int:
    """Round a nonnegative rational, retaining exact half information."""
    if value < 0:
        raise ValueError("nonnegative rational required")
    lower, rem = divmod(value.numerator, value.denominator)
    return lower + int(2 * rem > value.denominator or
                       (2 * rem == value.denominator and lower % 2 == 1))


def rgb_bytes(rgb: int) -> tuple[int, int, int]:
    if not 0 <= rgb <= 0xFFFFFF:
        raise ValueError("RGB888 range")
    return rgb >> 16, (rgb >> 8) & 255, rgb & 255


def rgba_bytes(rgba: int) -> tuple[int, int, int, int]:
    if not 0 <= rgba <= 0xFFFFFFFF:
        raise ValueError("RGBA8888 range")
    return tuple((rgba >> shift) & 255 for shift in (24, 16, 8, 0))


def screen_matte(rgb: int, key: int, inner: int, outer: int,
                 strength: int, blue: int) -> tuple[int, int]:
    red, green, blue_channel = rgb_bytes(rgb)
    kr, kg, kb = rgb_bytes(key)
    if not (0 <= inner < 2**19 and 0 <= outer < 2**19 and
            0 <= strength <= 255 and blue in (0, 1)):
        raise ValueError("configuration port range")
    if outer < inner:
        return 0, 1
    distance = ((blue_channel - green) - (kb - kg))**2
    distance += ((red - green) - (kr - kg))**2
    if outer == inner:
        alpha = 255 if distance > inner else 0
    elif distance <= inner:
        alpha = 0
    elif distance >= outer:
        alpha = 255
    else:
        alpha = nearest_even(Fraction(255 * (distance - inner), outer - inner))
    corrected = [red, green, blue_channel]
    screen_index = 2 if blue else 1
    remaining = [corrected[i] for i in range(3) if i != screen_index]
    excess = max(0, corrected[screen_index] - max(remaining))
    corrected[screen_index] -= nearest_even(Fraction(excess * strength, 255))
    colors = [nearest_even(Fraction(channel * alpha, 255)) for channel in corrected]
    if any(not 0 <= channel <= alpha for channel in colors):
        raise AssertionError("premultiplied result bound")
    return (colors[0] << 24) | (colors[1] << 16) | (colors[2] << 8) | alpha, 0


def source_over(source: int, destination: int) -> tuple[int, int]:
    """Mathematical production source-over equation, including input validity."""
    src = rgba_bytes(source)
    dst = rgba_bytes(destination)
    if any(color > src[3] for color in src[:3]):
        return 0, 2
    if any(color > dst[3] for color in dst[:3]):
        return 0, 3
    result = [min(255, nearest_even(Fraction(s * 255 + d * (255 - src[3]), 255)))
              for s, d in zip(src, dst)]
    return sum(value << shift for value, shift in zip(result, (24, 16, 8, 0))), 0


def matte_over(rgb: int, key: int, inner: int, outer: int,
               strength: int, blue: int, background: int) -> tuple[int, int]:
    paint, config_error = screen_matte(rgb, key, inner, outer, strength, blue)
    composed, blend_error = source_over(paint, background)
    return (0 if config_error else composed), (config_error << 2) | blend_error
