"""Record the bounded cubic-delay reference; no ASRC or board acceptance claim."""
import json
from pathlib import Path
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[1]
out=ROOT/'artifacts/dsp_isp_20260925/farrow_tracking';out.mkdir(exist_ok=False)
p=HERE/'requirements.json';(out/'requirements_before.json').write_bytes(p.read_bytes())
ledger=json.loads(p.read_text(encoding='utf-8'));base='cores/signal_processing/dsp_isp_library/dsp/farrow/'
m=json.loads((ROOT/base/'ip_manifest.json').read_text())
r=next(r for r in ledger['requirements'] if r['id']=='DSP-11')
r.update(status='仿真通过',configurations=['Causal Catmull-Rom cubic,D0..31,mu code0..4096/4096,totalD+1+mu,signed16,RNE/saturation,5stage global stall II1,atomic retain/clear configuration'],implementation=[base+m['rtl']],specification=[base+'SPEC.md'],documentation=[base+'README.md',base+'ip_manifest.json'],simulation=[base+m['model_evidence'],base+m['rtl_evidence']],checker_negative=[base+m['rtl_evidence']],synthesis=[base+m['synthesis_evidence']],limitations=['Amplitude/group-delay bounds qualified only over0..0.1 cycles/input; non-bandlimited transient overshoot can saturate','No P&R or physical/production acceptance','ASRC rate estimation and buffer control are separate unimplemented functions'])
model=list((ROOT/base/'models').glob('*reference*.py'));assert len(model)==1
r['float_model']=r['bit_exact_model']=[str(model[0].relative_to(ROOT)).replace('\\','/')]
for field in ('implementation','specification','documentation','simulation','checker_negative','synthesis','float_model','bit_exact_model'):
    for path in r[field]:assert (ROOT/path).is_file(),path
p.write_text(json.dumps(ledger,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print('DSP11 isolated model/RTL/synthesis evidence recorded; full acceptance remains open.')
