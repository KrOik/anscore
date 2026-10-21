import argparse,json
from pathlib import Path
from reference import design,spectrum_metrics
p=argparse.ArgumentParser();p.add_argument('--l',type=int,required=True);p.add_argument('--m',type=int,required=True);p.add_argument('--taps',type=int,default=128);p.add_argument('--output',type=Path)
a=p.parse_args();cfg,h=design(a.l,a.m,a.taps)
report={'l':cfg.l,'m':cfg.m,'taps':len(cfg.coefficients),'format':'signed18 Q3.15','coefficients':cfg.coefficients,
 'cfg_coeffs_hex':format(sum((c&0x3ffff)<<(18*i) for i,c in enumerate(cfg.coefficients)),'x'),
 'group_delay_highrate_ticks':(len(h)-1)/2,'spectrum':spectrum_metrics(cfg),
 'scope':'narrow-band reference; pass edge0.1/max(L,M), stop edge0.5/max in high-rate cycles'}
text=json.dumps(report,indent=2)
if a.output:
 with a.output.open('x',encoding='utf-8') as f:f.write(text)
else:print(text)
