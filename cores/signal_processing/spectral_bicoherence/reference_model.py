"""SPDX-License-Identifier: Apache-2.0.
Independent expanded-polynomial oracle, whole-record reductions and Fraction.
No import-time work, HDL calls, inherited imports or third-party dependencies.
"""
from fractions import Fraction
from pathlib import Path
import argparse, hashlib, json

PROFILES = [
 dict(name='d2_a1_t1', data=2, maximum=1, tag=1, example=0, bins=1, bin1=0, bin2=0, cases=10, aborts=4),
 dict(name='d12_a9_t8', data=12, maximum=9, tag=8, example=0, bins=1, bin1=0, bin2=0, cases=14, aborts=4),
 dict(name='d16_a256_t32', data=16, maximum=256, tag=32, example=0, bins=1, bin1=0, bin2=0, cases=3, aborts=0),
 dict(name='frames_d12_a64_b17', data=12, maximum=64, tag=8, example=1, bins=17, bin1=2, bin2=5, cases=14, aborts=4),
 dict(name='frames_d2_a1_b1', data=2, maximum=1, tag=1, example=1, bins=1, bin1=0, bin2=0, cases=10, aborts=4)]


def rounded_even(value):
 q, r = divmod(value.numerator, value.denominator)
 return q + int(2*r > value.denominator or (2*r == value.denominator and q % 2))


def measure(triples):
 # Expanded triple polynomial; U uses |X|^2|Y|^2, unlike RTL's |XY|^2.
 real = sum(a*c*e-b*d*e+a*d*f+b*c*f for a,b,c,d,e,f in triples)
 imag = sum(a*d*e+b*c*e-a*c*f+b*d*f for a,b,c,d,e,f in triples)
 u = sum((a*a+b*b)*(c*c+d*d) for a,b,c,d,e,f in triples)
 v = sum(e*e+f*f for a,b,c,d,e,f in triples)
 numerator, denominator = real*real+imag*imag, u*v
 assert 0 <= numerator <= denominator
 if denominator == 0:
  return (3, 0, real, imag, u, v)
 return (0, rounded_even(Fraction(65536*numerator, denominator)), real, imag, u, v)


def pack(lanes, width):
 return sum((value & ((1 << width)-1)) << (index*width) for index,value in enumerate(lanes))


