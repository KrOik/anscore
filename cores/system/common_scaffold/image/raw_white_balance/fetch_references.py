import datetime,hashlib,json,subprocess,tempfile
from pathlib import Path
H=Path(__file__).resolve().parent
urls=[('Raspberry Pi libcamera AWB','https://cdn.jsdelivr.net/gh/raspberrypi/libcamera@main/src/ipa/rpi/controller/rpi/awb.cpp'),('Infinite-ISP RAW white balance','https://cdn.jsdelivr.net/gh/10x-Engineers/Infinite-ISP@master/modules/white_balance/white_balance.py'),('Infinite-ISP automatic white balance','https://cdn.jsdelivr.net/gh/10x-Engineers/Infinite-ISP@master/modules/auto_white_balance/auto_white_balance.py')]
urls.append(('Infinite-ISP gray-world implementation','https://cdn.jsdelivr.net/gh/10x-Engineers/Infinite-ISP@master/modules/auto_white_balance/gray_world.py'))
rows=[]
for title,url in urls:
 with tempfile.TemporaryDirectory(prefix='awb_reference_')as td:
  p=Path(td)/'source';run=subprocess.run(['curl.exe','-fsL','--ssl-revoke-best-effort','--max-time','30','-o',str(p),url],capture_output=True)
  if run.returncode:rows.append(dict(title=title,url=url,error=run.stderr.decode(errors='replace')[-400:]));continue
  data=p.read_bytes();lines=data.decode(errors='replace').splitlines()
  hits=[i for i,l in enumerate(lines)if any(k in l.lower()for k in ('gray','grey','gain_r','gain_b','r_gain','b_gain','mean(', 'gr_avg','gb_avg','redgain','bluegain','np.clip'))]
  rows.append(dict(title=title,url=url,retrieved_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),sha256=hashlib.sha256(data).hexdigest(),bytes=len(data),excerpts=['\n'.join(lines[max(0,i-3):i+8])for i in hits[:14]],use='Inspected algorithm/design reference only; independent RTL and explicit four-plane pooled-green contract, no source code copied.'))
(H/'references.json').write_text(json.dumps(rows,indent=2)+'\n');print(json.dumps(rows,indent=2))
