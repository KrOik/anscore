"""SPDX-License-Identifier: Apache-2.0.
Independent whole-batch column reductions and exact rational SK. No HDL calls,
import-time preparation, inherited runner/model imports, NumPy or external code.
Only one archived preparation child per explicitly reviewed profile may run.
"""
from fractions import Fraction
from pathlib import Path
import argparse, hashlib, json

PROFILES = [
 dict(name='b1_m2_p1_f0_t1', bins=1, frames=2, power=1, frac=0, tag=1, example=0, cases=10, aborts=8),
 dict(name='b7_m3_p12_f1_t8', bins=7, frames=3, power=12, frac=1, tag=8, example=0, cases=10, aborts=8),
 dict(name='b256_m64_p32_f16_t32', bins=256, frames=64, power=32, frac=16, tag=32, example=0, cases=2, aborts=0),
 dict(name='iq_b4_m5_f12_t8', bins=4, frames=5, power=32, frac=12, tag=8, example=1, cases=10, aborts=8)]


def rne(value):
 q, r = divmod(value.numerator, value.denominator)
 return q + int(2*r > value.denominator or (2*r == value.denominator and q % 2 == 1))


def complex_word(real, imag):
 return (real & 65535) | ((imag & 65535) << 16)


def input_power(word, example):
 if not example:
  return word
 real, imag = word & 65535, word >> 16
 real = real-65536 if real >= 32768 else real
 imag = imag-65536 if imag >= 32768 else imag
 return real*real + imag*imag


def cases_for(p):
 b, m, w, f = p['bins'], p['frames'], p['power'], p['frac']
 max_power = (1 << w)-1
 peak_word = complex_word(-32768, -32768) if p['example'] else max_power
 one_word = complex_word(1, 0) if p['example'] else 1
 q_width = f + (m+1).bit_length()
 def matrix(kind):
  words = []
  for frame in range(m):
   for bin_index in range(b):
    if kind == 'zero':
     word = 0
    elif kind == 'constant':
     word = peak_word
    elif kind == 'one':
     word = one_word
    elif kind == 'impulse':
     word = peak_word if frame == 0 else 0
    elif kind == 'maxmixed':
     if bin_index % 4 == 0:
      word = max_power
     elif bin_index % 4 == 1:
      word = 0
     elif bin_index % 4 == 2:
      word = max_power if frame == 0 else 0
     else:
      word = max_power if frame % 2 == 0 else 0
    elif p['example']:
     lanes = [(-32768, 0), (32767, -1), (3, 4), (-7, 2), (0, 0)]
     real, imag = lanes[(3*frame+bin_index+(kind == 'recovery')) % len(lanes)]
     word = complex_word(real, imag)
    elif kind == 'ties' and m == 3:
     # At F=1: [1,1,2] gives0.5 -> even0; [0,1,3] gives3.5 -> even4.
     word = ([1,1,2] if bin_index % 2 == 0 else [0,1,3])[frame]
    else:
     word = ((frame+1)*(bin_index+3)*(frame+bin_index+5)+17*frame+3*bin_index) & max_power
    words.append(word)
  return words
 def case(name, kind, lower=0, upper=None, bad_index=None):
  upper = ((m+1) << f) if upper is None else upper
  words = matrix(kind)
  samples = [(word, int(index % b == b-1)) for index, word in enumerate(words)]
  if bad_index is not None:
   word, last = samples[bad_index]
   samples = samples[:bad_index] + [(word, 1-last)]
  return dict(name=name, lower=lower, upper=upper, samples=samples)
 invalid = dict(name='invalid_reversed_bounds', lower=(1 << q_width)-1, upper=0, samples=[])
 if b == 256 and m == 64:
  return [invalid, case('maximum_accumulators_zero_impulse_and_alternating', 'maxmixed', 1 << f, 1 << f)]
 return [invalid, case('all_zero_undefined', 'zero'),
  case('constant_max_below_unity', 'constant', 1 << f, 1 << f),
  case('single_full_scale_impulse_above_unity', 'impulse', 1 << f, 1 << f),
  case('mixed_columns', 'mixed'), case('signed_fft_extrema_or_rne_ties', 'ties'),
  case('inclusive_equal_bounds', 'one', 0, 0),
  case('bad_first_last', 'mixed', bad_index=0),
  case('bad_second_frame_last', 'mixed', bad_index=b),
  case('recovery_after_protocol_faults', 'recovery')]


