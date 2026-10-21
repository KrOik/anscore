from run_tests import *
import re
BASE=TB[:TB.index(' initial begin')]
EXTRA=r'''
 integer phase,j,successes=0;
 task begin_frame;begin
 while(!start_ready)tick;start_valid=1;while(!ce)tick;@(posedge clk);tick;start_valid=0;got=0;
 end endtask
 task feed;input integer count;integer j;begin
 for(j=0;j<count&&!done_valid;j=j+1)begin s_data=source[j];s_last=j==NB-1;s_valid=1;send;end s_valid=0;s_last=0;end endtask
 task finish_frame;input integer err;begin
 while(!done_valid)tick;if(error_code!=err||(err==0&&got!=NP))$fatal(1,"finish err %h expected %d got %d",error_code,err,got);
 repeat(4)tick;if(!done_valid||start_ready)$fatal(1,"done persistence");done_ready=1;while(!ce)tick;@(posedge clk);tick;done_ready=0;if(!start_ready)$fatal(1,"ack");end endtask
 task healthy;begin begin_frame;feed(NB);finish_frame(0);successes=successes+1;end endtask
 initial begin
 $readmemh("SRC",source);$readmemh("EXP",expectation);repeat(3)tick;rst_n=1;tick;
 healthy;
 // Each input/header validation and synchronous-read/output state aborts cleanly.
 for(phase=1;phase<=5;phase=phase+1)begin
 begin_frame;
 if(phase==1)feed(7);
 if(phase==2)feed(54);
 if(phase==3)feed(60);
 if(phase>=4)begin
 force m_ready=0;feed(NB);while(dut.state!=4&&dut.state!=5)tick;
 if(phase==5)begin while(dut.state!=5)tick;end
 end
 if(dut.state!=phase)$fatal(1,"abort state %d expected %d",dut.state,phase);$display("ABORT_STATE %d",dut.state);abort=1;while(!ce)tick;@(posedge clk);tick;abort=0;s_valid=0;finish_frame(8);release m_ready;healthy;
 end
 // Header error then same-instance healthy operation.
 begin_frame;source[0]=0;feed(NB);finish_frame(2);source[0]=8'h42;healthy;
 // Truncation then healthy operation.
 begin_frame;for(j=0;j<70;j=j+1)begin s_data=source[j];s_last=j==69;s_valid=1;send;end s_valid=0;s_last=0;finish_frame(5);healthy;
 // CE freezes every active state; asynchronous-to-CE synchronous reset wins.
 for(phase=1;phase<=5;phase=phase+1)begin
 begin_frame;
 if(phase==1)feed(7);
 if(phase==2)feed(54);
 if(phase==3)feed(60);
 if(phase>=4)begin force m_ready=0;feed(NB);while(dut.state!=4&&dut.state!=5)tick;if(phase==5)while(dut.state!=5)tick;end
 if(dut.state!=phase)$fatal(1,"reset state %d expected %d",dut.state,phase);
 force ce=0;repeat(3)tick;if(dut.state!=phase)$fatal(1,"CE freeze");$display("RESET_STATE %d",dut.state);
 rst_n=0;repeat(3)tick;if(!start_ready||done_valid||m_valid)$fatal(1,"reset CE");stalled=0;rst_n=1;release ce;release m_ready;tick;healthy;
 end
 // Missing last is rejected at bfSize, then recovers.
 begin_frame;for(j=0;j<NB;j=j+1)begin s_data=source[j];s_last=0;s_valid=1;send;end s_valid=0;finish_frame(6);healthy;
 begin_frame;feed(NB);while(!m_valid||!m_last)tick;force m_ready=0;repeat(9)tick;
 if(done_valid||got!=NP-1||!m_valid||!m_last)$fatal(1,"last drain");release m_ready;finish_frame(0);successes=successes+1;
 if(successes!=15)$fatal(1,"success count %d",successes);
 $display("PASS BMP protocol recovery abort reset");$finish;
 end
endmodule'''
def main():
 data,pix=fixture(3,4,True,7,3)
 # Keep ready forced high by base pattern except abort output tests force it explicitly.
 text=BASE+EXTRA
 text=text
 with tempfile.TemporaryDirectory(prefix='bmp_protocol_') as td:
  d=Path(td)
  for token,values in [('SRC',data),('EXP',pix)]:
   p=d/(token+'.hex');p.write_text('\n'.join(f'{v:x}' for v in values)+'\n');text=text.replace('"'+token+'"','"'+p.as_posix()+'"')
  for a,b in [('MW',64),('MH',64),('WW',3),('HH',4),('NB',len(data)),('NP',len(pix))]:text=re.sub(r'\b'+a+r'\b',str(b),text)
  (d/'tb.sv').write_text(text);execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],ROOT,H/'protocol_compile.log')
  out=execute(['vvp',d/'a.vvp'],ROOT,H/'protocol_simulation.log');assert 'PASS BMP protocol' in out
 (H/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),healthy_recovery_frames=15,abort_states=5,malformed_recovery=3,ce_low_reset=5,last_pixel_stall_cycles=9,observed_abort_states=[1,2,3,4,5],observed_ce_low_reset_states=[1,2,3,4,5]),indent=2)+'\n');print(out)
if __name__=='__main__':main()


