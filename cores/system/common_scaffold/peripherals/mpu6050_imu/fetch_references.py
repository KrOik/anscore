from pathlib import Path
import hashlib,json,tempfile,sys,concurrent.futures,subprocess,datetime
HERE=Path(__file__).resolve().parent
URLS={'register_map':'https://cdn.sparkfun.com/datasheets/Sensors/Accelerometers/RM-MPU-6000A.pdf','adafruit_driver':'https://cdn.jsdelivr.net/gh/adafruit/Adafruit_MPU6050@master/Adafruit_MPU6050.cpp'}
def fetch(item):
 name,url=item
 r=subprocess.run(['curl.exe','-fL','--retry','2','--retry-all-errors','--max-time','90',url],capture_output=True,check=True)
 data=r.stdout
 excerpts=[]
 if name=='register_map':
  import io
  from pypdf import PdfReader
  text='\n'.join(p.extract_text() or '' for p in PdfReader(io.BytesIO(data)).pages)
  for key in ['shadow', 'burst', 'DATA_RDY_INT', 'WHO_AM_I', 'INT_RD_CLEAR', 'PWR_MGMT_1']:
   off=text.lower().rfind(key.lower())
   if off>=0:excerpts.append({'key':key,'text':text[max(0,off-120):off+1800]})
 else:
  text=data.decode('utf-8')
  for key in ['_read(void)', 'MPU6050_ACCEL_OUT', 'MPU6050_WHO_AM_I', 'setSampleRateDivisor']:
   off=text.find(key);excerpts.append({'key':key,'text':text[max(0,off-100):off+1600]})
 return name,dict(url=url,accessed_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),bytes=len(data),sha256=hashlib.sha256(data).hexdigest(),excerpts=excerpts)
if __name__=='__main__':
 with concurrent.futures.ThreadPoolExecutor() as pool:rows=dict(pool.map(fetch,URLS.items()))
 (HERE/'references.json').write_text(json.dumps(rows,indent=2)+'\n',encoding='utf-8')
 print(json.dumps({k:{a:v[a] for a in ['bytes','sha256']} for k,v in rows.items()}))
