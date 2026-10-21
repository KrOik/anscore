"""Record reviewed DSP01 isolated evidence without production acceptance."""
import json
from pathlib import Path
HERE=Path(__file__).resolve().parent;ROOT=HERE.parents[1]
out=ROOT/'artifacts/dsp_isp_20260925/resampler_tracking';out.mkdir(exist_ok=False)
p=HERE/'requirements.json';(out/'requirements_before.json').write_bytes(p.read_bytes())
ledger=json.loads(p.read_text(encoding='utf-8'));base='cores/signal_processing/dsp_isp_library/dsp/resampler/'
m=json.loads((ROOT/base/'ip_manifest.json').read_text())
row=next(r for r in ledger['requirements'] if r['id']=='DSP-01')
row.update(status='仿真通过',configurations=['L/M each1..8, signed16 Q1.15, signed18 Q3.15 coefficients, default128taps, explicit finite-tail flush, capacity65535input samples'],implementation=[base+m['rtl']],specification=[base+'SPEC.md'],documentation=[base+'README.md',base+'ip_manifest.json'],simulation=[base+m['rtl_evidence'],base+m['model_evidence']],checker_negative=[base+m['rtl_evidence']],synthesis=[base+m['synthesis_evidence']],limitations=['Shared multiplier finite-block reference; actual2*phase_taps+1 startup and documented output rate; not an II1 qualification','Generated reference filters deliberately use bounded narrow passband0.1/max(L,M) and stop0.5/max(L,M), not a full Nyquist claim','Non-default static MAX_TAPS simulation and P&R/physical/production qualification remain pending'])
model=list((ROOT/base/'models').glob('*reference*.py'))
assert len(model)==1,model
row['float_model']=row['bit_exact_model']=[str(model[0].relative_to(ROOT)).replace('\\','/')]
for field in ('implementation','specification','documentation','simulation','checker_negative','synthesis','float_model','bit_exact_model'):
    for path in row[field]:assert (ROOT/path).is_file(),path
p.write_text(json.dumps(ledger,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
print('DSP01 reference evidence recorded; throughput and physical gates remain open.')
