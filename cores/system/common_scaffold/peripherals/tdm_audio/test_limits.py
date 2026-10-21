from run_tests import *
def long_profile(ns,sb,wb,dl,pol,pulse,depth=2):
 nf=32;rng=random.Random(9876+ns+wb);rv=[rng.randrange(1<<wb) for _ in range(nf*ns)];tv=[rng.randrange(1<<wb) for _ in range(nf*ns)]
 tb=TB.replace('.FIFO_FRAMES(2)',f'.FIFO_FRAMES({depth})').replace('NF=5','NF='+str(nf)).replace('tv[0:3*NS-1]','tv[0:NF*NS-1]').replace('f<=3','f<=NF').replace('f<3','f<NF').replace('underrun_count!=3','underrun_count!=1')
 tb=tb.replace(' for(f=0;f<=NF;',r''' fork begin
 for(i=3*NS;i<NF*NS;i=i+1)begin
 @(posedge bclk);#2;s_valid=1;s_sample=tv[i];s_slot=i%NS;s_sof=i%NS==0;s_last=i%NS==NS-1;
 @(negedge bclk);while(!(ce&&s_ready))@(negedge bclk);#1;s_valid=0;
 end end begin
 for(f=0;f<=NF;''').replace(' @(posedge bclk);#1;ce=1;m_ready=1;',' end join\n @(posedge bclk);#1;ce=1;m_ready=1;')
 for k,v in dict(NS=ns,SB=sb,WB=wb,DL=dl,POL=pol,PULSE=pulse).items():tb=tb.replace('@'+k+'@',str(v))
 return sim(f'long_{ns}_{sb}_{wb}_{dl}_{pol}_{pulse}',tb,{'rx.hex':'\n'.join(f'{v:x}' for v in rv),'tx.hex':'\n'.join(f'{v:x}' for v in tv)})
def main():
 rows=[]
 for p in [(2,16,1,0,0,31),(4,24,1,1,1,1),(8,24,20,1,0,3,3),(16,32,32,1,1,1,8),(3,24,17,0,0,2,5),(5,16,16,1,1,1,4),(15,32,31,0,1,7,7),(2,16,16,1,1,31,8)]:
  out=long_profile(*p);print(out);rows.append(dict(profile=p,status='PASS',output=out))
 (H/'limits_evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes(),profiles=rows,scope='32frame concurrent producer/wire/RX stream per profile, all FIFO pointer wraps, samplebits1 and32, maximum legal FS pulse, max slots, CE0/stalls, independent input/output bit oracle'),indent=2)+'\n')
if __name__=='__main__':main()
