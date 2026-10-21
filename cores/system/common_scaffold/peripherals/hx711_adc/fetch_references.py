from pathlib import Path
import subprocess,hashlib,json,fitz
H=Path(__file__).resolve().parent
URL='https://cdn.sparkfun.com/datasheets/Sensors/ForceFlex/hx711_english.pdf'
def main():
 data=subprocess.check_output(['curl.exe','-fsSL','--ssl-revoke-best-effort','--connect-timeout','5','--max-time','20',URL],timeout=25)
 doc=fitz.open(stream=data,filetype='pdf');text='\n'.join(page.get_text() for page in doc)
 (H/'datasheet_excerpts.txt').write_text(text,encoding='utf-8')
 (H/'references.json').write_text(json.dumps(dict(datasheet=dict(url=URL,bytes=len(data),sha256=hashlib.sha256(data).hexdigest(),pages=len(doc),extracted_text_sha256=hashlib.sha256(text.encode('utf-8')).hexdigest()),notes=['The actual AVIA Semiconductor HX711 datasheet is fetched and parsed; source PDF is kept only in memory.','Timing/selection derived from Serial Interface and Fig.2/3:25/26/27 pulses select A128/B32/A64 for NEXT conversion. PD_SCK high>60us powers down; normal high must remain below50us.']),indent=2)+'\n',encoding='utf-8')
if __name__=='__main__':main()
