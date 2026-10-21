"""Serialized CORDIC oracle; uses the independent fixed-point algorithm model."""
from cordic_reference import calculate


def fixtures(folder):
    inputs=[]
    outputs=[]
    vectors=[(0,0),(1,-1),(-32768,-32768),(32767,32767),(-32768,32767),
             (32767,-32768),(20000,0),(0,20000),(137,-891)]
    for mode in (0,1):
        for angle in (-131072,-51472,-25736,0,25736,51472,131071):
            for i,(x,y) in enumerate(vectors):
                last=int(i==len(vectors)-1)
                inputs.append(f'{mode} {angle} {x} {y} {last}\n')
                result=calculate(x,y,angle,mode)
                for component,value in enumerate(result):
                    outputs.append(f'{value & 65535} 0\n')
                    outputs.append(f'{(value >> 16) & 65535} {int(last and component==2)}\n')
    (folder/'input.txt').write_text(''.join(inputs),encoding='ascii')
    (folder/'expected.txt').write_text(''.join(outputs),encoding='ascii')
    return {'vectors':len(inputs),'words':len(outputs),'packets':14,'responses':32}
