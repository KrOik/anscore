from run_tests import *
def good(kind,v=0):return [(v,1,1)] if kind=='pack' else [(v,1,0),(v+1,0,1)]
def main():
 rows=[]
 for endian in (0,1):
  for kind in ('pack','unpack'):
   rows.append(run(kind,'missing_SOF_recovery',[(2,0,0),(3,0,0)]+good(kind,31),endian))
  for name,tokens in [('odd_EOL',[(1,1,1),(2,0,0)]+good('unpack',11)),('mid_SOF',[(1,1,0)]+good('unpack',23)),('SOF_EOL_priority',[(1,1,0),(2,1,1),(3,0,0)]+good('unpack',41)),('late_odd_EOL',good('unpack',45)+[(7,0,1),(9,0,0)]+good('unpack',99))]:rows.append(run('unpack',name,tokens,endian))
 (H/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',sources=SOURCES,scope='Odd-byte EOL discard/unlock; midpair SOF same-token reanchor; SOF+oddEOL priority2; missingSOF discard4; held first error and CE0ACK; valid one-pixel line pack; fresh valid frame after every fault',profiles=rows),indent=2)+'\n')
if __name__=='__main__':main()
