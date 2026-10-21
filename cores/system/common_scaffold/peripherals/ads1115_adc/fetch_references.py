from pathlib import Path
import hashlib,json,tempfile,sys,concurrent.futures,subprocess,datetime
HERE=Path(__file__).resolve().parent
URLS={'ti_datasheet':'https://www.ti.com/lit/ds/symlink/ads1115.pdf','adafruit_driver':'https://cdn.jsdelivr.net/gh/adafruit/Adafruit_ADS1X15@master/Adafruit_ADS1X15.cpp'}
def fetch(item):
 name,url=item
 r=subprocess.run(['curl.exe','-fL','--retry','2','--max-time','90',url],capture_output=True,check=True)
 data=r.stdout
 excerpts=[]
 if name=='ti_datasheet':
  import io
  from pypdf import PdfReader
  text='\n'.join(p.extract_text() or '' for p in PdfReader(io.BytesIO(data)).pages)
  for key in ['OS: Operational status','Operational status','single-cycle','settling','single-shot mode']:
   off=text.lower().find(key.lower())
   if off>=0:excerpts.append({'key':key,'text':text[max(0,off-120):off+1800]})
 else:
  text=data.decode('utf-8')
  for key in ['startADCReading','conversionComplete','getLastConversionResults']:
   off=text.find(key);excerpts.append({'key':key,'text':text[max(0,off-100):off+1600]})
 return name,dict(url=url,accessed_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),bytes=len(data),sha256=hashlib.sha256(data).hexdigest(),excerpts=excerpts)
if __name__=='__main__':
 with concurrent.futures.ThreadPoolExecutor() as pool:rows=dict(pool.map(fetch,URLS.items()))
 (HERE/'references.json').write_text(json.dumps(rows,indent=2)+'\n',encoding='utf-8')
 print(json.dumps({k:{a:v[a] for a in ['bytes','sha256']} for k,v in rows.items()}))
