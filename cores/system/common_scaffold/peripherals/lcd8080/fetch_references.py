"""Fetch mature driver reference excerpts in memory, without retaining downloads."""
from pathlib import Path
import hashlib,json,subprocess,datetime
HERE=Path(__file__).resolve().parent
URLS=[
 ('esp-idf','https://cdn.jsdelivr.net/gh/espressif/esp-idf@v5.4.1/components/esp_lcd/i80/esp_lcd_panel_io_i80.c',['bus_width','wr_gpio_num','dc_levels','pclk_hz']),
 ('Adafruit-TFTLCD','https://cdn.jsdelivr.net/gh/adafruit/TFTLCD-Library@master/Adafruit_TFTLCD.cpp',['readReg','readPixel','setAddrWindow','writeRegister'])]
def main():
 rows=[]
 for name,url,terms in URLS:
  blob=subprocess.check_output(['curl.exe','-fsSL','--ssl-revoke-best-effort','--connect-timeout','10','--max-time','40',url]);status=200
  text=blob.decode('utf-8','replace');lines=text.splitlines();excerpts=[]
  for term in terms:
   hit=next((i for i,s in enumerate(lines) if term in s),None)
   if hit is not None:excerpts.append(dict(term=term,line=hit+1,text='\n'.join(lines[max(0,hit-1):hit+3])))
  assert status==200 and len(blob)>1000 and excerpts
  rows.append(dict(name=name,url=url,status=status,bytes=len(blob),sha256=hashlib.sha256(blob).hexdigest(),excerpts=excerpts))
 (HERE/'references.json').write_text(json.dumps(dict(fetched_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),references=rows,usage='Interface and transaction-order cross-check only; original RTL, no copied implementation.'),indent=2)+'\n')
 print('PASS references fetched',len(rows))
if __name__=='__main__':main()
