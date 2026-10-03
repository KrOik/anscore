import sys,json
from pathlib import Path
import numpy as np
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'models'))
from reference import *
BASE=Path(__file__).resolve().parents[1];(BASE/'evidence').mkdir(exist_ok=True)
rng=np.random.default_rng(0xFA110);reports=[];worst=0
for delay in (0,1,15,31):
 for u in (0,1,257,1024,2048,3072,4095,4096):
  x=rng.integers(-12000,12001,4096);model=StreamModel();model.config(delay,u,True)
  fixed=np.array([model.sample(v)[0] for v in x]);ideal=floating(x,delay,u/4096)
  error=float(np.max(np.abs(fixed-ideal)));worst=max(worst,error);assert error<.51,error
  f=np.linspace(0,.1,2049);h=np.exp(-2j*np.pi*f[:,None]*np.arange(4))@weights(u/4096)
  amplitude=float(np.max(np.abs(20*np.log10(np.abs(h)))))
  gd=-np.gradient(np.unwrap(np.angle(h)),2*np.pi*f)
  group_error=float(np.max(np.abs(gd-(1+u/4096))))
  assert amplitude<.04 and group_error<.06,(amplitude,group_error)
  reports.append(dict(delay=delay,mu=u,float_lsb_error=error,amplitude_error_db=amplitude,group_delay_error_samples=group_error))
# Fractional sweep on identical windows measures parameter continuity, rather than
# confounding it with the input advancing in time. Compare to analytic derivative.
continuity=[]
for window in ([12000,-11000,9000,-7000],[100,200,300,400],[-32768,32767,-32768,32767]):
 outputs=np.array([bitexact(window,u)[0] for u in range(4097)])
 ideal=np.array([weights(u/4096)@window for u in range(4097)])
 clipped=np.clip(ideal,-32768,32767)
 assert np.max(np.abs(outputs-clipped))<.51
 step=int(np.max(np.abs(np.diff(outputs))))
 assert step<=np.max(np.abs(np.diff(clipped)))+1.01
 continuity.append(dict(window=window,max_step_lsb=step))
 for d in range(31):
  x=np.arange(80)*13-500
  assert np.array_equal(floating(x,d,1),floating(x,d+1,0))
result={'status':'PASS','vectors':len(reports),'samples_per_vector':4096,'worst_float_lsb_error':worst,
 'qualified_band_cycles_per_input':[0,.1],'bounds':{'amplitude_db':.04,'group_delay_samples':.06},
 'cases':reports,'continuity':continuity,'scope':'Catmull-Rom narrow-band reference; no ASRC or arbitrary delay-jump continuity'}
f=np.linspace(0,.1,1025);basis=np.array([weights(u/4096) for u in range(4097)])
response=basis@np.exp(-2j*np.pi*np.arange(4)[:,None]*f)
gd=-np.gradient(np.unwrap(np.angle(response),axis=1),2*np.pi*f,axis=1)
amp=float(np.max(np.abs(20*np.log10(np.abs(response)))))
gerr=float(np.max(np.abs(gd-(1+np.arange(4097)[:,None]/4096))))
assert amp<.04 and gerr<.06
result['all_mu_spectrum']={'mu_values':4097,'frequency_bins':1025,'max_amplitude_error_db':amp,'max_group_delay_error_samples':gerr}
(BASE/'evidence/model_validation.json').write_text(json.dumps(result,indent=2));print('PASS',worst)
