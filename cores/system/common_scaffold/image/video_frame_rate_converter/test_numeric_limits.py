from run_tests import *
def main():
 rows=[run('one_pixel',w=1,h=1,interval=20,ticks=80),run('odd_5x7',w=5,h=7,interval=100,ticks=60),run('max_64x64',w=64,h=64,interval=10000,ticks=12),run('width_256_height_16',w=256,h=16,interval=10000,ticks=12),run('height_256',w=1,h=256,interval=900,ticks=20),run('max_payload32',w=64,h=48,pw=32,interval=8500,ticks=12),run('pixel1',w=1,h=1,pw=1,interval=20,ticks=40)]
 (H/'numeric_evidence.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),profiles=rows),indent=2)+'\n')
if __name__=='__main__':main()
