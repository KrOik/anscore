"""CORDIC bit model, plus independent floating-point error bounds."""
import math
import random

PI = round(math.pi * 16384)
ATAN = [round(math.atan(2**-i)*16384) for i in range(16)]
GAIN = math.prod(math.sqrt(1+2**(-2*i)) for i in range(16))


def normalize(z):
    if z > PI:
        return z - 2*PI
    if z < -PI:
        return z + 2*PI
    return z


def calculate(x, y, z, vectoring):
    z = normalize(z)
    if vectoring and x == y == 0:
        return 0, 0, z
    if vectoring and x < 0:
        z += -PI if y < 0 else PI
        x, y = -x, -y
    elif not vectoring and abs(z) > PI//2:
        x, y = -x, -y
        z += -PI if z > 0 else PI
    for i, angle in enumerate(ATAN):
        turn = (y < 0) if vectoring else (z >= 0)
        direction = 1 if turn else -1
        x, y, z = x-direction*(y >> i), y+direction*(x >> i), z-direction*angle
    return x, y, normalize(z) if vectoring else z


def fixture(folder):
    rng = random.Random(0xC0D1C)
    cases = []
    for mode in (0, 1):
        for x, y in [(0,0), (1,0), (0,1), (-1,0), (0,-1),
                     (-32768,-32768), (32767,32767), (-32768,32767),
                     (32767,-32768), (20000,0), (0,20000)]:
            for z in [-131072, -PI, -PI//2, 0, PI//2, PI, 131071]:
                cases.append((mode,x,y,z))
        for _ in range(500):
            cases.append((mode,rng.randrange(-32768,32768),
                          rng.randrange(-32768,32768),rng.randrange(-131072,131072)))
    rows=[]
    max_xy_error=0.0
    for index,(mode,x,y,z) in enumerate(cases):
        ox,oy,oz=calculate(x,y,z,mode)
        if not mode:
            theta=normalize(z)/16384
            ex=GAIN*(x*math.cos(theta)-y*math.sin(theta))
            ey=GAIN*(x*math.sin(theta)+y*math.cos(theta))
            error=max(abs(ox-ex),abs(oy-ey))
            assert error<40, (x,y,z,error)
            assert abs(oz)<=5, oz
        else:
            error=abs(ox-GAIN*math.hypot(x,y))
            assert error<40, (x,y,z,error)
            assert abs(oy)<30, oy
            if math.hypot(x,y)>2000:
                theta=(normalize(z)/16384 + math.atan2(y,x))
                phase_error=math.atan2(math.sin(oz/16384-theta), math.cos(oz/16384-theta))
                assert abs(phase_error)<0.006, phase_error
        max_xy_error=max(max_xy_error,error)
        rows.append(f"{mode} {x} {y} {z} {index%7==6:d} {ox} {oy} {oz} {rng.randrange(4)} {rng.randrange(4)}\n")
    path=folder/'cordic_fixture.txt'
    path.write_text(''.join(rows),encoding='ascii')
    return path, len(cases), max_xy_error
