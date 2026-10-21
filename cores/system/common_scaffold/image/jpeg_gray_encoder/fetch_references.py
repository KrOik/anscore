from pathlib import Path
import urllib.request,hashlib,json
HERE=Path(__file__).resolve().parent
refs=[('libjpeg-turbo marker writer','https://raw.githubusercontent.com/libjpeg-turbo/libjpeg-turbo/main/src/jcmarker.c'),('libjpeg-turbo project license','https://raw.githubusercontent.com/libjpeg-turbo/libjpeg-turbo/main/LICENSE.md')]
rows=[]
for title,url in refs:
 data=urllib.request.urlopen(url,timeout=45).read()
 rows.append(dict(title=title,url=url,bytes=len(data),sha256=hashlib.sha256(data).hexdigest(),usage='Reference only; no copied code. Existing repository arithmetic and entropy reused. APP0 JFIF structure reviewed against marker writer.',license='libjpeg-turbo BSD-style/IJG/zlib terms; see linked LICENSE.md'))
(HERE/'references.json').write_text(json.dumps(dict(status='PASS',references=rows),indent=2));print('PASS references',len(rows))
