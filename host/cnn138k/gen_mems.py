"""Generate mem/ artifacts for cnn_infer_138k per SPEC.md.

Usage: python host/cnn138k/gen_mems.py
Writes into cores/acceleration/cnn_inference/mem/.
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from cnn_model import gen_weights, gen_image, forward, digest, digest_bytes, S1, S2, SEED

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), '..', '..'))
MEM = os.path.join(ROOT, 'projects', 'cnn_infer_138k', 'mem')


def b8(v):
    return v & 0xFF


def word9(ws):
    """9 int8 -> 72-bit word, w0 in [7:0] (MSB->LSB hex)."""
    acc = 0
    for i, w in enumerate(ws):
        acc |= (w & 0xFF) << (8 * i)
    return acc


def main():
    os.makedirs(MEM, exist_ok=True)
    W = gen_weights()
    img = gen_image()
    res = forward(img, W)
    dg = digest(res)

    def wr(name, lines):
        with open(os.path.join(MEM, name), 'w') as f:
            f.write('\n'.join(lines) + '\n')
        print(name, len(lines), 'lines')

    wr('img.mem', ['%02x' % b8(v) for v in img])

    # conv1: 16 lanes x 1 word (ic0)
    wr('w1.mem', ['%018x' % word9(W['w1'][L]) for L in range(16)])

    # conv2: lane-major then ic -> 256 lines
    wr('w2.mem', ['%018x' % word9(W['w2'][L][ic])
                  for L in range(16) for ic in range(16)])

    # fc: 16 lanes x 88 words (9 weights/word); lanes 10..15 zero
    fc_lines = []
    for L in range(16):
        for g in range(88):
            if L < 10:
                ws = W['wfc'][L][9 * g:9 * g + 9]
                ws += [0] * (9 - len(ws))
            else:
                ws = [0] * 9
            fc_lines.append('%018x' % word9(ws))
    wr('wfc.mem', fc_lines)

    # biases: 16 conv1 + 16 conv2 + 10 fc (int32 two's complement)
    wr('bias.mem', ['%08x' % (b & 0xFFFFFFFF)
                    for b in (W['b1'] + W['b2'] + W['bfc'])])

    # unified per-lane weight RAM: 16 lanes x 128 x 72b
    #   word 0      = conv1 (ic0)
    #   word 1+ic   = conv2 channel ic   (ic = 0..15)
    #   word 17+g   = fc group g         (g = 0..87)
    wmem = []
    for L in range(16):
        lane = [0] * 128
        lane[0] = word9(W['w1'][L])
        for ic in range(16):
            lane[1 + ic] = word9(W['w2'][L][ic])
        for g in range(88):
            if L < 10:
                ws = W['wfc'][L][9 * g:9 * g + 9]
                ws += [0] * (9 - len(ws))
            else:
                ws = [0] * 9
            lane[17 + g] = word9(ws)
        wmem.extend('%018x' % v for v in lane)
    wr('wmem.mem', wmem)
    # split halves for 2x36b BSRAM packing (lo = bits 35:0, hi = bits 71:36)
    wr('wmem_lo.mem', ['%09x' % (int(x, 16) & 0xFFFFFFFFF) for x in wmem])
    wr('wmem_hi.mem', ['%09x' % ((int(x, 16) >> 36) & 0xFFFFFFFFF)
                       for x in wmem])

    # expected intermediates (digest order: pos-major, channel inner)
    fa = [res['fmap_a'][ch][p] for p in range(196) for ch in range(16)]
    fb = [res['fmap_b'][ch][p] for p in range(49) for ch in range(16)]
    wr('exp_fmap_a.mem', ['%02x' % v for v in fa])
    wr('exp_fmap_b.mem', ['%02x' % v for v in fb])
    wr('exp_scores.mem', ['%08x' % (s & 0xFFFFFFFF) for s in res['scores']])

    golden = dict(
        seed=SEED, s1=S1, s2=S2,
        scores=res['scores'],
        digest='%08x' % dg,
        argmax=max(range(10), key=lambda i: res['scores'][i]),
        digest_nbytes=len(digest_bytes(res)),
    )
    with open(os.path.join(MEM, 'golden.json'), 'w') as f:
        json.dump(golden, f, indent=2)
    print('golden.json', golden)


if __name__ == '__main__':
    main()
