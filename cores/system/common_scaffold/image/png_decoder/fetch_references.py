from pathlib import Path
import subprocess,tempfile,hashlib,json,datetime,concurrent.futures
H=Path(__file__).resolve().parent
entries=[('PNG','https://www.w3.org/TR/2003/REC-PNG-20031110/',['filter types','CRC','IDAT']),('RFC1951','https://www.rfc-editor.org/rfc/rfc1951.txt',['Huffman','32,768','repeat']),('RFC1950','https://www.rfc-editor.org/rfc/rfc1950.txt',['ADLER32','CINFO']),('miniz_tinfl','https://cdn.jsdelivr.net/gh/richgel999/miniz@master/miniz_tinfl.c',['TINFL_STATE','tinfl_decompress','Adler'])]
def fetch(entry):
 name,url,keys=entry
 with tempfile.TemporaryDirectory(prefix='png_reference_') as td:
  p=Path(td)/'reference';r=subprocess.run(['curl.exe','-f','-L','--ssl-revoke-best-effort','--connect-timeout','10','--max-time','35','-o',str(p),url],capture_output=True)
  if r.returncode:return {'name':name,'url':url,'error':r.stderr.decode(errors='replace')[-300:]}
  data=p.read_bytes();lines=data.decode(errors='replace').splitlines();hits=[i for i,line in enumerate(lines) if any(key.lower() in line.lower() for key in keys)]
  return {'name':name,'url':url,'sha256':hashlib.sha256(data).hexdigest(),'bytes':len(data),'accessed_utc':datetime.datetime.now(datetime.timezone.utc).isoformat(),'excerpts':[{'line':i+1,'text':'\n'.join(lines[max(0,i-1):i+5])} for i in hits[:6]],'use':'Specification/algorithm review only; original RTL, no third-party source copied. miniz is a mature C implementation used to compare parser, Huffman/LZ77 and checksum concepts, not RTL architecture.'}
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:rows=list(pool.map(fetch,entries))
(H/'references.json').write_text(json.dumps(rows,indent=2)+'\n');print(json.dumps([{k:v for k,v in row.items() if k!='excerpts'} for row in rows],indent=2));assert all('sha256' in row for row in rows)
