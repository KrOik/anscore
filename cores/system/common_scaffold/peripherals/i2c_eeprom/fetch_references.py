"""Fetch mature EEPROM/I2C references in memory, retain hashes and excerpts."""
from pathlib import Path
import subprocess,json,hashlib,datetime
HERE=Path(__file__).resolve().parent
SOURCES=[('https://cdn.jsdelivr.net/gh/RobTillaart/I2C_EEPROM@master/I2C_eeprom.cpp',['page','ACK','writeBlock']),('https://cdn.jsdelivr.net/gh/alexforencich/verilog-i2c@master/rtl/i2c_master.v',['stretch','scl_i','sda_i'])]
def main():
 rows=[]
 for url,terms in SOURCES:
  data=subprocess.check_output(['curl.exe','-fsSL','--ssl-revoke-best-effort','--retry','2','--connect-timeout','10','--max-time','20',url]);lines=data.decode('utf-8','replace').splitlines();excerpts=[]
  for term in terms:
   hit=next((i for i,s in enumerate(lines) if term.lower() in s.lower()),None)
   if hit is not None:excerpts.append(dict(term=term,line=hit+1,text='\n'.join(lines[max(0,hit-1):hit+7])))
  assert len(data)>1000 and excerpts
  rows.append(dict(url=url,bytes=len(data),sha256=hashlib.sha256(data).hexdigest(),excerpts=excerpts))
 (HERE/'references.json').write_text(json.dumps(dict(accessed_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),sources=rows,scope='Actual mature Arduino EEPROM page limiting and ACK readiness plus open-drain I2C timing references. Original RTL; no imported implementation, no electrical or board claim.'),indent=2)+'\n',encoding='utf-8')
 print('PASS actual public references',len(rows))
if __name__=='__main__':main()

