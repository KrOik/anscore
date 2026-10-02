"""Generate RBJ low-pass coefficients and atomic packed configuration."""
import argparse,json,cmath,math
from pathlib import Path
from reference import lowpass,pack_coefficients,validate
p=argparse.ArgumentParser()
p.add_argument('--sample-rate',type=float,default=48000)
p.add_argument('--cutoff',type=float,default=2000)
p.add_argument('--q',type=float,default=math.sqrt(.5))
p.add_argument('--sections',type=int,default=1)
p.add_argument('--output',type=Path)
a=p.parse_args();s=lowpass(a.sample_rate,a.cutoff,a.q);sections=(s,)*a.sections;validate(sections)
b0,b1,b2,a1,a2=[v/32768 for v in s]
def gain(freq):
 z=cmath.exp(-2j*math.pi*freq/a.sample_rate)
 return abs((b0+b1*z+b2*z*z)/(1+a1*z+a2*z*z))**a.sections
report={'design':'identical cascaded RBJ lowpass sections','sample_rate_hz':a.sample_rate,
 'cutoff_hz_per_section':a.cutoff,'q_per_section':a.q,'cfg_sections':a.sections,'cfg_clear':1,
 'coefficient_format':'signed18 Q3.15','sections':sections,
 'cfg_coeffs_hex':f'{pack_coefficients(sections):090x}',
 'jury_integer_margins':[32768+s[3]+s[4],32768-s[3]+s[4],32768-s[4]],
 'quantized_dc_gain':gain(0),'quantized_gain_at_cutoff':gain(a.cutoff),
 'note':'Cascade cutoff is not generally per-section cutoff; inspect combined gain. Dynamic update has no bumpless-transfer guarantee.'}
text=json.dumps(report,indent=2)+'\n'
if a.output:
 with a.output.open('x',encoding='utf-8') as f:f.write(text)
else:print(text,end='')
