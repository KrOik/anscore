"""SPDX-License-Identifier: Apache-2.0. Independent byte-string IPv4/LPM oracle."""
import random


def folded(data):
    assert len(data) == 20
    total = sum(int.from_bytes(data[i:i+2], 'big') for i in range(0, 20, 2))
    while total >> 16:
        total = (total & 65535) + (total >> 16)
    return total


def repaired(data):
    data = bytearray(data)
    data[10:12] = b'\0\0'
    data[10:12] = (65535 ^ folded(data)).to_bytes(2, 'big')
    return bytes(data)


def header(dst=0x0a010203, ttl=64, ident=1, flags=0, protocol=17, length=20):
    return repaired(bytes([0x45, 0]) + length.to_bytes(2, 'big') + ident.to_bytes(2, 'big') +
                    flags.to_bytes(2, 'big') + bytes([ttl, protocol, 0, 0]) +
                    (0xc0000201).to_bytes(4, 'big') + dst.to_bytes(4, 'big'))


class Model:
    def __init__(self, routes, tag_w):
        self.routes = routes
        self.tag_mask = (1 << tag_w) - 1
        self.bindings = {}

    def admin(self, op, key=0, length=0, value=0, tag=0):
        found = inserted = prefix = old_length = old_value = status = 0
        if op == 3:
            self.bindings.clear()
        elif op in (1, 2) and length > 32:
            status = 3
        else:
            identity = (key & (((1 << length)-1) << (32-length)), length) if op != 0 else None
            matches = [(k, v) for k, v in self.bindings.items()
                       if (key >> (32-k[1]) == k[0] >> (32-k[1]))] if op == 0 else []
            chosen = max(matches, key=lambda kv: kv[0][1]) if matches else None
            if op != 0 and identity in self.bindings:
                chosen = (identity, self.bindings[identity])
            if chosen is not None:
                (prefix, old_length), old_value = chosen
                found = 1
            if op == 0:
                status = 0 if found else 1
            elif op == 1:
                if not found and len(self.bindings) == self.routes:
                    status = 2
                else:
                    inserted = 1 - found
                    self.bindings[identity] = value
            elif found:
                del self.bindings[identity]
            else:
                status = 1
        return [0, op, key, length, value, tag & self.tag_mask, 0, bytes(20),
                status, found, inserted, prefix, old_length, old_value, len(self.bindings), bytes(20)]

    def packet(self, data, available=None, tag=0, inject=False):
        available = int.from_bytes(data[2:4], 'big') if available is None else available
        length = int.from_bytes(data[2:4], 'big')
        flags = int.from_bytes(data[6:8], 'big')
        status = 0
        prefix = plen = value = 0
        output = data
        if data[0] != 0x45 or available < 20 or length < 20 or length > available or flags & 0x8000 or (flags & 0x4000 and flags & 0x3fff):
            status = 1
        elif inject:
            status = 5
        elif folded(data) != 65535:
            status = 2
        elif data[8] <= 1:
            status = 3
        else:
            dst = int.from_bytes(data[16:20], 'big')
            matches = [(k, v) for k, v in self.bindings.items() if dst >> (32-k[1]) == k[0] >> (32-k[1])]
            if not matches:
                status = 4
            else:
                (prefix, plen), value = max(matches, key=lambda kv: kv[0][1])
                value = (value & (255 << 32)) | ((value & 0xffffffff) or dst)
                changed = bytearray(data)
                changed[8] -= 1
                output = repaired(changed)
        return [3 if inject else 1, 0, 0, 0, 0, tag & self.tag_mask, available, data,
                status, 0, 0, prefix, plen, value, len(self.bindings), output]

    def reset(self):
        self.bindings.clear()
        return [2, 0, 0, 0, 0, 0, 0, bytes(20), 0, 0, 0, 0, 0, 0, 0, bytes(20)]


