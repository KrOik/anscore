"""Reference is explicit zero insertion/convolution/decimation, not phase RTL."""
import random


def fixtures(folder, up, down, taps):
    rng=random.Random(0x5A9+up*17+down*11+taps)
    coeff=[rng.randrange(-128,128) for _ in range(taps)]
    packets=[[127],[-128],[0],[1,-1],[127]*13,[-128]*17,
             [127 if i%2 else -128 for i in range(29)]]
    packets += [[rng.randrange(-128,128) for _ in range(length)] for length in (2,3,7,16,31,37)]
    inputs=[]
    expected=[]
    for packet in packets:
        inputs += [f"{x} {int(i==len(packet)-1)}\n" for i,x in enumerate(packet)]
        zero_inserted=[0]*((len(packet)-1)*up+1)
        zero_inserted[::up]=packet
        convolution=[0]*(len(zero_inserted)+taps-1)
        for i,x in enumerate(zero_inserted):
            for j,c in enumerate(coeff):
                convolution[i+j]+=x*c
        decimated=convolution[::down]
        for i,value in enumerate(decimated):
            y=max(-128,min(127,value>>6))
            expected.append(f"{y} {int(i==len(decimated)-1)}\n")
    (folder/'coeff.txt').write_text(''.join(f'{c}\n' for c in coeff),encoding='ascii')
    (folder/'input.txt').write_text(''.join(inputs),encoding='ascii')
    (folder/'expected.txt').write_text(''.join(expected),encoding='ascii')
    return {'packets':len(packets),'inputs':len(inputs),'outputs':len(expected)}
