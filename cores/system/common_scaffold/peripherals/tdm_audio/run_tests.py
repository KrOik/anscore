from pathlib import Path
import sys,json,hashlib,tempfile,random
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import execute
SOURCES=[H/'tdm_audio_rx.sv',H/'tdm_audio_tx.sv']
def hashes():return {p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
def sim(name,tb,files=None):
 with tempfile.TemporaryDirectory(prefix='tdm_audio_') as td:
  p=Path(td)
  for n,s in (files or {}).items():
   q=p/n;q.write_text(s);tb=tb.replace('"'+n+'"','"'+q.as_posix()+'"')
  (p/'tb.sv').write_text(tb)
  execute(['iverilog','-g2012','-s','tb','-o',p/'a.vvp',*SOURCES,p/'tb.sv'],H,H/(name+'_compile.log'))
  result=execute(['vvp',p/'a.vvp'],H,H/(name+'_simulation.log'),timeout=120)
  assert 'PASS' in result;return result
TB=r'''module tb;
localparam NS=@NS@,SB=@SB@,WB=@WB@,DL=@DL@,POL=@POL@,PULSE=@PULSE@,FB=NS*SB,NF=5;
reg bclk=0;always #5 bclk=~bclk;
reg rst_n=0,ce=1,fs=!POL,sd=0,error_clear=0;
wire[WB-1:0]m_sample;wire[3:0]m_slot;wire m_sof,m_last,m_valid;
reg m_ready=1;wire overflow_sticky,framing_sticky;wire[31:0]overflow_count,framing_count;
tdm_audio_rx #(.SLOTS(NS),.SLOT_BITS(SB),.SAMPLE_BITS(WB),.DELAY_BITS(DL),.FS_POLARITY(POL),.FS_PULSE_BITS(PULSE),.FIFO_FRAMES(2))rx(.*);
reg[WB-1:0]s_sample=0;reg[3:0]s_slot=0;reg s_sof=0,s_last=0,s_valid=0;
wire s_ready,tx_sd,underrun_sticky,input_error_sticky;wire[31:0]underrun_count,input_error_count,tx_framing_count;wire tx_framing_sticky;
tdm_audio_tx #(.SLOTS(NS),.SLOT_BITS(SB),.SAMPLE_BITS(WB),.DELAY_BITS(DL),.FS_POLARITY(POL),.FS_PULSE_BITS(PULSE),.FIFO_FRAMES(2))tx(.bclk(bclk),.rst_n(rst_n),.ce(ce),.fs(fs),.error_clear(error_clear),.s_sample(s_sample),.s_slot(s_slot),.s_sof(s_sof),.s_last(s_last),.s_valid(s_valid),.s_ready(s_ready),.sd(tx_sd),.underrun_sticky(underrun_sticky),.input_error_sticky(input_error_sticky),.framing_sticky(tx_framing_sticky),.underrun_count(underrun_count),.input_error_count(input_error_count),.framing_count(tx_framing_count));
reg[WB-1:0]rv[0:NF*NS-1],tv[0:3*NS-1];integer got=0,bits_checked=0,cycles=0,f,b,i,rel,slot,bitno;reg expected,heldvalid=0;reg[WB+5:0]held;
always @(posedge bclk)if(rst_n)begin
 if(heldvalid&&(!m_valid||{m_sample,m_slot,m_sof,m_last}!==held))$fatal(1,"held RX");
 heldvalid=m_valid&&!(ce&&m_ready);held={m_sample,m_slot,m_sof,m_last};
 if(ce&&m_ready&&m_valid)begin
 if(got>=NF*NS||m_sample!==rv[got]||m_slot!=got%NS||m_sof!==(got%NS==0)||m_last!==(got%NS==NS-1))$fatal(1,"RX sample%0d got%h want%h slot%0d",got,m_sample,rv[got],m_slot);got=got+1;end
 if(rx.count>rx.FIFO_FRAMES||(rx.wp+rx.FIFO_FRAMES+1-rx.rp)%(rx.FIFO_FRAMES+1)!=rx.count)$fatal(1,"RX ring invariant");
 if(rx.push&&rx.fetch&&rx.wp==rx.rp)$fatal(1,"RX RAM collision");
 cycles=cycles+1;if(cycles>100000)$fatal(1,"watchdog");
end
always @(negedge bclk)if(rst_n)begin if(tx.count>tx.FIFO_FRAMES||(tx.wp+tx.FIFO_FRAMES+1-tx.rp)%(tx.FIFO_FRAMES+1)!=tx.count)$fatal(1,"TX ring invariant");if(tx.push&&tx.fetch&&tx.wp==tx.rp)$fatal(1,"TX RAM collision");end
initial begin
 $readmemh("rx.hex",rv);$readmemh("tx.hex",tv);
 repeat(4)@(posedge bclk);#1;rst_n=1;
 for(i=0;i<3*NS;i=i+1)begin
 @(posedge bclk);#1;s_valid=1;s_sample=tv[i];s_slot=i%NS;s_sof=i%NS==0;s_last=i%NS==NS-1;
 @(negedge bclk);while(!s_ready)@(negedge bclk);#1;s_valid=0;
 end
 repeat(4)@(posedge bclk);
 for(f=0;f<=NF;f=f+1)for(b=0;b<(f==NF?NS*3+4:FB);b=b+1)begin
 @(posedge bclk);#1;fs=b<PULSE?POL:!POL;ce=(b%11)>2;m_ready=(b%7)>1;
 rel=b-DL;
 if(rel<0)begin slot=NS-1;bitno=SB-1;sd=f>0&&bitno<WB?rv[(f-1)*NS+slot][WB-1-bitno]:0;expected=f>0&&f<=3&&bitno<WB?tv[(f-1)*NS+slot][WB-1-bitno]:0;end
 else begin slot=rel/SB;bitno=rel%SB;sd=f<NF&&bitno<WB?rv[f*NS+slot][WB-1-bitno]:0;expected=f<3&&bitno<WB?tv[f*NS+slot][WB-1-bitno]:0;end
 @(negedge bclk);#1;if(tx_sd!==expected)$fatal(1,"TX wire f%0d b%0d got%b exp%b",f,b,tx_sd,expected);bits_checked=bits_checked+1;
 end
 @(posedge bclk);#1;ce=1;m_ready=1;repeat(2)@(posedge bclk);#1;
 if(got!=NF*NS||overflow_count||framing_count||tx_framing_count||input_error_count||underrun_count!=3)$fatal(1,"totals RX%0d ov%0d fr%0d TXfr%0d in%0d under%0d",got,overflow_count,framing_count,tx_framing_count,input_error_count,underrun_count);
 $display("PASS TDM slots=%0d slotbits=%0d samplebits=%0d delay=%0d polarity=%0d pulse=%0d RX=%0d TXbits=%0d",NS,SB,WB,DL,POL,PULSE,got,bits_checked);$finish;
end
endmodule'''
def profile(ns,sb,wb,dl,pol,pulse):
 rng=random.Random(ns*100000+sb*1000+wb*10+dl*2+pol);rv=[rng.randrange(1<<wb) for _ in range(5*ns)];tv=[rng.randrange(1<<wb) for _ in range(3*ns)]
 tb=TB
 for k,v in dict(NS=ns,SB=sb,WB=wb,DL=dl,POL=pol,PULSE=pulse).items():tb=tb.replace('@'+k+'@',str(v))
 return sim(f'main_{ns}_{sb}_{wb}_{dl}_{pol}_{pulse}',tb,{'rx.hex':'\n'.join(f'{v:x}' for v in rv),'tx.hex':'\n'.join(f'{v:x}' for v in tv)})
def main():
 rows=[]
 for ns in (2,4,8,16):
  for sb in (16,24,32):
   for dl in (0,1):
    for pol in (0,1):
     wb=sb if pol else max(1,sb-8);pulse=1 if pol else 2
     out=profile(ns,sb,wb,dl,pol,pulse);print(out.strip());rows.append(dict(slots=ns,slot_bits=sb,sample_bits=wb,delay=dl,polarity=pol,pulse=pulse,status='PASS'))
 (H/'evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes(),profiles=rows,scope='Independent physical device input and TX wire oracle; complete frames/slots/markers, both FS polarities, delay0/1, full-width wrap, padding, CE0 and output stalls, FIFO address collision assertions'),indent=2)+'\n')
if __name__=='__main__':main()
