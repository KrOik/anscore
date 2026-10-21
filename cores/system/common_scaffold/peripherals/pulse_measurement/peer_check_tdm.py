"""Read-only TDM review with independent pin-symbol oracle, no owner test reuse."""
from test_measurement import HERE,execute
from pathlib import Path
import tempfile,hashlib,json,re
OTHER=HERE.parent/'tdm_audio'
TB=r'''
module tb;
localparam S=@S@,B=@B@,W=@W@,D=@D@,P=@P@,F=S*B,FP=F-1;
reg bclk=0;always #5 bclk=~bclk;
reg rst_n=0,ce=1,fs=!P,error_clear=0;
reg[W-1:0]s_sample=0;reg[3:0]s_slot=0;
reg s_sof=0,s_last=0,s_valid=0,m_ready=0;
wire s_ready,sd;wire[W-1:0]m_sample;wire[3:0]m_slot;wire m_sof,m_last,m_valid;
wire us,ie,tf,ro,rf;wire[31:0]uc,ic,tc,oc,rc;
tdm_audio_tx #(.SLOTS(S),.SLOT_BITS(B),.SAMPLE_BITS(W),.DELAY_BITS(D),.FS_POLARITY(P),.FS_PULSE_BITS(FP),.FIFO_FRAMES(2)) tx(
.bclk(bclk),.rst_n(rst_n),.ce(ce),.fs(fs),.error_clear(error_clear),.s_sample(s_sample),.s_slot(s_slot),.s_sof(s_sof),.s_last(s_last),.s_valid(s_valid),.s_ready(s_ready),.sd(sd),.underrun_sticky(us),.input_error_sticky(ie),.framing_sticky(tf),.underrun_count(uc),.input_error_count(ic),.framing_count(tc));
tdm_audio_rx #(.SLOTS(S),.SLOT_BITS(B),.SAMPLE_BITS(W),.DELAY_BITS(D),.FS_POLARITY(P),.FS_PULSE_BITS(FP),.FIFO_FRAMES(2)) rx(
.bclk(bclk),.rst_n(rst_n),.ce(ce),.fs(fs),.sd(sd),.error_clear(error_clear),.m_sample(m_sample),.m_slot(m_slot),.m_sof(m_sof),.m_last(m_last),.m_valid(m_valid),.m_ready(m_ready),.overflow_sticky(ro),.framing_sticky(rf),.overflow_count(oc),.framing_count(rc));
function[W-1:0]word(input integer n,input integer slot_);word=((n+1)*197+slot_*37);endfunction
function frame_bit(input integer frame_,input integer position_);
integer n,slot_,bit_;reg[W-1:0]v;
begin
 n=frame_==0?0:frame_==1?1:frame_==3?2:-1;
 slot_=position_/B;bit_=position_%B;
 v=n<0?0:word(n,slot_);
 frame_bit=bit_<W?v[W-1-bit_]:0;
end endfunction
task send(input integer n);
integer k;
begin
 for(k=0;k<S;k=k+1)begin
  @(posedge bclk);#1;s_sample=word(n,k);s_slot=k;s_sof=k==0;s_last=k==S-1;s_valid=1;
  begin:a forever begin @(negedge bclk);if(ce&&s_ready)begin #1;disable a;end end end
  @(posedge bclk);#1;s_valid=0;
 end
end endtask
integer received=0,rfidx,slotidx,n,frames=0,phase=0,pins=0;
reg held=0;reg[W+5:0]holdword;reg expected;
always @(posedge bclk)if(rst_n)begin
 if(held&&(!m_valid||{m_last,m_sof,m_slot,m_sample}!==holdword))$fatal(1,"peer held RX token mutated");
 held=m_valid&&!m_ready;holdword={m_last,m_sof,m_slot,m_sample};
 if(m_valid&&m_ready)begin
  rfidx=received/S;slotidx=received%S;n=rfidx==0?0:rfidx==1?1:rfidx==3?2:-1;
  if(m_slot!==slotidx||m_sof!==(slotidx==0)||m_last!==(slotidx==S-1)||m_sample!==(n<0?{W{1'b0}}:word(n,slotidx)))$fatal(1,"peer RX word/order frame%0d slot%0d got%h",rfidx,slotidx,m_sample);
  received=received+1;
 end
end else held=0;
initial begin
 repeat(3)@(posedge bclk);#1;rst_n=1;send(0);send(1);repeat(4)@(posedge bclk);
 fork
  begin
   for(frames=0;frames<6;frames=frames+1)begin
    for(phase=0;phase<(frames==5?1:F);phase=phase+1)begin
     @(posedge bclk);#1;fs=phase<FP?P:!P;
     if(frames==2&&phase==3)m_ready=1;
     @(negedge bclk);#1;
     expected=D==0?frame_bit(frames,phase):phase==0?(frames==0?0:frame_bit(frames-1,F-1)):frame_bit(frames,phase-1);
     if(sd!==expected)$fatal(1,"peer pin frame%0d phase%0d got%b expected%b",frames,phase,sd,expected);
     pins=pins+1;
    end
   end
  end
  begin wait(frames==2&&phase==F/2);send(2);end
 join
 repeat(10)@(posedge bclk);#1;
 if(received!=5*S||oc||ic||!us||uc<2)$fatal(1,"peer counts received%0d expected%0d ovf%0d inputerr%0d under%0d",received,5*S,oc,ic,uc);
 $display("PASS TDM PEER slots=%0d sample=%0d delay=%0d fswidth=%0d pinbits=%0d words=%0d underrunWholeFrame",S,W,D,FP,pins,received);$finish;
end
initial begin #1000000;$fatal(1,"watchdog");end
endmodule
'''
def main():
 sources={n:hashlib.sha256((OTHER/n).read_bytes()).hexdigest() for n in ['tdm_audio_rx.sv','tdm_audio_tx.sv']}
 rows=[]
 for slots,bits,width,delay,pol in [(2,16,16,1,0),(3,24,1,1,1),(2,16,1,0,0)]:
  tb=TB
  for k,v in dict(S=slots,B=bits,W=width,D=delay,P=pol).items():tb=tb.replace('@'+k+'@',str(v))
  label=f'{slots}_{bits}_{width}_{delay}_{pol}'
  with tempfile.TemporaryDirectory(prefix='tdm_peer_') as tmp:
   p=Path(tmp);(p/'tb.sv').write_text(tb)
   execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*[OTHER/n for n in sources],p/'tb.sv'],p,p/'compile.log');out=execute(['vvp',p/'sim'],p,p/'run.log')
  assert 'PASS TDM PEER' in out;(HERE/f'peer_tdm_{label}.log').write_text(out);print(out);rows.append(dict(profile=label,output=out))
 for n,h in sources.items():assert hashlib.sha256((OTHER/n).read_bytes()).hexdigest()==h
 (HERE/'peer_tdm_directed_evidence.json').write_text(json.dumps(dict(status='PASS',sources=sources,profiles=rows),indent=2)+'\n')
if __name__=='__main__':main()
