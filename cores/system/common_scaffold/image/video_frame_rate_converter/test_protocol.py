from run_tests import *
def main():
 rows=[run('tick_every_clock',w=1,h=1,num=1,den=1,input_every=1,interval=1,ticks=800),run('odd_backpressure',w=3,h=5,num=2,den=3,input_every=1,interval=7,ticks=300),run('marker_fault',bad=True),run('rate_coprime',w=7,h=2,num=7,den=11,input_every=3,interval=23,ticks=400)]
 assert rows[0]['coverage']['triple_collision']>0
 assert rows[0]['counters'][4]>0 and rows[0]['counters'][5]>0
 (H/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),profiles=rows),indent=2)+'\n')
if __name__=='__main__':main()
