from run_tests import *
def main():
 rows=[]
 for filt,depth in [(1,2),(2,3),(8,16),(32,256)]:
  rx=[0x00,0xff,0x55,0xaa,0x1c,0xf0];tx=[0x00,0xff,0x55,0xaa,0xed,0xf4];tb=TB.replace('NR',str(len(rx))).replace('NT',str(len(tx))).replace('.FILTER_CYCLES(3)',f'.FILTER_CYCLES({filt})').replace('.RX_FIFO_DEPTH(4)',f'.RX_FIFO_DEPTH({depth})');out=execute_tb(f'numeric_f{filt}_d{depth}',tb,dict(RX=rx,TX=tx));rows.append(dict(filter_cycles=filt,fifo_depth=depth,rx_bytes=len(rx),tx_bytes=len(tx),status='PASS'))
 (H/'numeric_evidence.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),profiles=rows),indent=2)+'\n');print(json.dumps(rows))
if __name__=='__main__':main()
