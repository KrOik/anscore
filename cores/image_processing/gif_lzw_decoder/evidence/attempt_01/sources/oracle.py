"""Independent whole-word GIF image-data oracle. No RTL or upstream imports."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path

MIN, LZW, FORMAT, UPSTREAM, LIMIT = 1, 2, 4, 8, 16


def widths_for_codes(minimum: int, codes: list[int]) -> list[int]:
    """Packing schedule from allocation events, independent of word expansion."""
    clear = 1 << minimum
    width, next_free, have_previous = minimum + 1, clear + 2, False
    widths = []
    for code in codes:
        widths.append(width)
        assert 0 <= code < (1 << width)
        if code == clear:
            width, next_free, have_previous = minimum + 1, clear + 2, False
        elif code == clear + 1:
            break
        else:
            if have_previous and next_free < 4096:
                next_free += 1
                if next_free == (1 << width) and width < 12:
                    width += 1
            have_previous = True
    assert len(widths) == len(codes)
    return widths


def pack(codes: list[int], widths: list[int], pad_high: bool = False) -> bytes:
    assert len(codes) == len(widths)
    value, offset = 0, 0
    for code, width in zip(codes, widths):
        assert 1 <= width <= 12 and 0 <= code < (1 << width)
        value |= code << offset
        offset += width
    if pad_high and offset % 8:
        value |= ((1 << (8 - offset % 8)) - 1) << offset
    return value.to_bytes((offset + 7) // 8, "little")


def encode(data: bytes, minimum: int) -> list[int]:
    """Ordinary bytes-to-code LZW encoder; byte strings are its dictionary keys."""
    clear = 1 << minimum
    assert all(byte < clear for byte in data)
    table = {bytes([i]): i for i in range(clear)}
    next_free, codes, word = clear + 2, [clear], b""
    for byte in data:
        candidate = word + bytes([byte])
        if candidate in table:
            word = candidate
        else:
            codes.append(table[word])
            if next_free < 4096:
                table[candidate] = next_free
                next_free += 1
            word = bytes([byte])
    if word:
        codes.append(table[word])
    return codes + [clear + 1]


def section(minimum: int, payload: bytes, block_sizes: list[int] | None = None,
            after_blocks: list[bytes] | None = None) -> bytes:
    sizes = block_sizes or [255]
    assert sizes and all(1 <= n <= 255 for n in sizes)
    result, offset, block = bytearray([minimum]), 0, 0
    while offset < len(payload):
        chunk = payload[offset:offset + sizes[block % len(sizes)]]
        result.append(len(chunk)); result.extend(chunk)
        offset += len(chunk); block += 1
    for chunk in after_blocks or []:
        assert 1 <= len(chunk) <= 255
        result.append(len(chunk)); result.extend(chunk)
    result.append(0)
    return bytes(result)


class StopDecode(Exception):
    pass


def decode(data: bytes, bad_positions: list[int], count_w: int) -> dict:
    """Consume actual section bytes; word dictionary has no prefix-chain/RAM model.

    Every fixture's final supplied byte carries LAST. Rejected payload bytes are
    never appended. Once an error occurs only upstream markers are accumulated.
    """
    assert data and 1 <= count_w <= 32
    bad, indices, errors, pos = set(bad_positions), [], 0, 1
    minimum = data[0]
    metrics = dict(codes=0, data_codes=0, kw=0, refill_branches=0,
                   dictionary_reads=0, dictionary_writes=0, max_width=0,
                   max_next=0, clear_count=0, frozen_data_codes=0)
    errors |= MIN if not 2 <= minimum <= 8 else 0
    errors |= FORMAT if len(data) == 1 else 0
    errors |= UPSTREAM if 0 in bad else 0
    left, need_length, eoi, terminal = 0, True, False, len(data) == 1

    def fail(flag: int, last: bool) -> None:
        nonlocal errors, terminal
        errors |= flag
        terminal = last
        raise StopDecode

    def payload_byte(skipping: bool = False) -> int:
        nonlocal pos, left, need_length, terminal
        while True:
            assert pos < len(data), "fixture must provide a final LAST byte"
            at = pos
            byte, last = data[at], at == len(data) - 1
            pos += 1
            if at in bad:
                fail(UPSTREAM, last)
            if need_length:
                if byte == 0:
                    terminal = last
                    if not skipping or not last:
                        fail(FORMAT, last)
                    raise StopDecode
                if last:
                    fail(FORMAT, True)
                left, need_length = byte, False
            else:
                if last:
                    fail(FORMAT, True)
                left -= 1
                need_length = left == 0
                return byte

    if not errors:
        clear, end = 1 << minimum, (1 << minimum) + 1
        words = {i: bytes([i]) for i in range(clear)}
        width, next_free, previous = minimum + 1, clear + 2, None
        bits, available, filled = 0, 0, False
        metrics["max_width"], metrics["max_next"] = width, next_free
        try:
            while True:
                while available < width:
                    if filled:
                        metrics["refill_branches"] += 1
                    byte = payload_byte()
                    bits |= byte << available
                    available += 8
                    filled = True
                code = bits & ((1 << width) - 1)
                bits >>= width; available -= width
                metrics["codes"] += 1
                if code == clear:
                    words = {i: bytes([i]) for i in range(clear)}
                    width, next_free, previous = minimum + 1, clear + 2, None
                    metrics["clear_count"] += 1
                    continue
                if code == end:
                    eoi = True
                    while True:
                        payload_byte(skipping=True)
                is_kw = code == next_free and previous is not None and next_free < 4096
                if code in words:
                    word = words[code]
                elif is_kw:
                    word = previous + previous[:1]
                    metrics["kw"] += 1
                else:
                    fail(LZW, False)
                metrics["data_codes"] += 1
                metrics["dictionary_reads"] += len(word) - 1 - int(is_kw)
                if previous is not None and next_free < 4096:
                    words[next_free] = previous + word[:1]
                    next_free += 1
                    metrics["dictionary_writes"] += 1
                    if next_free == (1 << width) and width < 12:
                        width += 1
                    metrics["max_width"] = max(metrics["max_width"], width)
                    metrics["max_next"] = max(metrics["max_next"], next_free)
                elif previous is not None:
                    metrics["frozen_data_codes"] += 1
                previous = word
                for byte in word:
                    if len(indices) == (1 << count_w) - 1:
                        fail(LIMIT, False)
                    indices.append(byte)
        except StopDecode:
            pass
    if not terminal:
        for at in range(pos, len(data)):
            if at in bad:
                errors |= UPSTREAM
        pos = len(data)
    assert pos == len(data), "terminal LAST must be the fixture's final byte"
    success = errors == 0
    assert not success or eoi
    latency = ((len(data) - 1) + 2 * metrics["codes"] + 6 * len(indices)
               - 2 * metrics["kw"] + metrics["refill_branches"]) if success else -1
    return dict(indices=indices, errors=errors, count=len(indices), minimum=minimum,
                success=success, latency=latency, metrics=metrics)


def check_stored(root: Path) -> None:
    seal = json.loads((root / "SOURCE_SEAL.json").read_text())
    for group in ("sources", "fixtures"):
        for rel, expected in seal[group].items():
            assert hashlib.sha256((root / rel).read_bytes()).hexdigest() == expected, rel
    fixtures = json.loads((root / "fixtures/cases.json").read_text())
    certificates = json.loads((root / "BOUNDARY_CERTIFICATES.json").read_text())["certificates"]
    for cert in certificates:
        assert pack(cert["codes"], cert["widths"]).hex() == cert["payload_hex"]
        assert widths_for_codes(cert["minimum"], cert["codes"]) == cert["widths"]
        assert section(cert["minimum"], bytes.fromhex(cert["payload_hex"])).hex() == cert["section_hex"]
        assert decode(bytes.fromhex(cert["section_hex"]), [], 32)["indices"] == cert["indices"]
    for case in fixtures:
        actual = decode(bytes.fromhex(case["section_hex"]), case["bad_positions"], case["COUNT_W"])
        assert actual == case["expected"], case["key"]
    assert len(fixtures) == 38
    print("PASS ORACLE cases=38 certificates=3")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--verify-stored", action="store_true", required=True)
    args = parser.parse_args()
    check_stored(Path(__file__).resolve().parent)
