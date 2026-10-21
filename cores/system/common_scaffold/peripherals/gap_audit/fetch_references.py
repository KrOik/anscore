"""Fetch small mature 1-Wire application references; memory-only downloads."""
from pathlib import Path
import subprocess,hashlib,json,datetime
HERE=Path(__file__).resolve().parent
def main():
 rows=[]
 for repo,path,terms in [
  ('PaulStoffregen/OneWire','OneWire.cpp',['OneWire::search','LastDiscrepancy','OneWire::select','OneWire::crc8']),
  ('milesburton/Arduino-Temperature-Control-Library','DallasTemperature.cpp',['STARTCONVO','READSCRATCH','requestTemperatures','readScratchPad'])]:
  url=f'https://cdn.jsdelivr.net/gh/{repo}@master/{path}'
  blob=subprocess.check_output(['curl.exe','-fsSL','--ssl-revoke-best-effort','--connect-timeout','10','--max-time','40',url]);lines=blob.decode('utf-8','replace').splitlines();excerpts=[]
  for term in terms:
   i=next((i for i,line in enumerate(lines) if term in line),None)
   if i is not None:excerpts.append(dict(term=term,line=i+1,text='\n'.join(lines[max(0,i-1):i+5])))
  assert len(blob)>1000 and len(excerpts)>=2
  rows.append(dict(repository=repo,url=url,bytes=len(blob),sha256=hashlib.sha256(blob).hexdigest(),excerpts=excerpts))
 (HERE/'public_references.json').write_text(json.dumps(dict(accessed_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),sources=rows,scope='Mature application-level ROM search and temperature sequencing references only; software, not synthesizable RTL; no copying or new RTL.'),indent=2)+'\n')
 print('PASS actual mature references fetched:',len(rows),'memory-only')
if __name__=='__main__':main()
