"""FFT serialized oracle using the fixed-point reference, with natural bin order."""
import math
import random
from fft_reference import transform


def fixtures(folder, log_n):
    n=1<<log_n
    rng=random.Random(0xF7A+n)
    patterns=[[(32767,-32768)]+[(0,0)]*(n-1),[(32767,32767)]*n,
              [(-32768,-32768)]*n,
              [(round(8192*math.cos(2*math.pi*i/n)),round(8192*math.sin(2*math.pi*i/n))) for i in range(n)],
              [(rng.randrange(-32768,32768),rng.randrange(-32768,32768)) for _ in range(n)]]
    inputs=[]
    outputs=[]
    for inverse in (0,1):
        for values in patterns:
            for i,(re,im) in enumerate(values):
                inputs.append(f'{inverse} {re} {im} {int(i==n-1)}\n')
            result=transform(values,inverse)
            for i,(re,im) in enumerate(result):
                for component,value in enumerate((re,im)):
                    outputs.append(f'{value & 65535} 0\n')
                    outputs.append(f'{(value >> 16) & 65535} {int(i==n-1 and component==1)}\n')
    (folder/'input.txt').write_text(''.join(inputs),encoding='ascii')
    (folder/'expected.txt').write_text(''.join(outputs),encoding='ascii')
    return {'n':n,'packets':10,'words':len(outputs),'responses':43}
