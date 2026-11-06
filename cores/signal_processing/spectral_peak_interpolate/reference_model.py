"""SPDX-License-Identifier: Apache-2.0. Direct whole-frame integer oracle.

No RTL helper, scheduler, runner or external numeric package is imported.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import random


def rne(numerator, denominator):
    sign = -1 if numerator < 0 else 1
    q, r = divmod(abs(numerator), denominator)
    return sign * (q + (2*r > denominator or (2*r == denominator and q % 2)))


def cases(max_log2n, iq, tag_w):
    rng = random.Random(470102 + max_log2n + iq)
    frames = []
    for case in range(32):
        logn = 4 if case < 16 else min(max_log2n, 4 + case % (max_log2n-3))
        if case == 31:
            logn = max_log2n
        n = 1 << logn
        low, high, threshold = 1, n-2, 0
        if iq:
            data = [(rng.randint(-240,240)&65535) | ((rng.randint(-240,240)&65535)<<16) for _ in range(n)]
        else:
            data = [rng.randrange(0,100) for _ in range(n)]
        if case == 0:
            data = [1]*n
            data[6:9] = [30*30,40*40,35*35] if not iq else [30,40,35]
        elif case == 1:
            data = [0]*n
        elif case == 2:
            data = [0x80008000 if iq else 0xffffffff]*n
        elif case in (3,4):
            low = high = 7
            data = [0]*n
            data[6:9] = ([40,40,30] if case==3 else [30,40,40]) if iq else ([1000,1000,900] if case==3 else [900,1000,1000])
        elif case == 5:
            low = high = 7
            data[6:9] = [100,40,90] if iq else [4000,1000,3000]
        elif case == 6:
            data = [1]*n
            data[4] = data[10] = 100 if iq else 12345
        elif case == 7:
            threshold = 0xffffffff
        elif case == 8:
            data = [0]*n
            data[7] = 0x80008000 if iq else 0xffffffff
        elif case == 9:
            # Exact rational RNE tie: D=2,K=131072 => offset=0.5 -> even 0.
            low = high = 7
            if not iq:
                data[6:9] = [65535,131072,65537]
        elif case == 10:
            low = high = 7
            if not iq:
                data[6:9] = [65533,131072,65539]  # Q16 offset=1.5 -> even 2.
        elif case == 11:
            # FFT-like one-tone spectra; direct DFT, no FFT implementation reuse.
            freq = 3.23
            samples = [complex(math.cos(2*math.pi*freq*t/n), math.sin(2*math.pi*freq*t/n))*(0.5-0.5*math.cos(2*math.pi*t/n)) for t in range(n)]
            values = [sum(samples[t]*complex(math.cos(-2*math.pi*k*t/n),math.sin(-2*math.pi*k*t/n)) for t in range(n)) for k in range(n)]
            if iq:
                data = [(round(v.real*120)&65535)|((round(v.imag*120)&65535)<<16) for v in values]
            else:
                data = [round(abs(v)**2*100000) for v in values]
        elif case == 12:
            threshold = 1600 if not iq else 1600
            data = [0]*n
            data[7] = 40 if iq else 1600
        power = []
        for value in data:
            if iq:
                a,b=value&65535,value>>16
                a=a-65536 if a&32768 else a
                b=b-65536 if b&32768 else b
                power.append(a*a+b*b)
            else:
                power.append(value)
        status, supplied, received = 0, n, n
        last = [0]*(n-1)+[1]
        invalid = [0]*n
        if case in (13,14,15,16,17,18):
            if case==13:logn=0x10000004
            if case==14:low=0
            if case==15:high=n-1
            if case==16:low,high=8,7
            if case==17:logn=max_log2n+1
            if case==18:high=0x80000000
            status,supplied,received=1,0,0
        elif case==19:
            supplied,received,status=3,3,3
            last[2]=1
        elif case==20:
            status=4;last[-1]=0
        elif case==21:
            supplied,received,status=5,5,2
            invalid[4]=1
        elif case==22:
            supplied,received,status=2,2,2
            invalid[1]=1;last[1]=1
        elif case==23:
            supplied,received,status=n,n,2
            invalid[-1]=1
        index=left=center=right=curve=offset=refined=valid=0
        if status==0:
            index=max(range(low,high+1),key=lambda k:power[k])
            left,center,right=power[index-1:index+2]
            curve=2*center-left-right
            valid=int(center>0 and center>=threshold and center>=left and center>=right and curve>0)
            offset=rne((right-left)*65536,2*curve) if valid else 0
            refined=index*65536+offset
        frames.append(dict(header=[logn,low,high,threshold,((case+1)*0x13579bdf)&((1<<tag_w)-1),supplied,status,received,index,left,center,right,curve,offset,refined,valid],
            rows=list(zip(data[:supplied],last[:supplied],invalid[:supplied]))))
    return frames


def main():
    p=argparse.ArgumentParser()
    p.add_argument('--profile',required=True)
    p.add_argument('--max-log2n',type=int,required=True)
    p.add_argument('--tag-w',type=int,required=True)
    p.add_argument('--iq',type=int,required=True)
    p.add_argument('--out',type=Path,required=True)
    a=p.parse_args()
    frames=cases(a.max_log2n,a.iq,a.tag_w)
    a.out.mkdir(parents=True,exist_ok=False)
    text='32\n'+''.join(' '.join(map(str,f['header']))+'\n'+''.join(f'{v:08x} {last} {invalid}\n' for v,last,invalid in f['rows']) for f in frames)
    path=a.out/'vectors.txt';path.write_bytes(text.encode('ascii'))
    counters=dict(cases=32,results=46,holds=184,cancellations=14,recoveries=14,continuous=1)
    value=dict(profile=a.profile,cases=32,expected_counters=counters,oracle_definition_loads=1,numerical_preparations=1,
        files={'vectors.txt':dict(sha256=hashlib.sha256(path.read_bytes()).hexdigest(),bytes=path.stat().st_size,rows=len(text.splitlines())-1)})
    (a.out/'preparation.json').write_text(json.dumps(value,indent=2)+'\n',encoding='utf-8')
    print('PREP '+' '.join(f'{k}={v}' for k,v in counters.items()))


if __name__=='__main__':
    main()
