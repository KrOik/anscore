from pathlib import Path
import subprocess,hashlib,json,tempfile
H=Path(__file__).resolve().parent
specs=[('https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-bitmapinfoheader',['BI_RGB uncompressed RGB','Positive height: bottom-up; negative height: top-down','Stride rounds scanline to DWORD boundary']),('https://learn.microsoft.com/en-us/windows/win32/api/wingdi/ns-wingdi-bitmapfileheader',['bfType 0x4D42','bfOffBits is offset to bitmap bits','Reserved fields must be zero'])]
rows=[]
with tempfile.TemporaryDirectory(prefix='bmp_reference_') as td:
 for i,(url,notes) in enumerate(specs):
  p=Path(td)/str(i);subprocess.run(['curl.exe','-f','-L','--ssl-revoke-best-effort','--connect-timeout','10','--max-time','35','-o',str(p),url],check=True,capture_output=True);raw=p.read_bytes();rows.append(dict(url=url,sha256=hashlib.sha256(raw).hexdigest(),bytes=len(raw),design_points=notes))
(H/'references.json').write_text(json.dumps(dict(status='retrieved',references=rows),indent=2)+'\n');print('PASS references')

