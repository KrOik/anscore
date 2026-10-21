"""Actual DS3231 datasheet and mature RTC implementation references, memory-only."""
from pathlib import Path
import subprocess,json,hashlib,datetime,io
from concurrent.futures import ThreadPoolExecutor
from pypdf import PdfReader
HERE=Path(__file__).resolve().parent
SOURCES=[('https://www.analog.com/media/en/technical-documentation/data-sheets/ds3231.pdf','pdf',['user buffers','century','oscillator stop flag','12-hour']),('https://cdn.jsdelivr.net/gh/adafruit/RTClib@master/src/RTC_DS3231.cpp','code',['RTC_DS3231::now','RTC_DS3231::adjust','lostPower'])]
def fetch(entry):
 url,kind,terms=entry
 data=subprocess.check_output(['curl.exe','-fsSL','--ssl-revoke-best-effort','--retry','2','--connect-timeout','10','--max-time','25',url]);assert len(data)>1000
 if kind=='pdf':
  assert data.startswith(b'%PDF');text='\n'.join(page.extract_text() or '' for page in PdfReader(io.BytesIO(data)).pages)
 else:text=data.decode('utf-8')
 lines=text.splitlines();excerpts=[]
 for term in terms:
  hit=next((i for i,s in enumerate(lines) if term.lower() in s.lower()),None)
  if hit is not None:excerpts.append(dict(term=term,line=hit+1,text='\n'.join(lines[max(0,hit-2):hit+9])))
 assert len(excerpts)>=2
 return dict(url=url,kind=kind,bytes=len(data),sha256=hashlib.sha256(data).hexdigest(),excerpts=excerpts)
def main():
 with ThreadPoolExecutor(max_workers=2) as pool:rows=list(pool.map(fetch,SOURCES))
 (HERE/'references.json').write_text(json.dumps(dict(accessed_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),sources=rows,scope='Actual Analog Devices DS3231 datasheet and Adafruit RTC implementation fetched in memory, fixed hashes and textual excerpts retained. Original RTL, no copied implementation or physical accuracy certification.'),indent=2)+'\n',encoding='utf-8');print('PASS actual RTC references',len(rows))
if __name__=='__main__':main()
