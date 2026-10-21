"""Integer radix-2 reference plus direct complex DFT accuracy oracle."""
import cmath
import math
import random


def transform(values, inverse):
    n=len(values)
    log_n=n.bit_length()-1
    data=[None]*n
    for index,value in enumerate(values):
        reverse=int(f'{index:0{log_n}b}'[::-1],2)
        data[reverse]=value
    length=2
    while length<=n:
        for base in range(0,n,length):
            for j in range(length//2):
                angle=2*math.pi*j/length
                wr=round(math.cos(angle)*32768)
                wi=round(-math.sin(angle)*32768)*(-1 if inverse else 1)
                ar,ai=data[base+j]
                br,bi=data[base+j+length//2]
                tr=(br*wr-bi*wi)>>15
                ti=(br*wi+bi*wr)>>15
                data[base+j]=ar+tr,ai+ti
                data[base+j+length//2]=ar-tr,ai-ti
        length*=2
    if inverse:
        data=[(re>>log_n,im>>log_n) for re,im in data]
    return data


def fixtures(folder, log_n, data_w=16):
    n=1<<log_n
    rng=random.Random(0xFF7+n)
    maximum=(1<<(data_w-1))-1
    minimum=-(1<<(data_w-1))
    amplitude=maximum//4
    patterns=[[(0,0)]*n, [(maximum,minimum)]+[(0,0)]*(n-1),
              [(maximum,maximum)]*n, [(minimum,minimum)]*n,
              [(maximum if i%2 else minimum,0) for i in range(n)],
              [(round(amplitude*math.cos(2*math.pi*i/n)),round(amplitude*math.sin(2*math.pi*i/n))) for i in range(n)],
              [(rng.randrange(minimum,maximum+1),rng.randrange(minimum,maximum+1)) for _ in range(n)]]
    inputs=[]
    expected=[]
    errors=0
    max_error=0.0

    def bad_packet(length, last):
        nonlocal errors
        for i in range(length):
            inputs.append(f"123 -42 0 {int(last and i==length-1)}\n")
        expected.append('0 0 1 1\n')
        errors+=1

    for inverse in (0,1):
        for p,values in enumerate(patterns):
            if p==1:
                bad_packet(1, True)
            if p==3:
                bad_packet(n, False)
            if p==5 and n>2:
                bad_packet(n//2,True)
            for i,(re,im) in enumerate(values):
                # Only the first accepted mode is meaningful; subsequent bits
                # intentionally change to verify frame-atomic mode capture.
                inputs.append(f"{re} {im} {inverse if i==0 else 1-inverse} {int(i==n-1)}\n")
            result=transform(values,inverse)
            for k,(re,im) in enumerate(result):
                direction=1 if inverse else -1
                exact=sum(complex(x,y)*cmath.exp(direction*2j*math.pi*k*i/n)
                          for i,(x,y) in enumerate(values))
                if inverse:
                    exact/=n
                error=max(abs(re-exact.real),abs(im-exact.imag))
                limit=4*log_n*(1 if inverse else n)+1
                assert error<limit,(n,inverse,k,error,limit)
                max_error=max(max_error,error)
                expected.append(f"{re} {im} {int(k==n-1)} 0\n")
    (folder/'input.txt').write_text(''.join(inputs),encoding='ascii')
    (folder/'expected.txt').write_text(''.join(expected),encoding='ascii')
    return {'n':n,'frames':len(patterns)*2,'error_frames':errors,
            'outputs':len(expected),'max_dft_component_error':max_error}
