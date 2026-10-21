"""Independent integer / sequence models; never reads RTL or simulator output."""
import itertools
import random

MASK = (1 << 32) - 1


def signed(x):
    return x if x < 1 << 31 else x - (1 << 32)


def encode_hamming(v):
    data_positions = [3, 5, 6, 7, 9, 10, 11, 12]
    bits = {p: (v >> k) & 1 for k, p in enumerate(data_positions)}
    for p in [1, 2, 4, 8]:
        bits[p] = sum(bits.get(q, 0) for q in range(1, 13) if q & p) % 2
    bits[13] = sum(bits.values()) % 2
    return sum(bit << (p - 1) for p, bit in bits.items())


def polynomial_remainder(v, degree, polynomial):
    # Integer polynomial long division, rather than the RTL byte update loop.
    for k in range(v.bit_length() - 1, degree - 1, -1):
        if (v >> k) & 1:
            v ^= polynomial << (k - degree)
    return v


def step(name, a, b, c, state=0):
    r = x = 0
    f = False
    new_state = state
    restart = bool(c >> 31)
    old = 0 if restart else state & MASK
    if name == 'uadd_carry32':
        r, x = (a+b) & MASK, (a+b) >> 32
    elif name == 'usub_borrow32':
        r, x = (a-b) & MASK, int(a < b)
    elif name in ['sadd_overflow32', 'ssub_overflow32']:
        total = signed(a) + signed(b) if name.startswith('sadd') else signed(a)-signed(b)
        r, x = total & MASK, int(not -(1 << 31) <= total < (1 << 31))
    elif name == 'absdiff32':
        r, x = abs(a-b), int(a < b)
    elif name == 'minmax_signed32':
        r, x = sorted([a, b], key=signed)
    elif name == 'clamp_signed32':
        if signed(b) > signed(c):
            f = True
        else:
            r = min(max(signed(a), signed(b)), signed(c)) & MASK
            x = int(r != a)
    elif name == 'round_shift_even32':
        if b > 31:
            f = True
        elif b == 0:
            r = a
        else:
            q, rem = divmod(a, 1 << b)
            r, x = q + int(2*rem > (1 << b) or (2*rem == (1 << b) and q % 2)), rem
    elif name == 'popcount32':
        r = a.bit_count()
    elif name == 'clz32':
        r = 32-a.bit_length()
    elif name == 'ctz32':
        r = (a & -a).bit_length()-1 if a else 32
    elif name == 'bitreverse32':
        r = int(f'{a:032b}'[::-1], 2)
    elif name == 'byte_reverse32':
        r = int.from_bytes(a.to_bytes(4, 'little'), 'big')
    elif name == 'rotate32':
        bits = f'{a:032b}'
        n = b % 32
        n = (-n) % 32 if c & 1 else n
        r = int(bits[n:]+bits[:n], 2)
    elif name == 'bitfield_extract32':
        if b > 31 or c > 32 or b+c > 32:
            f = True
        else:
            x = (1 << c)-1
            r = (a >> b) & x
    elif name == 'bitfield_insert32':
        offset, width = c & 63, (c >> 8) & 63
        if offset > 31 or width > 32 or offset+width > 32:
            f = True
        else:
            x = ((1 << width)-1) << offset
            r = (a & (MASK ^ x)) | ((b << offset) & x)
    elif name == 'gray_decode32':
        r = a
        for shift in [1, 2, 4, 8, 16]:
            r ^= r >> shift
    elif name == 'thermometer_decode32':
        count = a.bit_count()
        f = a != (1 << count)-1
        r = 0 if f else count
    elif name == 'bcd8_encode':
        f = a > 99999999
        r = 0 if f else int(f'{a:08d}', 16)
    elif name == 'bcd8_decode':
        digits = f'{a:08x}'
        f = any(ch not in '0123456789' for ch in digits)
        r = 0 if f else int(digits, 10)
    elif name == 'hamming13_encode8':
        r = encode_hamming(a & 255)
    elif name == 'hamming13_decode8':
        syndrome = 0
        for position in range(1, 13):
            if (a >> (position-1)) & 1:
                syndrome ^= position
        odd = (a & 8191).bit_count() % 2
        f = a >= 8192 or (odd and syndrome > 12) or (not odd and syndrome != 0)
        corrected = bool(odd and not f)
        x = (syndrome << 4) | (2 if f else int(corrected))
        value = a ^ ((1 << (syndrome-1)) if corrected and syndrome else 0)
        if not f:
            r = sum(((value >> (p-1)) & 1) << k
                    for k, p in enumerate([3, 5, 6, 7, 9, 10, 11, 12]))
    elif name == 'crc16_poly1021_byte':
        r = polynomial_remainder(((a & 65535) << 8) ^ ((b & 255) << 16), 16, 0x11021)
    elif name == 'crc8_poly07_byte':
        r = polynomial_remainder(((a ^ b) & 255) << 8, 8, 0x107)
    elif name == 'internet_checksum_word':
        total = (a & 65535)+(b & 65535)
        r = (total-1) % 65535+1 if total else 0
        x = r ^ 65535
    elif name == 'sequence_window32':
        if c >= 1 << 31:
            f = True
        else:
            r = (a-b) & MASK
            x = int(r < c and r < 1 << 31) | (int(r == 0) << 1)
    elif name == 'address_boundary4k':
        if b == 0:
            f = True
        else:
            r = 4096-(a % 4096)
            x = int(b > r) | (int(a+b-1 > MASK) << 1)
    elif name == 'burst_split4k':
        if b == 0 or c == 0:
            f = True
        else:
            r = min(b, c, 4096-a % 4096)
            x = b-r
    elif name == 'keep_compact4':
        selected = bytes(v for k, v in enumerate(a.to_bytes(4, 'little')) if b & (1 << k))
        r, x = int.from_bytes(selected, 'little'), len(selected)
    elif name == 'byte_lane_merge4':
        aa, bb = a.to_bytes(4, 'little'), b.to_bytes(4, 'little')
        r = int.from_bytes(bytes(bb[k] if c & (1 << k) else aa[k] for k in range(4)), 'little')
        x = sum(255 << (8*k) for k in range(4) if c & (1 << k))
    elif name == 'leb128_encode28':
        if a >= 1 << 28:
            f = True
        else:
            words = []
            value = a
            while True:
                q, rem = divmod(value, 128)
                words.append(rem | (128 if q else 0))
                value = q
                if not value:
                    break
            r, x = int.from_bytes(bytes(words), 'little'), len(words)
    elif name == 'leb128_decode4':
        if b not in [1, 2, 3, 4]:
            f = True
        else:
            words = a.to_bytes(4, 'little')[:b]
            f = any(bool(v & 128) != (k < b-1) for k, v in enumerate(words))
            f = f or (b > 1 and (words[-1] & 127) == 0)
            if not f:
                r = sum((v & 127) << (7*k) for k, v in enumerate(words))
                x = b
    elif name == 'walking_pattern32':
        f = a > 31
        if not f:
            r = (1 << a) ^ (MASK if b & 1 else 0)
            x = (a+1) % 32
    elif name == 'march_step32':
        x = (c << 3) & MASK
        f = b > 5
        if not f:
            x |= (int(b < 5)) | (int(b > 0) << 1) | (int(b in [3, 4]) << 2)
            r = MASK if b in [1, 3] else 0
            f = bool(b and a != (MASK if b in [2, 4] else 0))
    elif name == 'stuck_fault32':
        r, x = (a ^ MASK) & b & c, a & (b ^ MASK) & c
        f = bool(r or x)
    elif name == 'parity_lane32':
        r = sum(v.bit_count() % 2 << k for k, v in enumerate(a.to_bytes(4, 'little')))
        if c & 1:
            x = (r ^ b) & 15
            f = bool(x)
    elif name == 'redundancy_compare32':
        r = (a & b) | (a & c) | (b & c)
        x = (a ^ b) | (b ^ c)
        f = bool(x)
    elif name == 'range_guard32':
        x = 4 if b > c else int(a < b) | (int(a > c) << 1)
        f = bool(x)
        r = 0 if f else a
    elif name == 'onehot_guard32':
        x = a.bit_count()
        r = a.bit_length()-1 if a else 32
        f = x > 1 or (x == 0 and not c & 1)
    elif name in ['change_detect32', 'stream_delta32', 'stream_xor_acc32', 'stream_rising_edges32']:
        if name == 'change_detect32':
            r, x, new_state = a ^ old, a, a
        elif name == 'stream_delta32':
            r, x, new_state = (a-old) & MASK, old, a
        elif name == 'stream_xor_acc32':
            r, x, new_state = a ^ old, old, a ^ old
        else:
            r, x, new_state = a & (old ^ MASK), (a ^ MASK) & old, a
    elif name == 'stream_prefix_sum32':
        r, x = (old+a) & MASK, (old+a) >> 32
        new_state = r
    elif name in ['stream_running_min32', 'stream_running_max32']:
        count = 0 if restart else (state >> 32) & MASK
        initialized = bool(state >> 64) and not restart
        if not initialized:
            r = a
        else:
            r = min(old, a) if 'min' in name else max(old, a)
        x = (count+1) & MASK
        new_state = (1 << 64) | (x << 32) | r
    elif name == 'stream_sequence32':
        x = b if restart or not state >> 32 else old
        r, f = (a+1) & MASK, a != x
        new_state = (1 << 32) | r
    elif name == 'stream_credit32':
        total = old+a
        f = total > MASK or total < b
        r, x = (old, 0) if f else (total-b, b)
        new_state = r
    elif name == 'event_counter32':
        x = (a & b).bit_count()
        f = old+x > MASK
        r, new_state = min(old+x, MASK), min(old+x, MASK)
    elif name == 'sticky_event32':
        r = (old & (b ^ MASK)) | a
        x, new_state = r & (old ^ MASK), r
    elif name == 'first_fault32':
        new_state = 0 if restart else state
        if not new_state & MASK and a:
            new_state = (b << 32) | a
        r, x = new_state & MASK, new_state >> 32
    elif name == 'watermark32':
        r, x, new_state = max(a, old), a, max(a, old)
    elif name == 'hysteresis32':
        high = c & 0x7fffffff
        f = b >= high
        r = old if f else (1 if a >= high else (0 if a <= b else old))
        x, new_state = (0 if f else r ^ old), r
    elif name == 'debounce_word32':
        working = 0 if restart else state
        stable, candidate, count = working & MASK, (working >> 32) & MASK, working >> 64
        f = not 1 <= b <= 65535
        if not f:
            count = min(count+1, 65535) if a == candidate else 1
            candidate = a
            stable = a if count >= b else stable
        r, x = stable, count
        new_state = (count << 64) | (candidate << 32) | stable
    elif name == 'token_bucket32':
        tokens = min(old+a, c & 0x7fffffff)
        f = tokens < b
        r, x = (tokens, 0) if f else (tokens-b, 1)
        new_state = r
    elif name == 'round_robin8':
        requests = [k for k in [(old+j) % 8 for j in range(8)] if a & b & (1 << k)]
        x = requests[0] if requests else 8
        r = (1 << x) if requests else 0
        new_state = (x+1) % 8 if requests else old
    else:
        raise ValueError(name)
    return r & MASK, x & MASK, int(bool(f)), new_state


