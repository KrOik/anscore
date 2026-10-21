"""Retrieve pinned open TMDS examples; no downloaded implementation retained."""
from pathlib import Path
import subprocess,hashlib,json,datetime
HERE=Path(__file__).resolve().parent
def get(url):return subprocess.check_output(['curl.exe','-fsSL','--ssl-revoke-best-effort','--connect-timeout','10','--max-time','30',url])
def main():
 rows=[]
 entries=[('projf/display_controller','rtl/tmds_encoder_dvi.v',['use_xnor','enc_qm[8]','balance =','bias >','ctrl sequences']),('hdl-util/hdmi','src/tmds_channel.sv',['N1D >','acc ==','acc_add =','control_data)'])]
 for repo,path,keys in entries:
  commit=json.loads(get('https://api.github.com/repos/'+repo+'/commits/HEAD'))['sha']
  url=f'https://cdn.jsdelivr.net/gh/{repo}@{commit}/{path}'
  b=get(url);lines=b.decode(errors='replace').splitlines();hits=[i for i,line in enumerate(lines) if any(k.lower() in line.lower() for k in keys)]
  assert hits
  rows.append(dict(repository=repo,url=url,commit=commit,sha256=hashlib.sha256(b).hexdigest(),bytes=len(b),accessed_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),excerpts=[dict(line=i+1,text='\n'.join(lines[max(0,i-1):i+4])) for i in hits[:4]],use='Compare transition-minimizing stage and control/video disparity conventions. Original implementation written independently; HDMI data islands/TERC4/guard bands are excluded.'))
 (HERE/'references.json').write_text(json.dumps(dict(sources=rows),indent=2)+'\n');print('PASS 2 actual pinned TMDS references')
if __name__=='__main__':main()
