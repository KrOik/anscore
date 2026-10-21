"""Independent analytic transfer-function vs integer steady-state tones."""
import sys,math,cmath,json
from pathlib import Path
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'models'))
from reference import lowpass,IntegerModel
reports=[]
for stages in [1,4]:
 for freq in [500,1000,2000,8000]:
  fs=48000;n=4800;amplitude=5000;section=lowpass();model=IntegerModel();model.configure((section,)*stages)
  ys=[]
  for i in range(2*n):
   x=round(amplitude*math.sin(2*math.pi*freq*i/fs));y,clipped=model.step(x)
   assert not clipped
   if i>=n:ys.append(y)
  measured=2*abs(sum(y*cmath.exp(-2j*math.pi*freq*i/fs) for i,y in enumerate(ys)))/n/amplitude
  b0,b1,b2,a1,a2=[v/32768 for v in section];z=cmath.exp(-2j*math.pi*freq/fs)
  analytic=abs((b0+b1*z+b2*z*z)/(1+a1*z+a2*z*z))**stages
  assert abs(measured-analytic)<.003,(stages,freq,measured,analytic)
  reports.append({'stages':stages,'frequency_hz':freq,'gain_bitexact':measured,'gain_analytic':analytic})
print(json.dumps({'status':'PASS','max_absolute_gain_error':max(abs(r['gain_bitexact']-r['gain_analytic']) for r in reports),'tones':reports},indent=2))
