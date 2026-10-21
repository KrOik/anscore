"""Actual mature reference fetches, memory-only; no imported implementation."""
from pathlib import Path
import subprocess,hashlib,json,datetime
HERE=Path(__file__).resolve().parent
def main():
 rows=[]
 for repo,path,terms in [
  ('raspberrypi/pico-examples','pwm/measure_duty_cycle/measure_duty_cycle.c',['measure_duty_cycle','PWM_DIV_B_HIGH','pwm_get_counter']),
  ('ZipCPU/wbuart32','rtl/rxuart.v',['q_uart','qq_uart','ASYNC_REG'])]:
  url=f'https://cdn.jsdelivr.net/gh/{repo}@master/{path}'
  data=subprocess.check_output(['curl.exe','-fsSL','--ssl-revoke-best-effort','--connect-timeout','10','--max-time','40',url]);lines=data.decode('utf-8','replace').splitlines();excerpts=[]
  for term in terms:
   hit=next((i for i,s in enumerate(lines) if term in s),None)
   if hit is not None:excerpts.append(dict(term=term,line=hit+1,text='\n'.join(lines[max(0,hit-1):hit+5])))
  assert len(data)>1000 and len(excerpts)>=2
  rows.append(dict(repository=repo,url=url,bytes=len(data),sha256=hashlib.sha256(data).hexdigest(),excerpts=excerpts))
 (HERE/'references.json').write_text(json.dumps(dict(accessed_utc=datetime.datetime.now(datetime.timezone.utc).isoformat(),sources=rows,scope='Pico duty-cycle gate/count and ZipCPU asynchronous-pin synchronization design references; original measurement RTL, no copied source or analog metastability certification.'),indent=2)+'\n')
 print('PASS actual public reference fetches',len(rows))
if __name__=='__main__':main()