def vectors(name, count=320):
    rng = random.Random(0x250056 + sum(name.encode()))
    edges = [0, 1, 2, 3, 7, 8, 15, 16, 31, 32, 33, 127, 128, 255, 256,
             4095, 4096, 65535, 65536, 0x7fffffff, 0x80000000, MASK]
    rows = [(a, edges[(k+7) % len(edges)], edges[(k+13) % len(edges)]) for k, a in enumerate(edges)]
    if name == 'hamming13_decode8':
        for v in [0, 1, 85, 170, 255]:
            code = encode_hamming(v)
            rows.append((code, 0, 0))
            rows.extend((code ^ (1 << bit), 0, 0) for bit in range(13))
            rows.extend((code ^ (1 << i) ^ (1 << j), 0, 0)
                        for i, j in itertools.combinations(range(13), 2))
    if name == 'bcd8_encode':
        rows.extend((v, 0, 0) for v in [9, 10, 99, 100, 99999999, 100000000])
    if name == 'bcd8_decode':
        rows.extend((int(f'{v:08d}', 16), 0, 0) for v in [0, 9, 10, 12345678, 99999999])
    if name == 'thermometer_decode32':
        rows.extend(((1 << k)-1, 0, 0) for k in range(33))
    if name == 'round_shift_even32':
        rows.extend((v, k, 0) for k in range(1, 32) for v in [(1 << (k-1)), 3*(1 << (k-1)), MASK])
    if name in ['clz32', 'ctz32', 'onehot_guard32', 'walking_pattern32']:
        rows.extend(((k if name == 'walking_pattern32' else 1 << k), k % 2, 0) for k in range(32))
    if name == 'debounce_word32':
        rows.extend((v, 3, (1 << 31) if k == 0 else 0) for k, v in enumerate([9]*5 + [4]*5 + [0]*5))
    if name == 'hysteresis32':
        rows.extend((v, 10, 20 | ((1 << 31) if k == 0 else 0)) for k, v in enumerate([0, 10, 15, 20, 15, 11, 10, 15, 30]))
    if name == 'round_robin8':
        rows.extend((255, 255, (1 << 31) if k == 0 else 0) for k in range(24))
    if name == 'stream_sequence32':
        rows.extend((k & MASK, MASK-3, (1 << 31) if k == MASK-3 else 0) for k in range(MASK-3, MASK+5))
    if name == 'leb128_decode4':
        for v in [0, 127, 128, 16383, 16384, 2097151, 2097152, (1 << 28)-1]:
            rr, xx, _, _ = step('leb128_encode28', v, 0, 0)
            rows.append((rr, xx, 0))
        rows.extend([(0x80, 1, 0), (0x0080, 2, 0), (0x80808080, 4, 0)])
    for k in range(count):
        a, b, c = [rng.getrandbits(32) for _ in range(3)]
        if name == 'round_shift_even32':
            b = rng.randrange(35)
        elif name == 'bitfield_extract32':
            b, c = rng.randrange(35), rng.randrange(35)
        elif name == 'bitfield_insert32':
            c = rng.randrange(35) | (rng.randrange(35) << 8)
        elif name == 'bcd8_encode':
            a %= 110000000
        elif name == 'bcd8_decode' and k % 2:
            a = int(f'{a % 100000000:08d}', 16)
        elif name == 'hamming13_decode8':
            a &= 8191
        elif name == 'walking_pattern32':
            a %= 35
        elif name == 'leb128_encode28':
            a &= (1 << 28)-1
        elif name == 'leb128_decode4':
            b %= 6
        elif name == 'sequence_window32':
            c = c & 0x7fffffff if k % 2 else c
        elif name == 'march_step32':
            b %= 8
            if k % 2:
                a = MASK if b in [2, 4] else 0
        elif name in ['clamp_signed32', 'range_guard32'] and k % 2:
            b, c = sorted([b, c], key=signed if name == 'clamp_signed32' else None)
        elif name == 'debounce_word32':
            b, a = rng.randrange(6), rng.randrange(5)
        elif name == 'hysteresis32':
            a, b, c = rng.randrange(30), 10, 20
        elif name == 'token_bucket32':
            a, b, c = rng.randrange(20), rng.randrange(20), 32
        if name.startswith('stream_') or name in ['event_counter32', 'sticky_event32', 'first_fault32', 'watermark32', 'hysteresis32', 'debounce_word32', 'token_bucket32', 'round_robin8', 'change_detect32']:
            c = (c & 0x7fffffff) | ((1 << 31) if k % 37 == 0 else 0)
        rows.append((a, b, c))
    return rows
