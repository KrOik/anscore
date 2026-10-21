from pathlib import Path
import hashlib,json,tempfile,sys,concurrent.futures,subprocess,datetime
HERE=Path(__file__).resolve().parent
URLS={'sccb_specification':'https://www.waveshare.com/w/upload/1/14/OmniVision_Technologies_Seril_Camera_Control_Bus%28SCCB%29_Specification.pdf','espressif_sccb':'https://cdn.jsdelivr.net/gh/espressif/esp32-camera@master/driver/sccb.c'}
def fetch(item):
 name,url=item
 if name=='sccb_specification':
  # Server is slow per connection; explicit byte ranges are fetched independently.
  size=302883;chunk=16384
  def part(start):
   end=min(size-1,start+chunk-1)
   r=subprocess.run(['curl.exe','-fL','--retry','2','--retry-all-errors','--max-time','45','-r',str(start)+'-'+str(end),url],capture_output=True,check=True)
   assert len(r.stdout)==end-start+1,(start,len(r.stdout))
   return r.stdout
  with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:data=b''.join(pool.map(part,range(0,size,chunk)))
 else:
  r=subprocess.run(['curl.exe','-fL','--retry','2','--retry-all-errors','--max-time','90',url],capture_output=True,check=True)
  data=r.stdout
 excerpts=[]
 if name=='sccb_specification':
  import io
  from pypdf import PdfReader
  text='\n'.join(p.extract_text() or '' for p in PdfReader(io.BytesIO(data)).pages)
  for key in ["3.2.3", "NA bit", "1.1 2-Wire", "3.2.1", "3.2.2"]:
   off=text.lower().rfind(key.lower())
   if off>=0:excerpts.append({'key':key,'text':text[max(0,off-120):off+1800]})
 else:
  text=data.decode('utf-8')
  for key in ['SCCB_Read(', 'SCCB_Write(', 'SCCB_Read16(', 'SCCB_Write16(']:
   off=text.find(key);excerpts.append({'key':key,'text':text[max(0,off-100):off+1600]})
 return name,dict(url=url,accessed_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),bytes=len(data),sha256=hashlib.sha256(data).hexdigest(),excerpts=excerpts)
if __name__=='__main__':
 with concurrent.futures.ThreadPoolExecutor() as pool:rows=dict(pool.map(fetch,URLS.items()))
 (HERE/'references.json').write_text(json.dumps(rows,indent=2)+'\n',encoding='utf-8')
 print(json.dumps({k:{a:v[a] for a in ['bytes','sha256']} for k,v in rows.items()}))
