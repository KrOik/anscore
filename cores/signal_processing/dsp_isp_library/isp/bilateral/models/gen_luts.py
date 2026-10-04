"""LUT generator for isp/bilateral (ISP-18).

Prints the spatial (sigma_d) and range (sigma_r) tables and their packed
hex strings in the exact bit order of the RTL parameters SLUT_INIT /
RLUT_INIT (entry N-1 in the most significant field, entry 0 in the least
significant).  Use the hex to patch the bilateral_stream parameters or to
build lut.mem reload fixtures for tests/test_bilateral.py.

Usage:
    python gen_luts.py [--sigma-d 1.0] [--sigma-r 25.0] [--bits 8]
"""
import argparse
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import model  # noqa: E402


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--sigma-d', type=float, default=model.SIGMA_D_REF)
    p.add_argument('--sigma-r', type=float, default=model.SIGMA_R_REF)
    p.add_argument('--bits', type=int, default=model.BITS)
    a = p.parse_args()
    slut = model.spatial_table(a.sigma_d)
    rlut = model.range_table(a.sigma_r, bits=a.bits)
    print('# sigma_d=%g sigma_r=%g bits=%d' % (a.sigma_d, a.sigma_r, a.bits))
    print('slut =', slut)
    print('SLUT_INIT = %d\'h%0*x' % (9 * model.WS_W, 9,
                                    model.pack_slut(slut)))
    print('rlut =', rlut)
    print('RLUT_INIT = %d\'h%0*x' % (model.RLN * model.WR_W,
                                    model.RLN * 2, model.pack_rlut(rlut)))
    # sanity: monotonic non-increasing, bin-0 weight is full scale
    assert all(rlut[i] >= rlut[i + 1] for i in range(len(rlut) - 1))
    assert rlut[0] == (1 << model.WR_W) - 1
    assert slut[4] == (1 << model.WS_W) - 1


if __name__ == '__main__':
    main()
