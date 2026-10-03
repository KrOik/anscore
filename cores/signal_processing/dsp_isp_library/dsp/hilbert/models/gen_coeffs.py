"""Generate Hilbert FIR coefficients and the phase/envelope tables.

Usage:
  python gen_coeffs.py --pairs 16 --output coeffs.json
  python gen_coeffs.py --pairs 16 --emit-rtl            (print localparams)
"""
import argparse, json
from pathlib import Path
import reference as ref

p = argparse.ArgumentParser()
p.add_argument('--pairs', type=int, default=ref.PAIRS)
p.add_argument('--output', type=Path)
p.add_argument('--emit-rtl', action='store_true')
a = p.parse_args()

coeffs, h = ref.design(a.pairs)
metrics = ref.spectrum_metrics(coeffs, a.pairs)
report = {
    'pairs': a.pairs,
    'taps': 4 * a.pairs - 1,
    'group_delay_samples': 2 * a.pairs - 1,
    'coefficient_format': 'signed18 Q15; c_j multiplies '
                          '(x[n-C+d]-x[n-C-d]), d=2j+1',
    'coefficients': coeffs,
    'cfg_coeffs_hex': format(
        sum((c & 0x3ffff) << (18 * j) for j, c in enumerate(coeffs)), 'x'),
    'atan_table': {'entries': ref.ATAN_RES + 1, 'index': 'r[15:8]',
                   'units': 'brads (phase/2pi * 65536)',
                   'p': ref.ATAN_P, 'delta': ref.ATAN_D},
    'envelope': {'method': 'sigma=+/-1 CORDIC x-path, 16 iterations, '
                           'inputs <<4', 'scale_constant': ref.ENV_C,
                 'scale_shift': ref.ENV_SHIFT},
    'divider': {'iterations': ref.DIV_BITS,
                'quotient': 'floor(a*2^17/b), r=(q+1)>>1'},
    'spectrum': metrics,
    'scope': 'antisymmetric odd-length Hilbert; valid band is a measured '
             'property of this configuration, not a guarantee for '
             'user-loaded coefficients',
}
if a.emit_rtl:
    ptab = ", ".join(f"14'd{ref.ATAN_P[i]}" for i in range(256, -1, -1))
    dtab = ", ".join(f"6'd{ref.ATAN_D[i]}" for i in range(255, -1, -1))
    packed = sum((c & 0x3ffff) << (18 * j) for j, c in enumerate(coeffs))
    print(f"localparam [3597:0] PTAB = {{ {ptab} }};")
    print(f"localparam [1535:0] DTAB = {{ {dtab} }};")
    print(f"// DEFAULT_COEFFS = {a.pairs * 18}'h{packed:x}")
text = json.dumps(report, indent=2)
if a.output:
    with a.output.open('x', encoding='utf-8') as f:
        f.write(text)
else:
    if not a.emit_rtl:
        print(text)
