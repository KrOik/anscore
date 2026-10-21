"""Configuration atomicity, concurrent inactive loading, CE/backpressure and full recovery."""
from run_tests import H,ROOT,RTL,TB,execute,oracle
from pathlib import Path
import tempfile,numpy as np,json,hashlib
BODY=r'''
 task map_begin;begin cfg_begin_valid=1;wait_begin;cfg_begin_valid=0;end endtask
 task map_write;input integer addr,value;begin cfg_index=addr;cfg_bad=value;cfg_valid=1;wait_cfg;cfg_valid=0;end endtask
 task map_commit;input integer expected_error;begin cfg_commit_valid=1;wait_commit;cfg_commit_valid=0;
 if(!cfg_done_valid||cfg_error!==(expected_error!=0)||cfg_error_code!=expected_error)$fatal(1,"cfg outcome %h expected %d",cfg_error_code,expected_error);cfg_ack;end endtask
 task load_b;begin map_begin;for(i=0;i<N;i=i+1)map_write(i,1);map_commit(0);end endtask
 task start_frame;begin cfg_fill=51;cfg_pattern=2;start_valid=1;wait_start;start_valid=0;cfg_fill=222;cfg_pattern=0;end endtask
 task send_source;input integer corrupt;begin
 for(j=0;j<N;j=j+1)begin
 s_pixel=pixels[j];s_sof=j==0;s_eol=j%W==W-1;s_last=j==N-1;
 if(j==0)begin if(corrupt==1)s_sof=0;if(corrupt==2)s_eol=1;if(corrupt==3)s_last=1;end
 s_valid=1;wait_pixel;if(corrupt!=0)j=N;
 end s_valid=0;end endtask
 task finish_frame;input integer error_expected;begin while(!done_valid)tick;
 if(frame_error!==(error_expected!=0)||error_code!=error_expected)$fatal(1,"frame outcome %h expected %d",error_code,error_expected);
 repeat(3)tick;if(!done_valid)$fatal(1,"DONE lost");frame_ack;end endtask
 task healthy;begin start_frame;send_source(0);finish_frame(0);end endtask
 task reach_phase;input integer phase;begin
 start_frame;if(phase!=1)send_source(0);
 while(dut.state!=phase)tick;
 end endtask
 initial begin
 $readmemh("PIX",pixels);$readmemh("EXP",expected);
 repeat(3)tick;rst_n=1;tick;
 // Unconfigured START has an explicit terminal error.
 start_frame;finish_frame(2);
 map_begin;for(i=N-1;i>=0;i=i-1)map_write(i,i==0);map_commit(0);healthy;
 // Missing one distinct address, duplicate-only writes, invalid address and explicit abort.
 map_begin;for(i=0;i<N-1;i=i+1)map_write(i,1);map_commit(1);
 map_begin;for(i=0;i<N;i=i+1)map_write(0,1);map_commit(1);
 map_begin;map_write(N,1);if(!cfg_done_valid||cfg_error_code!=2)$fatal(1,"bad index");cfg_ack;
 map_begin;cfg_abort=1;while(!ce)tick;@(posedge clk);tick;cfg_abort=0;
 if(!cfg_done_valid||cfg_error_code!=3)$fatal(1,"cfg abort");cfg_ack;healthy;
 // Load B while A output is stalled. Pending commit cannot change current frame bank.
 sink_pause=1;start_frame;send_source(0);while(dut.state!=7)tick;
 load_pending_begin: begin end
 map_begin;for(i=0;i<N;i=i+1)map_write(i,1);
 cfg_commit_valid=1;repeat(9)begin tick;if(cfg_commit_ready||cfg_ready)$fatal(1,"early commit/write");end
 sink_pause=0;while(!done_valid)tick;
 if(frame_error||cfg_commit_ready)$fatal(1,"frame/commit error");repeat(5)tick;
 if(cfg_commit_ready)$fatal(1,"commit during held DONE");frame_ack;wait_commit;cfg_commit_valid=0;
 if(cfg_error||!cfg_done_valid)$fatal(1,"atomic commit");cfg_ack;healthy;
 for(k=1;k<=3;k=k+1)begin start_frame;send_source(k);finish_frame(1);healthy;end
 // All seven active phases, with CE paused before abort/reset and recovery after each.
 for(phase=1;phase<=7;phase=phase+1)begin
 sink_pause=1;reach_phase(phase);ce_pause=1;tick;abort=1;repeat(3)tick;
 if(m_valid||s_ready)$fatal(1,"abort interface");ce_pause=0;while(!ce)tick;@(posedge clk);tick;abort=0;
 if(!done_valid||!frame_error||error_code!=3)$fatal(1,"phase abort %d",phase);
 finish_frame(3);sink_pause=0;healthy;end
 for(phase=1;phase<=7;phase=phase+1)begin
 sink_pause=1;reach_phase(phase);ce_pause=1;tick;rst_n=0;@(posedge clk);tick;
 if(map_active_valid||done_valid||m_valid||s_ready)$fatal(1,"CE-low reset");
 rst_n=1;ce_pause=0;tick;start_frame;finish_frame(2);load_b;sink_pause=0;healthy;end
 if(got!=F*N)$fatal(1,"count %d expected %d",got,F*N);
 $display("PASS defect_map protocol %d healthy pixels",got);$finish;end
endmodule
'''.replace(' load_pending_begin: begin end\n','')
def main():
 shape=(4,6);bits=8;n=24;a=np.arange(n).reshape(shape)*7+1;ma=np.zeros(shape,dtype=np.uint8);ma[0,0]=1;mb=np.ones(shape,dtype=np.uint8)
 expected=[]
 for m in [ma]*3+[mb]*18:
  out,s=oracle(a,m,51);expected.extend(((s<<bits)|out).flat)
 tb=TB.split(' initial begin')[0]+BODY
 tb=tb.replace('integer cycle=0,got=0,f,i;','integer j,k,phase;reg sink_pause=0,ce_pause=0;integer cycle=0,got=0,f,i;')
 tb=tb.replace('ce=cycle%13>1;m_ready=cycle%7>1;','ce=!ce_pause&&cycle%13>1;m_ready=!sink_pause&&cycle%7>1;')
 tb=tb.replace('always @(posedge clk)if(rst_n)begin','always @(posedge clk)if(!rst_n)held_valid=0;else begin')
 tb=tb.replace('if(held_valid&&(!m_valid||token!==held))','if(!abort&&held_valid&&(!m_valid||token!==held))').replace('held_valid=m_valid&&!(ce&&m_ready);','held_valid=!abort&&m_valid&&!(ce&&m_ready);')
 import re
 for token,value in [('WW',6),('HH',4),('BB',8),('FF',21)]:tb=re.sub(r'\b'+token+r'\b',str(value),tb)
 with tempfile.TemporaryDirectory(prefix='defect_protocol_') as td:
  d=Path(td)
  for token,values in [('PIX',list(a.flat)+[0]*(21*n-n)),('EXP',expected)]:
   p=d/(token+'.hex');p.write_text('\n'.join(f'{int(x):x}' for x in values)+'\n');tb=tb.replace('"'+token+'"','"'+p.as_posix()+'"')
  (d/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',str(d/'a.vvp'),str(RTL),str(d/'tb.sv')],ROOT,H/'protocol_compile.log')
  result=execute(['vvp',str(d/'a.vvp')],ROOT,H/'protocol_simulation.log',timeout=180);assert 'PASS defect_map protocol' in result;print(result)
 (H/'protocol_evidence.json').write_text(json.dumps({'result':'PASS','rtl_sha256':hashlib.sha256(RTL.read_bytes()).hexdigest(),'healthy_frames':21,'healthy_pixels':504,'bad_config_cases':4,'malformed_markers':3,'abort_phases':7,'reset_phases':7,'concurrent_inactive_loading':True,'commit_held_through_frame_done':True},indent=2)+'\n')
if __name__=='__main__':main()
