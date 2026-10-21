"""Golden model for cnn_infer_138k — single source of truth.

Deterministic weights (xorshift32), INT8 CNN forward pass bit-exact with RTL:
    conv1 3x3 p1 1->16, relu>>S1 clamp127, maxpool2x2 -> 14x14x16
    conv2 3x3 p1 16->16, relu>>S2 clamp127, maxpool2x2 -> 7x7x16
    fc 784->10 raw int32 scores
CRC32 digest over fmap_a bytes + fmap_b bytes + scores(int32 LE).
"""
import zlib

SEED = 0x13820
S1 = 7
S2 = 7
LANES = 16
NCLASS = 10

# ---------------------------------------------------------------- PRNG

def _xr32(state):
    state &= 0xFFFFFFFF
    state ^= (state << 13) & 0xFFFFFFFF
    state ^= (state >> 17) & 0xFFFFFFFF
    state ^= (state << 5) & 0xFFFFFFFF
    return state & 0xFFFFFFFF

class Rng:
    def __init__(self, seed=SEED):
        self.s = seed or 1
    def next(self):
        self.s = _xr32(self.s)
        return self.s
    def intn(self, lo, hi):  # inclusive
        return lo + self.next() % (hi - lo + 1)

# ---------------------------------------------------------------- weights

def gen_weights(seed=SEED):
    r = Rng(seed)
    w1 = [[r.intn(-16, 15) for _ in range(9)] for _ in range(16)]        # [oc][k]
    w2 = [[[r.intn(-16, 15) for _ in range(9)] for _ in range(16)]
          for _ in range(16)]                                          # [oc][ic][k]
    wfc = [[r.intn(-16, 15) for _ in range(784)] for _ in range(10)]    # [cls][i]
    b1 = [r.intn(-16, 15) for _ in range(16)]
    b2 = [r.intn(-16, 15) for _ in range(16)]
    bfc = [r.intn(-255, 255) for _ in range(10)]
    return dict(w1=w1, w2=w2, wfc=wfc, b1=b1, b2=b2, bfc=bfc)

def gen_image(seed=SEED ^ 0x5A5A):
    """Deterministic test image: diagonal bars + prng texture."""
    r = Rng(seed)
    img = []
    for y in range(28):
        for x in range(28):
            v = 16 + (r.next() & 0x1F)
            if abs(x - y) < 2:
                v += 120
            if abs(x + y - 27) < 3:
                v += 80
            img.append(min(v, 255))
    return img

# ---------------------------------------------------------------- forward

def _s8(v):
    return v - 256 if v > 127 else v

def conv3x3_plane(img, H, W, cin, cout, wset, bias, shift):
    """img: list of cin planes, each H*W unsigned bytes -> acc per oc,pos."""
    acc = [[bias[oc]] * (H * W) for oc in range(cout)]
    for oc in range(cout):
        for ic in range(cin):
            w = wset[oc][ic] if cin > 1 else wset[oc]
            for y in range(H):
                for x in range(W):
                    s = 0
                    for ky in range(3):
                        for kx in range(3):
                            yy, xx = y + ky - 1, x + kx - 1
                            if 0 <= yy < H and 0 <= xx < W:
                                s += img[ic][yy * W + xx] * w[ky * 3 + kx]
                    acc[oc][y * W + x] += s
    # relu >> shift clamp
    out = []
    for oc in range(cout):
        row = []
        for p in range(H * W):
            t = acc[oc][p]
            q = 0 if t < 0 else (t >> shift)
            row.append(min(q, 127))
        out.append(row)
    return out  # [oc][pos]

def maxpool2x2(fmap, H, W, cout):
    """fmap flat [oc][pos] ints -> pooled flat [oc][pos'] (H/2,W/2)."""
    ho, wo = H // 2, W // 2
    out = []
    for oc in range(cout):
        row = []
        for y in range(ho):
            for x in range(wo):
                m = max(fmap[oc][(2 * y + dy) * W + 2 * x + dx]
                        for dy in (0, 1) for dx in (0, 1))
                row.append(m)
        out.append(row)
    return out

def forward(img, W):
    """img: 784 uint8 -> dict with fmaps and scores."""
    a = conv3x3_plane([img], 28, 28, 1, 16, W['w1'], W['b1'], S1)
    a = maxpool2x2(a, 28, 28, 16)                    # 16 x 196
    fmap_a = a
    b = conv3x3_plane([a[ic] for ic in range(16)], 14, 14, 16, 16,
                      W['w2'], W['b2'], S2)
    b = maxpool2x2(b, 14, 14, 16)                    # 16 x 49
    fmap_b = b
    # fc: input order = pos-major then channel (byte addr = pos*16+ch)
    xvec = []
    for p in range(49):
        for ch in range(16):
            xvec.append(_s8(fmap_b[ch][p]))
    scores = []
    for c in range(10):
        s = W['bfc'][c]
        for i in range(784):
            s += xvec[i] * W['wfc'][c][i]
        s &= 0xFFFFFFFF
        if s >= 0x80000000:
            s -= 0x100000000
        scores.append(s)
    return dict(fmap_a=fmap_a, fmap_b=fmap_b, scores=scores)

def digest_bytes(res):
    """Byte stream the RTL CRC sees, in order."""
    out = bytearray()
    for p in range(196):
        for ch in range(16):
            out.append(res['fmap_a'][ch][p] & 0xFF)
    for p in range(49):
        for ch in range(16):
            out.append(res['fmap_b'][ch][p] & 0xFF)
    for s in res['scores']:
        out += (s & 0xFFFFFFFF).to_bytes(4, 'little')
    return bytes(out)

def digest(res):
    return zlib.crc32(digest_bytes(res)) & 0xFFFFFFFF

if __name__ == '__main__':
    W = gen_weights()
    img = gen_image()
    res = forward(img, W)
    print('scores:', res['scores'])
    print('argmax:', max(range(10), key=lambda i: res['scores'][i]))
    print('digest: %08X' % digest(res))
    fa = res['fmap_a']; fb = res['fmap_b']
    print('fmap_a range', min(fa), max(fa), 'fmap_b range', min(fb), max(fb))
