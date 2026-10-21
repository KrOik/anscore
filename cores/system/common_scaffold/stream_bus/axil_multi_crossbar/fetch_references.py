"""Retrieve mature AXI fabric references; persist only SHA and small excerpts."""
from pathlib import Path
import subprocess,hashlib,json,datetime
HERE=Path(__file__).resolve().parent

def get(url):
 return subprocess.check_output(['curl.exe','-fsSL','--ssl-revoke-best-effort','--connect-timeout','10','--max-time','35',url])
def main():
 commit=json.loads(get('https://api.github.com/repos/alexforencich/verilog-axi/commits/master'))['sha']
 rows=[]
 for name,keys in [('axil_crossbar_wr.v',['S_COUNT','M_COUNT','AW channel','W channel','B channel']),('axil_crossbar_rd.v',['S_COUNT','M_COUNT','AR channel','R channel']),('arbiter.v',['ARB_TYPE_ROUND_ROBIN','round_robin'])]:
  url=f'https://cdn.jsdelivr.net/gh/alexforencich/verilog-axi@{commit}/rtl/{name}'
  b=get(url);lines=b.decode(errors='replace').splitlines();hits=[i for i,line in enumerate(lines) if any(k.lower() in line.lower() for k in keys)]
  assert hits
  rows.append(dict(name=name,url=url,commit=commit,sha256=hashlib.sha256(b).hexdigest(),bytes=len(b),accessed_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),excerpts=[dict(line=i+1,text='\n'.join(lines[max(0,i-1):i+4])) for i in hits[:5]],use='Architectural comparison of mature separated read/write AXI-Lite fabric and round-robin arbitration. Independently written narrow RTL; no third-party source copied. This small core allows one outstanding transaction per upstream direction rather than matching all reference features.'))
 (HERE/'references.json').write_text(json.dumps(dict(sources=rows),indent=2)+'\n');print('PASS fetched 3 pinned mature code references')
if __name__=='__main__':main()