def evaluate(case, p):
 if case['lower'] > case['upper']:
  return [[1, 0, 0, 0, 0, 0, 0, 0, 0, 1]]
 b, m, f = p['bins'], p['frames'], p['frac']
 for index, (_, last) in enumerate(case['samples']):
  if last != int(index % b == b-1):
   assert index == len(case['samples'])-1
   return [[2, index % b, 0, 0, 0, 0, 0, 0, 0, 1]]
 assert len(case['samples']) == b*m
 powers = [input_power(word, p['example']) for word, _ in case['samples']]
 rows = []
 for index in range(b):
  column = powers[index::b]
  first, second = sum(column), sum(value*value for value in column)
  if first == 0:
   rows.append([3, index, 0, 0, 0, 0, 0, 0, 0, int(index == b-1)])
  else:
   # Whole-column integer powers/sums; no RAM/update/square/divider schedule.
   numerator = (m+1)*(m*second-first*first)
   denominator = (m-1)*first*first
   ratio = Fraction(numerator*(1 << f), denominator)
   rounded = rne(ratio)
   assert 0 <= numerator <= (m+1)*denominator
   assert 0 <= rounded <= (m+1)*(1 << f)
   rows.append([0, index, first, second, numerator, denominator, rounded,
    int(ratio.denominator != 1), int(rounded < case['lower'] or rounded > case['upper']), int(index == b-1)])
 return rows


def prepare(index, destination):
 p = PROFILES[index]
 cases = cases_for(p)
 assert len(cases) == p['cases']
 lines, details = [str(len(cases))], []
 totals = dict(cases=len(cases), case_results=0, samples=0, status0=0, status1=0, status2=0,
  status3=0, inexact=0, outside=0, commands=2*len(cases)+p['aborts'],
  future_commands=len(cases), future_results=len(cases), resets=1+p['aborts'], cancelled=p['aborts'])
 for ci, case in enumerate(cases):
  rows = evaluate(case, p)
  lines.append('%d %x %x %d %d' % (ci, case['lower'], case['upper'], len(case['samples']), len(rows)))
  lines.extend('%x %d' % sample for sample in case['samples'])
  lines.extend('%d %d ' % (row[0], row[1])+' '.join(format(value, 'x') for value in row[2:]) for row in rows)
  totals['samples'] += len(case['samples'])
  totals['case_results'] += len(rows)
  for row in rows:
   totals['status'+str(row[0])] += 1
   totals['inexact'] += row[7]
   totals['outside'] += row[8]
  details.append(dict(index=ci, name=case['name'], lower=case['lower'], upper=case['upper'],
   samples=len(case['samples']), rows=len(rows), statuses=[row[0] for row in rows]))
 folder = Path(destination)
 folder.mkdir(parents=True, exist_ok=True)
 vector = ('\n'.join(lines)+'\n').encode('ascii')
 (folder/'vectors.txt').write_bytes(vector)
 summary = dict(schema='anscore-b44-sk-preparation-v1', profile=p, preparation_calls=1,
  oracle='Whole-column Python integers, exact Fraction and divmod nearest-even',
  vector_bytes=len(vector), vector_sha256=hashlib.sha256(vector).hexdigest(),
  expected_counters=totals, cases=details)
 (folder/'preparation.json').write_bytes((json.dumps(summary, indent=2)+'\n').encode())
 print('PREPARED spectral_kurtosis profile=%d cases=%d' % (index, len(cases)))


if __name__ == '__main__':
 parser = argparse.ArgumentParser()
 parser.add_argument('--profile', type=int, choices=range(4), required=True)
 parser.add_argument('--output', required=True)
 args = parser.parse_args()
 prepare(args.profile, args.output)
