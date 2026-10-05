"""Isolated core Gowin synthesis; not place/route or board acceptance."""
import argparse,collections,datetime,hashlib,json,os,subprocess
from pathlib import Path
HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]
p=argparse.ArgumentParser();p.add_argument('--bits',type=int,choices=(8,10),default=10);args=p.parse_args()
dest=HERE/'evidence'/('synth_'+datetime.datetime.now().strftime('%Y%m%d_%H%M%S_%f'));dest.mkdir(parents=True)
binpath=ROOT/'tools/oss-cad-suite/oss-cad-suite/bin'
env=os.environ.copy();env['PATH']=str(binpath)+os.pathsep+str(binpath.parent/'lib')+os.pathsep+env['PATH']
script=f'read_verilog -I{HERE.as_posix()} {HERE.as_posix()}/csc_stream.v; chparam -set BITS {args.bits} csc_stream; synth_gowin -top csc_stream -noalu; stat; write_json {dest.as_posix()}/core.json'
(dest/'command.ys').write_text(script+'\n')
with (dest/'synthesis.log').open('w') as log:
    proc=subprocess.run([str(binpath/'yosys.exe'),'-Q','-T','-p',script],env=env,stdout=log,stderr=subprocess.STDOUT)
if proc.returncode: raise SystemExit(proc.returncode)
design=json.loads((dest/'core.json').read_text())
counts=collections.Counter(c['type'] for c in design['modules']['csc_stream']['cells'].values())
metrics=dict(bits=args.bits,latency=4,status='SYNTHESIS_PASS_ONLY',cells=counts,lut1_4=sum(counts[f'LUT{i}'] for i in range(1,5)),ff=sum(n for k,n in counts.items() if k.startswith('DFF')),dsp=sum(n for k,n in counts.items() if k.startswith(('MULT','PADD'))),sha256={name:hashlib.sha256((HERE/name).read_bytes()).hexdigest() for name in ('csc_stream.v','csc_coeffs.vh')})
(dest/'summary.json').write_text(json.dumps(metrics,indent=2)+'\n');print(dest);print(json.dumps(metrics))
