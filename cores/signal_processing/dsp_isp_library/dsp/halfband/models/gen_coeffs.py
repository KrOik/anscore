"""Coefficient/configuration generator for the DSP-10 half-band cores.

Usage:
  python gen_coeffs.py --kind halfband --taps 31 [--output f.json]
  python gen_coeffs.py --kind ciccomp --order 4 --rate 8 --taps 15 \
      --fp 0.2 [--output f.json]

Half-band output carries only the P unique nonzero coefficients (center
tap 0.5 and all (n-c)-even zeros are structural in RTL). The CIC
compensation table carries U=(taps+1)/2 unique symmetric coefficients;
`--order`/`--rate` name the compensated CIC (reference: N=4 R=8; the
existing sigproc_20k cic_dec8 is N=3 R=8 M=1). --fp is the passband edge
in cycles per *output* sample (fp/rate per input sample).
"""
import argparse, json
from pathlib import Path
import reference as ref

p = argparse.ArgumentParser()
p.add_argument('--kind', choices=['halfband', 'ciccomp'], required=True)
p.add_argument('--taps', type=int, required=True)
p.add_argument('--order', type=int, default=4)
p.add_argument('--rate', type=int, default=8)
p.add_argument('--fp', type=float, default=0.2)
p.add_argument('--output', type=Path)
a = p.parse_args()

if a.kind == 'halfband':
    uc, h, hq = ref.design_halfband(a.taps)
    report = {
        'kind': 'halfband', 'taps': a.taps,
        'unique_pairs': ref.pairs_of(a.taps),
        'center_tap': 'implicit 0.5 (16384 Q3.15)',
        'zero_taps': 'structural, (n-c) even',
        'coefficient_format': 'signed18 Q3.15, unique pair order lo_i..hi',
        'coefficients': uc,
        'cfg_taps_field': a.taps,
        'cfg_coeffs_hex': format(
            sum((c & 0x3ffff) << (18 * i) for i, c in enumerate(uc)), 'x'),
        'group_delay_input_samples': (a.taps - 1) / 2,
        'spectrum': ref.halfband_metrics(a.taps, uc),
        'scope': 'measured quantized metrics for this table only; '
                 'arbitrary user coefficients carry no spectral guarantee',
    }
else:
    uc, h, hq = ref.design_ciccomp(a.order, a.rate, a.taps, a.fp)
    report = {
        'kind': 'ciccomp', 'taps': a.taps,
        'unique_coeffs': (a.taps + 1) // 2,
        'cic_order': a.order, 'cic_rate': a.rate,
        'passband_edge_output_cycles': a.fp,
        'passband_edge_input_cycles': a.fp / a.rate,
        'coefficient_format': 'signed18 Q3.15, unique order g0..g_center',
        'coefficients': uc,
        'cfg_taps_field': a.taps,
        'cfg_coeffs_hex': format(
            sum((c & 0x3ffff) << (18 * i) for i, c in enumerate(uc)), 'x'),
        'group_delay_output_samples': (a.taps - 1) / 2,
        'spectrum': ref.ciccomp_metrics(a.order, a.rate, a.taps, uc, a.fp),
        'scope': 'compensates the stated CIC droop over [0,fp] at the '
                 'decimated rate; measured composite flatness is reported, '
                 'not guaranteed for other order/rate/fp combinations',
    }
text = json.dumps(report, indent=2)
if a.output:
    a.output.parent.mkdir(parents=True, exist_ok=True)
    with a.output.open('x', encoding='utf-8') as f:
        f.write(text)
else:
    print(text)
