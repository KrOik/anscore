"""Deterministic coherent4-channel virtual ADC input and exact I/Q oracle."""
import argparse
import hashlib
import json
import math
from pathlib import Path

ROOT=next(p for p in Path(__file__).resolve().parents if (p/'cores').is_dir());P=ROOT/'cores/signal_processing/lockin'


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);args=p.parse_args()
    args.output.mkdir(parents=True,exist_ok=False)
    sine=[round(32767*math.sin(2*math.pi*i/256)) for i in range(256)]
    cosine=[sine[(i+64)%256] for i in range(256)]
    for name,values in [('sine',sine),('cosine',cosine)]:
        (args.output/(name+'.mem')).write_text(''.join(f'{v&65535:04x}\n' for v in values))
    cases=[]
    for case,(bins,amplitudes,phases) in enumerate([
        (1,[1000,4000,12000,24000],[0,32,192,96]),
        (3,[64,2000,8000,20000],[16,64,128,224]),
        (7,[500,5000,16000,28000],[240,80,160,48]),
    ]):
        samples=[];sumi=[0]*4;sumq=[0]*4
        for n in range(256):
            phase=n*bins%256
            vector=[round(amplitudes[c]*cosine[(phase+phases[c])%256]/32767) for c in range(4)]
            samples.append(vector)
            for c,x in enumerate(vector):sumi[c]+=x*cosine[phase];sumq[c]-=x*sine[phase]
        expected_i=[v>>(15+8) for v in sumi];expected_q=[v>>(15+8) for v in sumq]
        cases.append(dict(id=case,bins=bins,tuning=bins<<24,log2=8,period=1000,
                          amplitudes=amplitudes,phases_indices=phases,samples=samples,
                          expected_i=expected_i,expected_q=expected_q))
        (args.output/f'samples{case}.mem').write_text(''.join(f'{sum((v&65535)<<(16*c) for c,v in enumerate(row)):016x}\n' for row in samples))
    (args.output/'cases.json').write_text(json.dumps(cases,indent=2)+'\n')
    (args.output/'manifest.json').write_text(json.dumps(dict(physical_measurement=False,
        generator_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        files={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in args.output.iterdir()}),indent=2)+'\n')
    print('Generated3 coherent4-channel datasets: '+str(args.output))


if __name__=='__main__':main()
