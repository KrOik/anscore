from pathlib import Path
import subprocess,json,hashlib,datetime
H=Path(__file__).resolve().parent
def get(u):return subprocess.check_output(['curl.exe','-fsSL','--ssl-revoke-best-effort','--connect-timeout','10','--max-time','30',u],stderr=subprocess.PIPE)
def main():
 repo='analogdevicesinc/hdl';commit=json.loads(get('https://api.github.com/repos/'+repo+'/commits/HEAD'))['sha'];rows=[]
 for name in ['i2s_rx.vhd','i2s_tx.vhd']:
  path='library/axi_i2s_adi/'+name
  for url in [f'https://cdn.jsdelivr.net/gh/{repo}@{commit}/{path}',f'https://raw.githubusercontent.com/{repo}/{commit}/{path}']:
   try:b=get(url);break
   except subprocess.CalledProcessError:continue
  else:raise RuntimeError('reference retrieval failed')
  lines=b.decode().splitlines();hits=[i for i,x in enumerate(lines) if any(k in x.lower() for k in ['channel_sync','frame_sync','data_int','bit_sync'])];assert len(b)>1000 and hits
  rows.append(dict(repository=repo,commit=commit,url=url,sha256=hashlib.sha256(b).hexdigest(),bytes=len(b),accessed_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),excerpts=[dict(line=i+1,text='\n'.join(lines[max(0,i-1):i+3])) for i in hits[:5]],use='Actual mature serial-audio reference inspected for bit/channel/frame boundary separation, shifting and frame buffering. Independent native-BCLK single-wire TDM implementation; this reference is not claimed bit-equivalent to arbitrary-slot TDM or used as a substitute for independent waveform oracle. No downloaded source retained.'))
 (H/'references.json').write_text(json.dumps(dict(status='PASS',sources=rows),indent=2)+'\n');print('PASS actual pinned RX/TX references fetched and inspected')
if __name__=='__main__':main()
