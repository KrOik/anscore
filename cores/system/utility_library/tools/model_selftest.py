"""Reference sanity checks using published check values and algebraic properties."""
from golden import MASK, encode_hamming, step


def main():
    checks = 0
    # Explicit algorithm definitions: nonreflected 0x1021 init FFFF; 0x07 init0.
    crc16, crc8 = 65535, 0
    for byte in b'123456789':
        crc16 = step('crc16_poly1021_byte', crc16, byte, 0)[0]
        crc8 = step('crc8_poly07_byte', crc8, byte, 0)[0]
    assert crc16 == 0x29b1 and crc8 == 0xf4
    checks += 2
    for data in range(256):
        code = encode_hamming(data)
        assert step('hamming13_decode8', code, 0, 0)[:3] == (data, 0, 0)
        checks += 1
        for i in range(13):
            r, x, f, _ = step('hamming13_decode8', code ^ (1 << i), 0, 0)
            assert r == data and not f and x & 1
            checks += 1
            for j in range(i+1, 13):
                r, x, f, _ = step('hamming13_decode8', code ^ (1 << i) ^ (1 << j), 0, 0)
                assert f and x & 2 and r == 0
                checks += 1
    for value in [0, 1, 10, 99, 12345, 12345678, 99999999]:
        coded = step('bcd8_encode', value, 0, 0)[0]
        assert step('bcd8_decode', coded, 0, 0)[:3] == (value, 0, 0)
        checks += 1
    for value in [0, 1, 127, 128, 16384, 2097152, (1 << 28)-1]:
        coded, size, _, _ = step('leb128_encode28', value, 0, 0)
        assert step('leb128_decode4', coded, size, 0)[:3] == (value, size, 0)
        checks += 1
    for value in range(1024):
        assert step('gray_decode32', value ^ (value >> 1), 0, 0)[0] == value
        checks += 1
    # Reach otherwise impractically distant saturating/wrapping state boundaries.
    assert step('event_counter32', MASK, MASK, 0, MASK-10)[:3] == (MASK, 32, 1)
    state = (1 << 64) | (MASK << 32) | 1
    r, count, _, state = step('stream_running_min32', 3, 0, 0, state)
    assert (r, count) == (1, 0)
    assert step('stream_running_min32', 2, 0, 0, state)[0] == 1
    checks += 3
    print(f'PASS independent model checks={checks}')


if __name__ == '__main__':
    main()
