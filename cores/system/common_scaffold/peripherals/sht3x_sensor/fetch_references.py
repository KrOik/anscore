from pathlib import Path
import subprocess,hashlib,json,fitz
H=Path(__file__).resolve().parent
URLS={'datasheet':'https://cdn-shop.adafruit.com/product-files/2857/Sensirion_Humidity_SHT3x_Datasheet_digital-767294.pdf','adafruit':'https://raw.githubusercontent.com/adafruit/Adafruit_SHT31/master/Adafruit_SHT31.cpp','sensirion':'https://raw.githubusercontent.com/Sensirion/embedded-sht/master/sht3x/sht3x.c'}
def main():
 rows={}
 for name,url in URLS.items():
  data=subprocess.check_output(['curl.exe','-fsSL','--ssl-revoke-best-effort','--connect-timeout','5','--max-time','25',url],timeout=30)
  if name=='datasheet':
   with fitz.open(stream=data,filetype='pdf') as doc:text='\n'.join(p.get_text() for p in doc)
   (H/'datasheet_excerpts.txt').write_text(text,encoding='utf-8')
  else:text=data.decode('utf-8')
  terms=['0x2400','0x240B','0x2416','0x24','0x31','65535','Single Shot','Single-Shot','15 ms','clock stretching']
  excerpts=[]
  for term in terms:
   pos=text.lower().find(term.lower())
   if pos>=0:excerpts.append(text[max(0,pos-120):pos+450])
  rows[name]=dict(url=url,sha256=hashlib.sha256(data).hexdigest(),bytes=len(data),excerpts=excerpts)
 (H/'references.json').write_text(json.dumps(dict(status='FETCHED',sources=rows,reuse='Independent RTL; public data sheet and open-source drivers consulted for command bytes, polling, CRC8 and numeric conversion. No driver source copied.'),indent=2)+'\n',encoding='utf-8')
 print('PASS FETCHED SHT3X REFERENCES')
if __name__=='__main__':main()
