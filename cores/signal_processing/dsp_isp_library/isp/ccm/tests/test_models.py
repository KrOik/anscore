"""ISP-14 model self-checks: legality predicate, bit-exact vs float bound,
identity passthrough, tone bypass, PWL node semantics.  Pure stdlib."""
import pathlib
import random
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / 'models'))
from model import (Config, Shadow, ROW_GAIN_MAX, identity_nodes, mpx,
                   packpix, pixel, float_pixel, tone_chan, quantize,
                   LIN_BASE)


def main():
    r = random.Random(20260926)
    for bits in (8, 10):
        mx = mpx(bits)
        ident = Config(bits=bits)
        # identity matrix + tone off -> passthrough for all-extreme and random
        for px in (0, packpix([mx] * 3, bits)) + tuple(
                packpix([r.randrange(mx + 1) for _ in range(3)], bits)
                for _ in range(200)):
            assert pixel(px, ident) == px
        # legality: row bound
        assert not Config(matrix=(20000, 20000, 20000) + (0,) * 6,
                          bits=bits).legal()
        assert Config(matrix=(8192, 8192, 8192) + (0,) * 6,
                      bits=bits).legal()          # row sum 3.0 <= 7.0
        # legality: non-monotone / over-range nodes
        ln = identity_nodes(bits) * 3
        ln[5], ln[6] = mx, 0
        assert not Config(lin=tuple(ln), bits=bits).legal()
        ln = identity_nodes(bits) * 3
        ln[5] = mx + 1
        assert not Config(lin=tuple(ln), bits=bits).legal()
        # quantize: half-away, clamps
        assert quantize(8192, bits) == 1
        assert quantize(8192 + 4095, bits) == 1
        assert quantize(8192 + 4096, bits) == 2      # tie rounds up
        assert quantize(-4096, bits) == 0            # -0.5 -> -1 -> clamp
        assert quantize(-1 << 20, bits) == 0
        assert quantize((mx + 100) << 13, bits) == mx
        # bit-exact vs float: matrix-only and matrix+tone bounded error
        cfgs = [Config(matrix=(12000, -2000, -500, -800, 11000, -900,
                              0, -300, 10000), bias=(3, -5, 8), bits=bits),
                Config(matrix=(8192, 0, 0, 0, 8192, 0, 0, 0, 8192),
                       tone_en=(1, 1, 1), bits=bits,
                       lin=tuple(identity_nodes(bits) * 3)),
                Config(matrix=(8192, 0, 0, 0, 8192, 0, 0, 0, 8192),
                       tone_en=(1, 0, 1), domain=1, bits=bits,
                       enc=tuple([min(mx, i * i // 4) for i in range(33)] * 3))]
        worst = 0
        for cfg in cfgs:
            assert cfg.legal()
            for _ in range(2000):
                px = packpix([r.randrange(mx + 1) for _ in range(3)], bits)
                a, b = pixel(px, cfg), float_pixel(px, cfg)
                for c in range(3):
                    da = abs(((a >> (c * bits)) & mx) - ((b >> (c * bits)) & mx))
                    worst = max(worst, da)
        assert worst <= 2, worst           # spec: <= 2 LSB total
        # shadow bank write/commit legality mirrors RTL predicate
        sh = Shadow(bits)
        assert sh.commit_legal()           # reset image is legal
        assert not sh.write(0x77, 1)       # unmapped write -> error
        assert not sh.write(LIN_BASE, mx + 1)   # out-of-range node -> error
        assert sh.write(LIN_BASE, mx)      # boundary node lands
        assert sh.write(0x00, 0x00F0)      # ctrl write lands
        assert not sh.commit_legal()       # reserved bits -> illegal
    print('PASS ccm models')


if __name__ == '__main__':
    main()