def recipe(p):
 d, maximum, ex = p['data'], p['maximum'], p['example']
 lo, hi = -(1 << (d-1)), (1 << (d-1))-1
 ordinary = min(maximum, 8)
 def triples(kind, count):
  rows = []
  down = [181,-181,2,-2,1,-1,2,0]
  up = [313,-313,18,-18,1,-1,4,2]
  for i in range(count):
   if kind == 'zero': row = (0,0,0,0,0,0)
   elif kind == 'zero_z': row = (lo,hi,hi,lo,0,0)
   elif kind == 'minimum': row = (lo,lo,lo,lo,lo,lo)
   elif kind == 'coherent': row = (hi,0,1,0,0,hi if i % 2 == 0 else max(1,hi//2))
   elif kind == 'cancel': row = (1,0,1,0,1 if i % 2 == 0 else -1,0)
   elif kind == 'tie_down': row = (down[i],0,1,0,1,0)
   elif kind == 'tie_up': row = (up[i],0,1,0,1,0)
   else:
    mask = (1 << d)-1
    row = tuple((((i+1)*(j+3)*(i+j+5)+j*7) & mask)+lo for j in range(6))
   rows.append(row)
  return rows
 def make(name, kind, count=ordinary, bad=None):
  rows = triples(kind, count)
  words = []
  if ex:
   b1,b2,b3 = p['bin1'],p['bin2'],p['bin1']+p['bin2']
   if p['bins'] == 1:
    # All selected bins coincide: one actual bin supplies X=Y=Z.
    rows = [(r[0],r[1])*3 for r in rows]
   for row in rows:
    selected = {b1:row[0:2], b2:row[2:4], b3:row[4:6]}
    for j in range(p['bins']):
     lanes = selected.get(j, ((j % 3)-1, 0))
     words.append((pack(lanes,d), int(j == p['bins']-1)))
  else:
   words = [(pack(row,d),int(i == count-1)) for i,row in enumerate(rows)]
  expected = measure(rows)
  if bad is not None:
   word,last = words[bad]
   words = words[:bad]+[(word,1-last)]
   expected = (5 if ex else 2,0,0,0,0,0)
  return dict(name=name, averages=count, samples=words, expected=expected)
 def invalid(value):
  return dict(name='invalid_'+str(value),averages=value,samples=[],expected=(1,0,0,0,0,0))
 if d == 16:
  return [invalid(0x80000000),make('maximum_full_scale','minimum',maximum),make('maximum_mixed','mixed',maximum)]
 cases = [invalid(0), invalid(maximum+1), invalid(0x80000000),
  make('all_zero','zero'),make('zero_z','zero_z'),make('signed_minima','minimum'),
  make('complex_mixed','mixed'), make('bad_first_last','mixed',bad=0),
  make('bad_final_last','mixed',bad=ordinary*p['bins']-1),make('recovery','minimum',1)]
 if maximum >= 8:
  cases += [make('positive_quadrature','coherent'),make('exact_cancellation','cancel'),
            make('rne_half_to_even_zero','tie_down',8),make('rne_half_to_even_two','tie_up',8)]
  assert cases[-2]['expected'][1] == 0 and cases[-1]['expected'][1] == 2
 return cases


def prepare(index, destination):
 p = PROFILES[index]
 cases = recipe(p)
 assert len(cases) == p['cases']
 d, lg = p['data'], (p['maximum']-1).bit_length()
 b,u,v = 3*d+2+lg,4*d+3+lg,2*d+1+lg
 lines = [str(len(cases))]
 details = []
 for case in cases:
  status,q,real,imag,usum,vsum = case['expected']
  assert 0 <= q <= 65536 and -(1 << (b-1)) <= real < (1 << (b-1))
  assert -(1 << (b-1)) <= imag < (1 << (b-1)) and 0 <= usum < (1 << u) and 0 <= vsum < (1 << v)
  lines.append(f"{case['averages']} {len(case['samples'])} {status} {q} {real & ((1<<b)-1):x} {imag & ((1<<b)-1):x} {usum:x} {vsum:x}")
  lines += [f'{word:x} {last}' for word,last in case['samples']]
  details.append(dict(name=case['name'], averages=case['averages'], input_beats=len(case['samples']), status=status, q16=q))
 destination.mkdir(parents=True,exist_ok=False)
 vector = ('\n'.join(lines)+'\n').encode('ascii')
 (destination/'vectors.txt').write_bytes(vector)
 counters = dict(cases=p['cases'],commands=2*p['cases']+2*p['aborts'],
  results=2*p['cases']+p['aborts'],future_commands=p['cases'],future_results=p['cases'],
  resets=p['aborts']+1,cancelled=p['aborts'],
  input_beats=sum(len(case['samples']) for case in cases)+3*p['bins']*int(p['aborts']>0))
 summary = dict(profile=p,preparation_calls=1,cases=details,expected_counters=counters,
  vector_bytes=len(vector),vector_sha256=hashlib.sha256(vector).hexdigest(),
  oracle='Expanded integer cubic polynomial, independent power product and one Fraction/RNE')
 (destination/'preparation.json').write_text(json.dumps(summary,indent=2)+'\n',encoding='utf-8',newline='\n')
 print(f"PREPARED spectral_bicoherence profile={index} cases={len(cases)}")


if __name__ == '__main__':
 parser = argparse.ArgumentParser()
 parser.add_argument('--profile',type=int,choices=range(len(PROFILES)),required=True)
 parser.add_argument('--output',type=Path,required=True)
 args = parser.parse_args()
 prepare(args.profile,args.output)
