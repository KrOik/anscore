"""CIC oracle using closed-form integrals and binomial checkpoint differences."""
from math import comb
import random


def fixtures(folder,rate,stages,shift):
    rng=random.Random(0xC1CA+rate*19+stages)
    lengths=[1,max(1,rate-1),rate,rate+1,2*rate+3,127,129]
    packets=[[127]*lengths[0],[-128]*lengths[1],
             [127]*lengths[2],[-128]*lengths[3]]
    packets += [[rng.randrange(-128,128) for _ in range(length)] for length in lengths[4:]]
    width=8+stages*(rate-1).bit_length()
    inputs=[]
    expected=[]
    for packet in packets:
        checkpoints=[]
        for index,x in enumerate(packet):
            last=index==len(packet)-1
            inputs.append(f'{x} {int(last)}\n')
            if (index+1)%rate!=0 and not last:
                continue
            integral=sum(comb(index-i+stages-1,stages-1)*value
                         for i,value in enumerate(packet[:index+1]))
            checkpoints.append(integral)
            value=sum((-1)**j*comb(stages,j)*checkpoints[-1-j]
                      for j in range(min(stages+1,len(checkpoints))))
            value=((value+(1<<(width-1)))%(1<<width))-(1<<(width-1))
            value=max(-128,min(127,value>>shift))
            expected.append(f'{value} {int(last)}\n')
    (folder/'input.txt').write_text(''.join(inputs),encoding='ascii')
    (folder/'expected.txt').write_text(''.join(expected),encoding='ascii')
    return {'inputs':len(inputs),'outputs':len(expected),'packets':len(packets)}
