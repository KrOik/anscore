"""SPDX-License-Identifier: Apache-2.0. Whole-record integer set oracle.

No RTL/helper/upstream import. Execute only after frozen source/plan review.
"""
from pathlib import Path
import json
import sys

PROFILES = [(4, 2, 1, 0), (8, 8, 8, 0), (12, 8, 32, 0), (8, 8, 8, 1)]


def rne(a, b):
    q, r = divmod(a * 65536, b)
    return q + (2 * r > b or (2 * r == b and q % 2 == 1))


def signed16(v):
    return (v & 32767) - (v & 32768)


def oracle(case, profile):
    ml, mh, tw, ex = profile
    l, h, r, lo, hi = case['config']
    zero = [0] * (mh + 10)
    legal = (4 <= l <= ml and 2 <= h <= mh and 0 <= r <= 2 and
             2*r+1 <= lo <= hi and h*hi+r < 2**(l-1))
    if not legal:
        return [1, 0] + zero
    samples = case['samples']
    n = 2**l
    early = next((j+1 for j, (_, last, _) in enumerate(samples) if last and j+1 != n), None)
    if early is not None:
        return [2, early] + zero
    if not samples[-1][1]:
        return [3, n] + zero
    if any(bad for _, _, bad in samples):
        return [4, n] + zero
    power = [(signed16(raw)**2 + signed16(raw >> 16)**2) if ex else raw
             for raw, _, _ in samples]
    peak = max(range(lo, hi+1), key=lambda k: power[k])
    if power[peak] == 0:
        return [5, n] + zero
    if case['action'] == 2:
        return [6, n] + zero
    regions = [set(range(order*peak-r, order*peak+r+1)) for order in range(1, h+1)]
    assert all(not (a & b) for j, a in enumerate(regions) for b in regions[j+1:])
    assert all(0 < k < n//2 for region in regions for k in region)
    components = [sum(power[k] for k in region) for region in regions] + [0]*(mh-h)
    fundamental = components[0]
    harmonic = sum(components[1:])
    residual_bins = set(range(1, n//2)) - set.union(*regions)
    residual = sum(power[k] for k in residual_bins)
    total = sum(power[1:n//2])
    assert total == fundamental + harmonic + residual
    numerators = [harmonic, fundamental, fundamental]
    denominators = [fundamental, residual, harmonic+residual]
    ratios = [rne(a, b) if b else 0 for a, b in zip(numerators, denominators)]
    valid = sum((b != 0) << j for j, b in enumerate(denominators))
    return [0, n, peak, power[peak], total, fundamental, harmonic, residual, *ratios, valid, *components]


def cases(profile):
    ml, mh, tw, ex = profile
    records = []

    def sig(a, b=0):
        return ((b & 65535) << 16) | (a & 65535) if ex else a*a+b*b

    def add(config=(4, 2, 0, 1, 1), values=None, *, samples=None, action=0, target=0, name='base'):
        legal_l = config[0] if 4 <= config[0] <= ml else 4
        if samples is None:
            values = values if values is not None else {1:sig(10), 2:sig(2), 5:sig(1)}
            samples = [(values.get(k, 0), k == 2**legal_l-1, False) for k in range(2**legal_l)]
        case = dict(config=config, samples=samples, action=action, target=target, name=name,
                    tag=(len(records)*37+3) & (2**tw-1))
        if not (4 <= config[0] <= ml and 2 <= config[1] <= mh and 0 <= config[2] <= 2 and
                2*config[2]+1 <= config[3] <= config[4] and config[1]*config[4]+config[2] < 2**(config[0]-1)):
            case['samples'] = []
        records.append(case)

    add(name='base_components')
    add(values={0:sig(-32768,-32768), 1:sig(10), 15:sig(-32768), 8:sig(32767)}, name='dc_nyquist_negative_excluded')
    add(values={1:sig(10)}, name='pure_fundamental_zero_residual_and_harmonic')
    add(values={1:sig(10), 2:sig(2)}, name='zero_residual_nonzero_harmonic')
    add(values={1:sig(10), 5:sig(2)}, name='zero_harmonic_nonzero_residual')
    add(values={}, name='all_zero_no_fundamental')
    add(values={5:sig(32767)}, name='search_empty_strong_external_peak')
    add((4,2,0,1,3), {1:sig(10),2:sig(10),3:sig(10),7:sig(32767)}, name='earliest_equal_search_peaks')
    add((4,2,1,3,3), {3:sig(10),2:sig(2),4:sig(3),5:sig(1),6:sig(2),7:sig(3),1:sig(4)}, name='radius1_disjoint_min_spacing')
    add((4,2,1,3,3), {3:sig(256,256),5:sig(1)}, name='thd_even_half_tie')
    add((4,2,1,3,3), {3:sig(256,256),5:sig(1),6:sig(1),7:sig(1)}, name='thd_odd_half_tie')
    add((4,2,0,1,1), {1:sig(1),5:sig(256,256)}, name='snr_even_half_tie')
    add((4,2,1,3,3), {2:sig(1),3:sig(1),4:sig(1),1:sig(256,256)}, name='snr_odd_half_tie')
    if ml >= 5:
        add((5,mh,0,1,1), {k:sig(11-k) for k in range(1,mh+1)}, name='maximum_harmonics')
        add((5,2,2,5,5), {k:sig((k%5)+1) for k in range(1,16)}, name='radius2_complete_windows')
    max_value = sig(-32768,-32768) if ex else 0xffffffff
    add((ml,2,0,1,1), {k:max_value for k in range(2**ml)}, name='full_capacity_full_unsigned_power')
    # Deterministic arithmetic sequence, no random dependency or floating point.
    for j in range(4):
        l = min(ml, 5+j)
        r = min(j, 2)
        lo = 2*r+1
        if 2*lo+r >= 2**(l-1):
            r, lo = 0, 1
        hi = min(lo+2, (2**(l-1)-r-1)//2)
        values = {k:sig(((k*17+j*11)%97)-48, ((k*7+j)%31)-15) for k in range(2**l)}
        add((l,2,r,lo,hi), values, name='deterministic_spectrum_%d'%j)
    for config in [(3,2,0,1,1),(ml+1,2,0,1,1),(0x80000004,2,0,1,1),
                   (4,1,0,1,1),(4,mh+1,0,1,1),(4,0x80000002,0,1,1),
                   (4,2,3,1,1),(4,2,0x80000000,1,1),(4,2,1,2,2),
                   (4,2,0,0,1),(4,2,0,3,2),(4,2,0,1,4),
                   (4,2,0,1,0xffffffff),(4,2,0,0xffffffff,0xffffffff),
                   (4,2,2,5,5)]:
        add(config, name='bad_full_width_config')
    raw = [(sig(10) if k == 1 else sig(2) if k == 2 else 0,k==15,False) for k in range(16)]
    early = raw[:5]
    early[-1] = (early[-1][0], True, True)
    add(samples=early, name='early_last_precedes_invalid')
    missing = raw.copy()
    missing[-1] = (0,False,True)
    add(samples=missing, name='missing_last_precedes_invalid')
    for index in [0,15]:
        invalid = raw.copy()
        invalid[index] = (*invalid[index][:2],True)
        add(samples=invalid,name='invalid_sample_%d'%index)
    add(name='recovery_after_errors')
    for target in range(1,13):
        add(action=1,target=target,name='cancel_state_%d'%target)
        add(name='recovery_state_%d'%target)
    add(action=2,name='defensive_divider_fault')
    add(name='recovery_after_arithmetic_fault')
    return records


def prepare(index, directory):
    profile = PROFILES[index]
    records = cases(profile)
    sw = 32+profile[0]-1
    lines = []
    descriptions = []
    for i, case in enumerate(records):
        result = oracle(case, profile)
        status, received, peak, pp, total, fundamental, harmonic, residual, thd, snr, sinad, valid, *components = result
        packed = sum(v << (j*sw) for j,v in enumerate(components))
        header = [i,case['action'],case['target'],*case['config'],case['tag'],len(case['samples']),
                  status,received,peak,pp,total,fundamental,harmonic,residual,thd,snr,sinad,valid,packed]
        lines.append(' '.join(format(v,'x') for v in header))
        lines.extend('%x %x %x'%sample for sample in case['samples'])
        descriptions.append(dict(id=i,name=case['name'],action=case['action'],target=case['target'],
                                 config=case['config'],samples=len(case['samples']),expected_status=status))
    directory = Path(directory)
    directory.joinpath('vectors%d.txt'%index).write_text('\n'.join(lines)+'\n',encoding='ascii',newline='\n')
    counters = dict(cases=len(records),commands=len(records),responses=sum(c['action']!=1 for c in records),
                    resets=1+sum(c['action']==1 for c in records),faults=sum(c['action']==2 for c in records))
    counters['held'] = 5*counters['responses']
    directory.joinpath('preparation%d.json'%index).write_text(json.dumps(dict(
        expected_counters=counters,cases=descriptions,oracle='whole-record integer sets, sums, divmod RNE',
        preparation_profile=index),indent=2)+'\n',encoding='utf8',newline='\n')
    print('PREPARED spectral_harmonic_quality profile=%d cases=%d'%(index,len(records)))


if __name__ == '__main__':
    if len(sys.argv)!=4 or sys.argv[1]!='--prepare-reviewed-profile':
        raise SystemExit('Requires root-reviewed finite plan; no implicit preparation')
    prepare(int(sys.argv[2]),sys.argv[3])
