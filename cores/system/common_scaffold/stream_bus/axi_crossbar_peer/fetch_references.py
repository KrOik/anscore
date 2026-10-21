"""Fetch real mature references in memory, retaining SHA and short excerpts only."""
from pathlib import Path
import subprocess,json,hashlib,datetime
HERE=Path(__file__).resolve().parent
SOURCES=[('https://cdn.jsdelivr.net/gh/alexforencich/verilog-axi@master/rtl/axi_crossbar_addr.v',['M_ADDR_WIDTH','ADDR_WIDTH','decode']),('https://cdn.jsdelivr.net/gh/pulp-platform/axi@master/src/axi_pkg.sv',['beat_addr','aligned_addr','wrap_boundary']),('https://zipcpu.com/blog/2019/04/27/axi-addr.html',['wrap','unaligned','4096'])]
def main():
 rows=[]
 for url,terms in SOURCES:
  data=subprocess.check_output(['curl.exe','-fsSL','--ssl-revoke-best-effort','--max-time','40',url]);lines=data.decode('utf-8','replace').splitlines();excerpts=[]
  for term in terms:
   hits=[i for i,s in enumerate(lines) if term.lower() in s.lower()]
   if hits:excerpts.append(dict(term=term,line=hits[0]+1,text='\n'.join(lines[max(0,hits[0]-1):hits[0]+7])))
  assert len(data)>1000 and excerpts
  rows.append(dict(url=url,bytes=len(data),sha256=hashlib.sha256(data).hexdigest(),excerpts=excerpts))
 (HERE/'references.json').write_text(json.dumps(dict(accessed_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),sources=rows,scope='Actual memory-only reference fetch; independent byte-address equations, no owner validation imported and no copied RTL.'),indent=2)+'\n', encoding="utf-8")
 print('PASS actual public references',len(rows))
if __name__=='__main__':main()
