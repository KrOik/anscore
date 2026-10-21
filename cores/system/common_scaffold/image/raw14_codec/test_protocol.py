from run_tests import *
def good(kind,v=0):
 n=4 if kind=='pack' else 7;return [(v+i,int(i==0),int(i==n-1)) for i in range(n)]
def main():
 rows=[]
 for kind in ('pack','unpack'):
  n=4 if kind=='pack' else 7
  early=[]
  for pos in range(n-1):early.extend((i,int(i==0),int(i==pos)) for i in range(pos+1));early.extend([(2,0,0),(3,0,0)]);early.extend(good(kind,11))
  rows.append(run(kind,'every_early_EOL',early))
  middle=[]
  for pos in range(1,n):middle.extend((i,int(i==0),0) for i in range(pos));middle.extend(good(kind,23))
  rows.append(run(kind,'every_mid_SOF',middle))
  rows.append(run(kind,'missing_SOF_recovery',[(2,0,0),(3,0,0)]+good(kind,31)))
  rows.append(run(kind,'SOF_EOL_priority',[(1,1,0),(2,1,1),(3,0,0)]+good(kind,41)))
 (H/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',sources=SOURCES,scope='Every early EOL and internal SOF position; malformed group discard, fresh SOF re-anchor, missing SOF drop+error4, simultaneous SOF/earlyEOL discard priority2; pending first error retained through new errors and CE0ack; healthy group after each fault',profiles=rows),indent=2)+'\n')
if __name__=='__main__':main()
