"""Fault termination, CE-paused abort/reset and healthy frame recovery."""
from pathlib import Path
import tempfile,json,numpy as np
from run_tests import HERE,RTL,TB,jpeg,execute,hashes
PRE=r'''
 active=0;
 for(test=0;test<7;test=test+1)begin
 target=(test==0)?1:(test==1)?2:(test==2)?10:(test==3)?16:(test==4)?24:(test==5)?32:21;
 start_valid=1;while(!start_ready)tick;@(posedge clk);#1;tick;start_valid=0;
 fork
 begin
 for(j=0;j<NN;j=j+1)begin
 if(!done_valid)begin s_data=filebytes[j];s_last=j==NN-1;s_valid=1;while(!s_ready&&!done_valid)tick;
 if(!done_valid)begin @(posedge clk);#1;tick;end end
 end
 s_valid=0;s_last=0;
 end
 begin
 while(dut.state!=target)tick;
 abort=1;while(!ce)tick;@(posedge clk);#1;tick;abort=0;
 end
 join
 while(!done_valid)tick;
 if(!done_error||error_code!=8'h93)$fatal(1,"abort result %h",error_code);
 repeat(3)tick;done_ready=1;while(!ce)tick;@(posedge clk);#1;tick;done_ready=0;
 end
 // Synchronous reset is honored even at CE=0; a held output must disappear.
 start_valid=1;while(!start_ready)tick;@(posedge clk);#1;tick;start_valid=0;
 for(j=0;j<NN;j=j+1)begin s_data=filebytes[j];s_last=j==NN-1;s_valid=1;while(!s_ready)tick;@(posedge clk);#1;tick;end
 s_valid=0;s_last=0;while(dut.state!=24)tick;
 force ce=0;rst_n=0;@(posedge clk);#1;if(busy||done_valid||m_valid)$fatal(1,"reset while disabled");tick;rst_n=1;release ce;
 active=1;
'''
def main():
 a=np.arange(99,dtype=np.uint8).reshape(9,11);b=jpeg(a,87,opt=True)
 with tempfile.TemporaryDirectory(prefix='jpeg_protocol_') as tmp:
  d=Path(tmp);(d/'input.hex').write_text('\n'.join(f'{v:02x}' for v in b)+'\n')
  tb=TB.replace('integer i,cyc=0','integer test,target,j;reg active=1;integer i,cyc=0').replace('always @(posedge clk)if(rst_n)begin','always @(posedge clk)if(rst_n&&active)begin').replace('repeat(3)tick;rst_n=1;tick;','repeat(3)tick;rst_n=1;tick;'+PRE)
  tb=tb.replace('NN',str(len(b))).replace('WW','11').replace('HH','9').replace('ERR','0').replace('INPUT',(d/'input.hex').as_posix()).replace('OUTPUT',(d/'output.txt').as_posix())
  (d/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],HERE.parents[3],d/'compile.log');text=execute(['vvp',d/'a.vvp'],HERE.parents[3],d/'sim.log',timeout=180)
  assert 'PASS jpeg' in text;text=text.strip();print(text)
 (HERE/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes(),abort_states=[1,2,10,16,24,32,21],reset_ce_disabled=True,healthy_recovery_frames=2),indent=2)+'\n')
if __name__=='__main__':main()
