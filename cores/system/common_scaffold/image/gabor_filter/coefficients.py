"""Generate signed Q-format complex Gabor convolution coefficients; no clipping."""
import argparse
import json
import math
from pathlib import Path


def generate(size=5, sigma=1.4, theta=0.0, wavelength=3.0, gamma=0.8,
             phase=0.0, fraction=12, zero_dc=False):
    if type(size) is not int or size not in (1, 3, 5, 7):
        raise ValueError('size must be 1,3,5,7')
    if type(fraction) is not int or not 0 <= fraction <= 14:
        raise ValueError('fraction must be an integer in 0..14')
    for name, value, lo, hi in [('sigma', sigma, .05, 32),
                               ('wavelength', wavelength, .1, 128),
                               ('gamma', gamma, .05, 16)]:
        if not math.isfinite(value) or not lo <= value <= hi:
            raise ValueError(f'{name} must be finite in {lo}..{hi}')
    if not math.isfinite(theta) or not math.isfinite(phase):
        raise ValueError('angles must be finite radians')
    theta = math.remainder(theta, 2*math.pi)
    phase = math.remainder(phase, 2*math.pi)
    c, s = math.cos(theta), math.sin(theta)
    r = size//2
    real, imag = [], []
    for y in range(-r, r+1):
        for x in range(-r, r+1):
            xr, yr = x*c+y*s, -x*s+y*c
            envelope = math.exp(-.5*((xr/sigma)**2+(gamma*yr/sigma)**2))
            angle = 2*math.pi*xr/wavelength+phase
            real.append(envelope*math.cos(angle))
            imag.append(envelope*math.sin(angle))
    if zero_dc:
        real = [v-sum(real)/len(real) for v in real]
        imag = [v-sum(imag)/len(imag) for v in imag]
    def quantize(values):
        result = [int(math.copysign(math.floor(abs(v)*(1 << fraction)+.5), v))
                  for v in values]
        if any(v < -32768 or v > 32767 for v in result):
            raise ValueError('signed16 coefficient overflow; reduce fraction')
        return result
    qr, qi = quantize(real), quantize(imag)
    return dict(size=size, shift=fraction, real=qr, imag=qi,
                sigma=sigma, theta=theta, wavelength=wavelength, gamma=gamma,
                phase=phase, zero_dc=bool(zero_dc),
                convention='row-major mathematical convolution, replicate border',
                quantization='nearest, half away from zero; no clipping',
                dc_quantized=[sum(qr), sum(qi)],
                max_abs_raw_response=[255*sum(map(abs, qr)), 255*sum(map(abs, qi))])


if __name__ == '__main__':
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--size', type=int, default=5)
    p.add_argument('--sigma', type=float, default=1.4)
    p.add_argument('--theta', type=float, default=0.)
    p.add_argument('--wavelength', type=float, default=3.)
    p.add_argument('--gamma', type=float, default=.8)
    p.add_argument('--phase', type=float, default=0.)
    p.add_argument('--fraction', type=int, default=12)
    p.add_argument('--zero-dc', action='store_true')
    p.add_argument('--output', type=Path)
    a = vars(p.parse_args()); output = a.pop('output')
    text = json.dumps(generate(**a), indent=2)+'\n'
    if output:
        output.write_text(text, encoding='utf-8')
    else:
        print(text, end='')
