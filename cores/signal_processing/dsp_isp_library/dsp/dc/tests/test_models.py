"""Run from any directory: python <this-file>."""
import sys
from pathlib import Path
import random
import json
import math
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'models'))
from dc_reference import Config, FixedReference, float_reference, rne, cutoff_hz


def run():
    assert [rne(x, 2) for x in [-7,-5,-3,-1,1,3,5,7]] == [-4,-2,-2,0,0,2,2,4]
    for kwargs in ({'pole':65536}, {'pole':-1}, {'mode':'bad'}, {'window_log2':9}):
        try:
            Config(**kwargs)
        except ValueError:
            pass
        else:
            raise AssertionError('illegal config accepted')
    rng = random.Random(0xDC09)
    vectors = {'zero':[0]*512, 'constant':[10000]*8192,
               'impulse':[16000]+[0]*1023,
               'extrema':[-32768,32767]*1024,
               'random':[rng.randrange(-16000,16001) for _ in range(2048)],
               'baseline_sine':[int(5000+3000*math.sin(i*.0007)+4000*math.sin(i*.31)) for i in range(8192)]}
    cases, max_error = 0, 0
    for mode in ['blocker','mean','baseline']:
        for pole in [0,32768,65024,65535]:
            for logn in ([0,1,4,8] if mode == 'mean' else [4]):
                cfg = Config(mode,pole,logn)
                for name, xs in vectors.items():
                    dut = FixedReference(cfg)
                    actual = [dut.step(x) for x in xs]
                    reference = float_reference(xs,cfg)
                    for pair, fp in zip(actual,reference):
                        for a,f in zip(pair,fp):
                            ideal = max(-32768,min(32767,f*32768))
                            error = abs(a-ideal)
                            assert error <= 1.01, (mode,pole,name,error)
                            max_error = max(max_error,error)
                    dut.reset()
                    assert [dut.step(x) for x in xs] == actual
                    dut.configure(cfg)
                    assert [dut.step(x) for x in xs] == actual
                    if mode == 'mean' and name == 'constant':
                        assert all(p == (0,10000) for p in actual[(1<<logn)-1:])
                    cases += 1
    # Closed-form impulse independently confirms blocker recurrence direction.
    cfg = Config('blocker',32768)
    assert [FixedReference(cfg).step(8000)] == [(8000,0)]
    m = FixedReference(cfg)
    assert [m.step(x)[0] for x in [8000,0,0,0]] == [8000,-4000,-2000,-1000]
    # Saturation must not clamp feedback state: recovery retains wide history.
    m = FixedReference(Config('blocker',0))
    assert [m.step(x)[0] for x in [-32768,32767,32767]] == [-32768,32767,0]
    return {'status':'PASS','cases':cases,'seed':'0xDC09',
            'max_error_output_lsb':max_error,
            'default_cutoff_at_48khz':cutoff_hz(65024,48000),
            'scope':'algorithm models only; RTL/protocol/build/board pending'}


if __name__ == '__main__':
    print(json.dumps(run(),indent=2))
