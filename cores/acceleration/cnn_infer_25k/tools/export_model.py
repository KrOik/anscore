"""Convert validated JSON INT8 parameters into memories and full layer goldens."""
import argparse
import hashlib
import json
from pathlib import Path
from model import fixture,validate,infer,model_hash


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--model',type=Path,help='omit to generate deterministic functional model')
    p.add_argument('--output',type=Path,required=True)
    args=p.parse_args()
    model=json.loads(args.model.read_text()) if args.model else fixture()
    validate(model)
    args.output.mkdir(parents=True,exist_ok=False)
    (args.output/'model.json').write_text(json.dumps(model,indent=2)+'\n')
    def memory(name,values,bits):
        (args.output/(name+'.mem')).write_text(''.join(f'{v&((1<<bits)-1):0{bits//4}x}\n' for v in values))
    for name in ('conv1','conv2','dense','bias1','bias2','bias3'):
        memory(name,model[name],32 if name.startswith('bias') else 8)
    cases={
        'ramp':[(i*37+11)%256-128 for i in range(784)],
        'checker':[127 if (x+y)%2 else -128 for y in range(28) for x in range(28)],
        'impulse':[127 if i==14*28+14 else 0 for i in range(784)],
    }
    for name,image in cases.items():
        taps=infer(model,image)
        (args.output/(name+'.json')).write_text(json.dumps(taps,indent=2)+'\n')
        for tap,values in taps.items():memory(name+'_'+tap,values,32 if tap.endswith('_acc') or tap=='scores' else 8)
    manifest=dict(schema='cnn25k_export_v1',model_sha256=model_hash(model),physical_measurement=False,
                  inputs=list(cases),rtl_verified=False,
                  sources={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (Path(__file__).resolve(),Path(__file__).with_name('model.py'))},
                  files={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(args.output.iterdir())})
    (args.output/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    print('Export PASS:3 full-network cases; '+str(args.output))


if __name__=='__main__':main()
