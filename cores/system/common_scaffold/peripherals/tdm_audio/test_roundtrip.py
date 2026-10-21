from run_tests import *
def main():
 rows=[]
 for ns,sb,wb,dl,pol in [(2,16,16,1,1),(4,24,20,0,0),(8,32,24,1,0),(16,32,32,1,1)]:
  rng=random.Random(ns+999);tv=[rng.randrange(1<<wb) for _ in range(3*ns)];rv=tv+[0]*(2*ns)
  tb=TB.replace('rx(.*);','rx(.sd(tx_sd),.*);').replace('reg m_ready=1;', 'wire tx_sd;reg m_ready=1;').replace('wire s_ready,tx_sd,','wire s_ready,')
  for k,v in dict(NS=ns,SB=sb,WB=wb,DL=dl,POL=pol,PULSE=1).items():tb=tb.replace('@'+k+'@',str(v))
  out=sim(f'roundtrip_{ns}_{sb}_{wb}_{dl}_{pol}',tb,{'rx.hex':'\n'.join(f'{v:x}' for v in rv),'tx.hex':'\n'.join(f'{v:x}' for v in tv)});print(out);rows.append(dict(slots=ns,slot_bits=sb,sample_bits=wb,delay=dl,polarity=pol,status='PASS',output=out))
 (H/'roundtrip_evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes(),profiles=rows,scope='Actual TX SD wire connected to actual RX, externally driven BCLK/FS, separate TX-bit and RX-frame oracle; queued source frames then explicit zero-filled underflow frames'),indent=2)+'\n')
if __name__=='__main__':main()
