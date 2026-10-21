"""Abort/reset every parser, table, inflate, checksum and output boundary, with recovery."""
from run_tests import H,RTL,ROOT,TB,encode,execute
from test_errors import BODY as ERROR_BODY
from test_deflate_limits import dynamic_repeats,Writer,canonical,png
import numpy as np,tempfile,re,json,hashlib
from pathlib import Path
EXTRA=r'''
 task seek_abort;input integer offset,count,phase,reset_it;reg ok,found;begin
 check_output=0;got=0;sink_pause=phase==49;start_valid=1;while(!start_ready)tick;@(posedge clk);tick;start_valid=0;found=0;
 for(i=0;i<count;i=i+1)begin
 if(dut.state==phase)begin found=1;i=count;end
 else begin s_data=source[offset+i];s_last=i==count-1;s_valid=1;ok=0;
 while(!ok)begin @(posedge clk);ok=ce&&s_ready;end tick;end end
 s_valid=0;s_last=0;while(!found)begin if(dut.state==phase)found=1;else if(done_valid)$fatal(1,"phase unreachable %d",phase);else tick;end
 ce_pause=1;tick;
 if(reset_it)begin rst_n=0;@(posedge clk);tick;if(done_valid||m_valid||s_ready)$fatal(1,"reset interfaces");rst_n=1;ce_pause=0;tick;end
 else begin abort=1;repeat(3)tick;if(m_valid||s_ready)$fatal(1,"abort interfaces");ce_pause=0;while(!ce)tick;@(posedge clk);tick;abort=0;
 if(!done_valid||!frame_error||error_code!=8'hf0)$fatal(1,"abort phase %d code%h",phase,error_code);acknowledge;end
 sink_pause=0;
 end endtask
'''
def main():
 a=np.zeros((5,7,1),dtype=np.uint8);good,expected,_=encode(a,'fixed',(0,));stored,_,_=encode(a,'stored',(0,));dynamic,_=dynamic_repeats()
 wr=Writer();wr.field(3,3);lit=canonical([8]*144+[9]*112+[7]*24+[8]*8);dist=canonical([5]*32)
 for _ in range(20):wr.symbol(0,lit)
 wr.symbol(269,lit);wr.field(1,2);wr.symbol(8,dist);wr.field(3,3);wr.symbol(256,lit)
 extra=png(bytes(40),wr.bytes(),7,5)
 source=list(good+stored+dynamic+extra);offsets=[0,len(good),len(good)+len(stored),len(good)+len(stored)+len(dynamic)]
 phases=list(range(1,54))+[55]
 calls=[]
 for phase in phases:
  which=1 if phase in (12,13,14,16,17,18) else 2 if 26<=phase<=34 else 3 if phase==55 else 0
  packet=[good,stored,dynamic,extra][which]
  calls.append(f'seek_abort({offsets[which]},{len(packet)},{phase},0);run(0,{len(good)},0);')
 resets=[1,4,9,20,33,43,47,48,49,53]
 for phase in resets:
  which=2 if phase==33 else 0;packet=[good,stored,dynamic,extra][which]
  calls.append(f'seek_abort({offsets[which]},{len(packet)},{phase},1);run(0,{len(good)},0);')
 body=ERROR_BODY.replace('got!=4','got!=35').split(' initial begin')[0]+EXTRA+' initial begin $readmemh("SRC",source);$readmemh("EXP",expectation);repeat(3)tick;rst_n=1;tick;\n'+'\n'.join(calls)+'\n$display("PASS PNG protocol");$finish;end\nendmodule'
 tb=TB.split(' initial begin')[0]+body
 tb=tb.replace('integer cycles=0,got=0,i;','reg check_output=0,sink_pause=0,ce_pause=0;integer cycles=0,got=0,i;')
 tb=tb.replace('ce=cycles%13>1;m_ready=cycles%7>1;','ce=!ce_pause&&cycles%13>1;m_ready=!sink_pause&&cycles%7>1;')
 tb=tb.replace('always @(posedge clk)if(rst_n)begin','always @(posedge clk)if(!rst_n)stalled=0;else begin')
 tb=tb.replace('if(got>=NP||m_rgb!==expectation[got])','if(check_output&&(got>=NP||m_rgb!==expectation[got]))')
 tb=tb.replace('if(m_sof!==(got==0)||m_eol!==(got%WW==WW-1)||m_last!==(got==NP-1))','if(check_output&&(m_sof!==(got==0)||m_eol!==(got%WW==WW-1)||m_last!==(got==NP-1)))')
 for token,value in [('MW',16),('MH',12),('MC',4096),('WW',7),('HH',5),('NB',len(source)),('NP',35)]:tb=re.sub(r'\b'+token+r'\b',str(value),tb)
 with tempfile.TemporaryDirectory(prefix='png_protocol_') as td:
  d=Path(td)
  for token,values in [('SRC',source),('EXP',[0]*35)]:
   p=d/(token+'.hex');p.write_text('\n'.join(f'{v:x}' for v in values)+'\n');tb=tb.replace('"'+token+'"','"'+p.as_posix()+'"')
  (d/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',str(d/'a.vvp'),str(RTL),str(d/'tb.sv')],ROOT,H/'protocol_compile.log');text=execute(['vvp',str(d/'a.vvp')],ROOT,H/'protocol_simulation.log',timeout=300);assert 'PASS PNG protocol' in text;print(text)
 (H/'protocol_evidence.json').write_text(json.dumps({'result':'PASS','rtl_sha256':hashlib.sha256(RTL.read_bytes()).hexdigest(),'abort_states':phases,'ce_low_reset_states':resets,'healthy_recovery_frames':len(phases)+len(resets),'healthy_pixels':35*(len(phases)+len(resets))},indent=2)+'\n')
if __name__=='__main__':main()
