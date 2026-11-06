"""SPDX-License-Identifier: Apache-2.0. Independent whole-record integer oracle.

No import-time preparation or HDL invocation. Run only as one explicitly gated,
isolated archived preparation child for one frozen profile.
"""
from collections import Counter
from fractions import Fraction
from pathlib import Path
import argparse, hashlib, json

PROFILES = [
 dict(name='n1_f0_t1', samples=1, frac=0, tag=1, example=0, cases=12, aborts=7),
 dict(name='n257_f7_t8', samples=257, frac=7, tag=8, example=0, cases=12, aborts=8),
 dict(name='n65535_f16_t32', samples=65535, frac=16, tag=32, example=0, cases=4, aborts=0),
 dict(name='trigger256_f12_t8', samples=256, frac=12, tag=8, example=1, cases=11, aborts=8)]


def rne(value):
 """Round a Fraction symmetrically to nearest integer, ties to even."""
 sign = -1 if value < 0 else 1
 n, d = abs(value.numerator), value.denominator
 q, r = divmod(n, d)
 return sign * (q + int(2*r > d or (2*r == d and q % 2 == 1)))


def cases_for(profile):
 n = profile['samples']
 def case(name, first, last, codes, malformed=False):
  samples = [(code, int(i == len(codes)-1)) for i, code in enumerate(codes)]
  if malformed:
   samples = [(code, int(i == 0 and n > 1)) for i, (code, _) in enumerate(samples)]
  return dict(name=name, first=first, last=last, samples=samples)
 invalid = case('reversed_range', 200, 100, [])
 ramp = case('all_codes_ramp', 0, 255, [i % 256 for i in range(n)])
 hot0 = case('all_at_code0', 0, 255, [0] * n)
 hot255 = case('all_at_code255', 0, 255, [255] * n)
 if n == 65535:
  return [invalid, ramp, hot0, hot255]
 ties = ([1]*83 + [2]*85 + [3]*88 + [0]) if n == 257 else [1 + (i % 3) for i in range(n)]
 result = [invalid,
  case('selected_range_empty', 240, 250, [0]*n),
  case('single_selected_code', 7, 7, [7]*n), hot0, hot255, ramp,
  case('cropped_8_to_23', 8, 23, [(i*37 + i//7) % 256 for i in range(n)]),
  case('sparse_three_codes', 1, 3, [0 if i % 5 == 0 else 1 + ((i*7 + i//11) % 3) for i in range(n)]),
  case('nonuniform_deterministic', 0, 255, [(i*i + 17*i + 39) % 256 for i in range(n)]),
  case('exclude_endpoint_codes', 1, 254, [i % 256 for i in range(n)]),
  case('signed_rne_ties', 1, 3, ties)]
 if not profile['example']:
  result.append(case('bad_last_framing', 0, 255, [i % 256 for i in range(n)], True))
 return result


def evaluate(case, profile):
 first, last = case['first'], case['last']
 if first > last:
  return 1, []
 samples = case['samples']
 assert len(samples) == profile['samples']
 if any(last_flag != int(i == len(samples)-1) for i, (_, last_flag) in enumerate(samples)):
  return 2, []
 histogram = Counter(code for code, _ in samples)
 selected = list(range(first, last+1))
 total = sum(histogram[code] for code in selected)
 if total == 0:
  return 3, []
 k = len(selected)
 rows = []
 # Whole-record sums and exact Fractions deliberately do not follow the RTL's
 # two RAM scans, shared multiplier, expected-prefix recurrence or divider FSM.
 for ordinal, code in enumerate(selected, 1):
  h = histogram[code]
  prefix = sum(histogram[c] for c in selected[:ordinal])
  dn, inn = k*h-total, k*prefix-ordinal*total
  dr, ir = Fraction(dn * 2**profile['frac'], total), Fraction(inn * 2**profile['frac'], total)
  rows.append([code, h, dn, inn, total, rne(dr), rne(ir),
               int(dr.denominator != 1), int(ir.denominator != 1), int(code == last)])
 assert rows[-1][3] == rows[-1][6] == 0
 assert sum(row[2] for row in rows) == 0
 return 0, rows


def prepare(profile_index, output):
 profile = PROFILES[profile_index]
 cases = cases_for(profile)
 assert len(cases) == profile['cases']
 text = [str(len(cases))]
 summaries = []
 totals = dict(cases=len(cases), rows=0, samples=0, zero_rows=0, dnl_inexact=0, inl_inexact=0,
               commands=2*len(cases)+profile['aborts'], future_commands=len(cases),
               resets=1+profile['aborts'], cancelled=profile['aborts'])
 for index, case in enumerate(cases):
  status, rows = evaluate(case, profile)
  text.append(' '.join(map(str, [index, case['first'], case['last'], len(case['samples']), len(rows), status])))
  text.extend(' '.join(map(str, sample)) for sample in case['samples'])
  text.extend(' '.join(map(str, row)) for row in rows)
  counts = dict(rows=len(rows), samples=len(case['samples']), zero_rows=sum(row[1] == 0 for row in rows),
                dnl_inexact=sum(row[7] for row in rows), inl_inexact=sum(row[8] for row in rows))
  for key, value in counts.items():
   totals[key] += value
  summaries.append(dict(index=index, name=case['name'], first=case['first'], last=case['last'], status=status, **counts))
 output = Path(output)
 output.mkdir(parents=True, exist_ok=True)
 data = ('\n'.join(text)+'\n').encode('ascii')
 (output/'vectors.txt').write_bytes(data)
 summary = dict(schema='anscore-b43-adc-density-preparation-v1', profile=profile,
  vector='vectors.txt', vector_sha256=hashlib.sha256(data).hexdigest(), vector_bytes=len(data),
  oracle='Counter, whole-record prefix sums, exact Fraction, signed divmod RNE',
  preparation_calls=1, expected_counters=totals, cases=summaries)
 (output/'preparation.json').write_bytes((json.dumps(summary, indent=2)+'\n').encode())
 print('PREPARED adc_code_density profile=%d cases=%d' % (profile_index, len(cases)))


if __name__ == '__main__':
 parser = argparse.ArgumentParser()
 parser.add_argument('--profile', type=int, choices=range(4), required=True)
 parser.add_argument('--output', required=True)
 args = parser.parse_args()
 prepare(args.profile, args.output)
