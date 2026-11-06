# SPDX-License-Identifier: Apache-2.0
"""Independent full 2-D error field; no RTL bank/address/FSM scheduling."""


def diffuse(pixels, width, height, bits, low, high):
    assert 1 <= width <= 4096 and 1 <= height <= 4096
    assert bits in (8, 10, 12) and 0 <= low < high < 1 << bits
    assert len(pixels) == width * height
    maximum = (1 << bits) - 1
    field = [[0 for _ in range(width)] for _ in range(height)]
    result = []
    bounds = {"max_error": 0, "max_incoming": 0, "negative": 0, "ties": 0}
    for y in range(height):
        for x in range(width):
            incoming = field[y][x]
            corrected = min(maximum * 16, max(0, pixels[y * width + x] * 16 + incoming))
            code = int(2 * corrected >= (low + high) * 16)
            level = (low, high)[code]
            error = corrected - level * 16
            bounds["max_error"] = max(bounds["max_error"], abs(error))
            bounds["max_incoming"] = max(bounds["max_incoming"], abs(incoming))
            bounds["negative"] += error < 0
            bounds["ties"] += 2 * corrected == (low + high) * 16
            result.append((level, code))
            for dx, dy, weight in ((1, 0, 7), (-1, 1, 3), (0, 1, 5), (1, 1, 1)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < width and 0 <= ny < height:
                    amount = (abs(error) * weight + 8) // 16
                    field[ny][nx] += -amount if error < 0 else amount
    assert bounds["max_error"] <= maximum * 16
    assert bounds["max_incoming"] <= maximum * 16 + 2
    return result, bounds
