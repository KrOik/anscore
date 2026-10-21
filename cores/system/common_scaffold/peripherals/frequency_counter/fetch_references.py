from pathlib import Path
import subprocess,hashlib,json,datetime
H=Path(__file__).resolve().parent
def get(u):return subprocess.check_output(['curl.exe','-fsSL','--ssl-revoke-best-effort','--connect-timeout','10','--max-time','30',u],stderr=subprocess.PIPE)
def main():
 rows=[]
 for repo,path,terms in [('enjoy-digital/litex','litex/soc/cores/freqmeter.py',['class FreqMeter','counter','period','Gray']),('raspberrypi/pico-examples','pwm/measure_duty_cycle/measure_duty_cycle.c',['measure_duty_cycle','pwm_get_counter','sleep_ms','PWM_DIV_B_HIGH'])]:
  commit=json.loads(get('https://api.github.com/repos/'+repo+'/commits/HEAD'))['sha'];url=f'https://raw.githubusercontent.com/{repo}/{commit}/{path}';b=get(url);lines=b.decode().splitlines();hits=[i for i,x in enumerate(lines) if any(k.lower() in x.lower() for k in terms)];assert len(b)>500 and hits
  rows.append(dict(repository=repo,commit=commit,url=url,sha256=hashlib.sha256(b).hexdigest(),bytes=len(b),accessed_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),excerpts=[dict(line=i+1,text='\n'.join(lines[max(0,i-1):i+4])) for i in hits[:6]],use='Inspect reference gate/count/time normalization and CDC boundary conventions. Independent low-rate sampled-pin RTL; LiteX external-clock-domain Gray-counter architecture is intentionally not copied and has a different high-frequency envelope. No external source retained or claimed equivalent.'))
 (H/'references.json').write_text(json.dumps(dict(status='PASS',sources=rows),indent=2)+'\n');print('PASS actual pinned LiteX frequency meter and Pico gate-count references')
if __name__=='__main__':main()
