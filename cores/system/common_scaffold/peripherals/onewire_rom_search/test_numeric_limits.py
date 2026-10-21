from run_tests import *
def main():
 rows=[]
 values=[rom(v) for v in range(16)]
 for limit in (1,2,16):
  rows.append(run('limit_'+str(limit),values,error=5 if limit<16 else 0,outputs=limit,maxdev=limit))
  rows.append(run('exact_'+str(limit),values[:limit],outputs=limit,maxdev=limit))
 for clock in (2000000,27000000,250000000):rows.append(run('clock_'+str(clock),[rom(0xabcdef28)],clock=clock,delay=13.9))
 for clock in (999999,1500000,250000001):rows.append(run('badclock_'+str(clock),[],error=1,outputs=0,clock=clock))
 for limit in (0,65536):rows.append(run('badlimit_'+str(limit),[],error=1,outputs=0,maxdev=limit))
 rows.append(run('badtimeout',[],error=1,outputs=0,timeout=999))
 (H/'numeric_evidence.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),profiles=rows),indent=2)+'\n')
if __name__=='__main__':main()