def build(routes, tag_w, example=False):
    m = Model(routes, tag_w)
    rows = []
    rng = random.Random(0x43a115 + routes * 101 + tag_w)
    if example:
        m.admin(1, 0, 0, 1 << 32)
        m.admin(1, 0xc0a80000, 16, (2 << 32) | 0xc0a80001)
    else:
        rows += [m.admin(3), m.admin(0, 0xffffffff), m.packet(header(), tag=1)]
        rows.append(m.admin(1, 0x12345678, 0, 1 << 32, 2))
        rows += [m.packet(header(ttl=t), tag=t) for t in (0, 1, 2, 64, 255)]
        rows.append(m.admin(1, 0xffffffff, 0, (4 << 32) | 0xc0000209, 3))
        rows.append(m.admin(1, 0x0a010203, 32, (2 << 32) | 0xc0000202, 4))
        rows.append(m.admin(3, tag=5))
        for i in range(routes):
            rows.append(m.admin(1, 0x0a000000+i, 32, ((i & 255) << 32) | (0 if i % 3 else 0xc0000201+i), i))
        rows.append(m.admin(1, 0x0b000000, 32, 7 << 32, 6))
        rows.append(m.admin(1, 0x0a000000, 32, 9 << 32, 7))
        for i in sorted({0, routes//2, routes-1}):
            rows.append(m.packet(header(0x0a000000+i), tag=i))
        rows.append(m.admin(2, 0x0a000000+routes-1, 32, tag=8))
        rows.append(m.admin(1, 0x0b000000, 32, 7 << 32, 9))
        rows.append(m.admin(0, 0x0a000000, tag=10))
        rows.append(m.reset())
        for length in (0, 8, 16, 24, 31, 32):
            rows.append(m.admin(1, 0x0a010203, length, ((length+1) << 32) | (0xc0000201 if length & 1 else 0), length))
        rows.append(m.packet(header(), tag=11))
        rows.append(m.admin(2, 0x0a010203, 32, tag=12))
        rows.append(m.packet(header(), tag=13))
        for length in (33, 256, 0xffffffff):
            rows += [m.admin(1, 0xffffffff, length, (255 << 32) | 0xffffffff, length),
                     m.admin(2, 0, length, tag=length)]
        rows += [m.admin(0, 0x0a010203, 0xffffffff, tag=14), m.packet(header(), tag=15, inject=True),
                 m.packet(header(), tag=16)]

    # Deterministic header boundaries, including both received checksum zeros.
    for i in range(48):
        dst = (0xc0a80000 | rng.randrange(65536)) if i & 1 else rng.getrandbits(32)
        data = bytearray(header(dst, (0, 1, 2, 255, 64, 128)[i % 6], i*131, (0, 0x2000, 7, 0x4000)[i % 4], i % 256, 20 + i*13))
        available = int.from_bytes(data[2:4], 'big') + (i % 3)
        case = i % 12
        if case == 1:
            data[0] = 0x65
        elif case == 2:
            data[0] = 0x46
        elif case == 3:
            data[2:4] = b'\0\x13'
        elif case == 4:
            available = 19
        elif case == 5:
            available = int.from_bytes(data[2:4], 'big')-1
        elif case == 6:
            data[6] |= 0x80
        elif case == 7:
            data[6:8] = b'\x60\0'
        elif case == 8:
            data[6:8] = b'\x40\1'
        elif case == 9:
            data[10] ^= 1
        rows.append(m.packet(bytes(data), available, rng.getrandbits(32)))
    for checksum in (0, 65535):
        data = bytearray(header(0xc0a80101, 2))
        data[4:6] = b'\0\0'; data[10:12] = b'\0\0'
        # Changing ID to complement of the rest makes the non-checksum sum ffff.
        data[4:6] = (65535 ^ folded(data)).to_bytes(2, 'big')
        data[10:12] = checksum.to_bytes(2, 'big')
        assert folded(data) == 65535
        rows.append(m.packet(bytes(data), 20, checksum))

    if not example:
        for i in range(96):
            key = rng.choice([rng.getrandbits(32), 0x0a010203, 0xc0a80101, 0])
            if i % 4:
                rows.append(m.packet(header(key, rng.choice([2, 3, 128, 255]), rng.randrange(65536), 0, rng.randrange(256), rng.randrange(20, 65536)), tag=rng.getrandbits(32)))
            else:
                op = rng.choice([0, 1, 2]); length = rng.choice([0, 1, 8, 16, 24, 31, 32, 33, 0xffffffff])
                rows.append(m.admin(op, key, length, rng.getrandbits(40), rng.getrandbits(32)))
        rows.append(m.reset())
        rows += [m.packet(header(), tag=17), m.admin(1, 0, 0, 1 << 32, 18), m.packet(header(), tag=19)]
    return rows


def serialize(row):
    kind, op, key, length, value, tag, available, data, status, found, inserted, prefix, plen, old_value, count, output = row
    return f'{kind} {op} {key:08x} {length:08x} {value:010x} {tag:08x} {available} {data.hex()} {status} {found} {inserted} {prefix:08x} {plen} {old_value:010x} {count} {output.hex()}\n'
