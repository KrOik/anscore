from run_tests import HERE
import subprocess,hashlib,json,io
urls=[('https://cdn.jsdelivr.net/gh/libsdl-org/libtiff@master/libtiff/tif_dirwrite.c','TIFFTAG_STRIPOFFSETS'),('https://cdn.jsdelivr.net/gh/python-pillow/Pillow@main/src/PIL/TiffImagePlugin.py','STRIPOFFSETS')]
rows=[]
for url,needle in urls:
 data=subprocess.check_output(['curl.exe','-fsSL','--max-time','40',url]);text=data.decode();i=text.find(needle);assert i>=0
 rows.append(dict(url=url,sha256=hashlib.sha256(data).hexdigest(),bytes=len(data),excerpt=text[max(0,i-120):i+400]))
url='https://www.itu.int/itudoc/itu-t/com16/tiff-fx/docs/tiff6.pdf'
data=subprocess.check_output(['curl.exe','--ssl-revoke-best-effort','-fsSL','--max-time','40',url]);assert data.startswith(b'%PDF')
from pypdf import PdfReader
reader=PdfReader(io.BytesIO(data));excerpts=[]
for page in reader.pages:
 text=page.extract_text()
 if 'RowsPerStrip' in text and 'StripOffsets' in text:
  excerpts.append(text[:1600])
  if len(excerpts)==2:break
assert excerpts
rows.append(dict(url=url,sha256=hashlib.sha256(data).hexdigest(),bytes=len(data),excerpts=excerpts))
(HERE/'references.json').write_text(json.dumps(rows,indent=2)+'\n')
