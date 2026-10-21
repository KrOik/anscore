"""Abort/reset at every active state, marker errors, CE and recovery on real RTL."""
import tempfile,json
from pathlib import Path
from run_tests import HERE,RTL,execute,hashes
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,abort=0,cfg_top_down=0;
reg[23:0]s_pixel=24'h123456;reg s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=1,done_ready=0;
wire start_ready,s_ready,m_valid,m_sof,m_last,done_valid,done_error,busy;wire[7:0]m_data,error_code;wire[31:0]output_bytes;
bmp_encoder #(.WIDTH(3),.HEIGHT(2))dut(.*);
integer i,k,good=0;reg[31:0]saved_count;reg[7:0]saved_byte;
task tick;begin @(negedge clk);#1;end endtask
task step;begin @(posedge clk);#1;tick;end endtask
task launch;begin if(!start_ready)$fatal(1,"not ready");start_valid=1;step;start_valid=0;end endtask
task feed;input integer bad;begin
for(i=0;i<6;i=i+1)begin
s_valid=1;s_sof=(i==0);s_eol=(i%3==2);s_last=(i==5);
if(i==0&&bad==1)s_sof=0;
if(i==0&&bad==2)s_eol=1;
if(i==0&&bad==3)s_last=1;
if(i==1&&bad==4)s_sof=1;
if(i==2&&bad==5)s_eol=0;
if(i==5&&bad==6)s_last=0;
step;if(done_valid)i=6;
end s_valid=0;end endtask
task ack;begin done_ready=1;step;done_ready=0;if(!start_ready)$fatal(1,"ack");end endtask
task healthy;begin launch;feed(0);while(!done_valid)step;
if(done_error||output_bytes!=78)$fatal(1,"healthy frame");good=good+1;ack;end endtask
task expect_error;input integer code;begin
if(!done_valid||!done_error||error_code!=code)$fatal(1,"error %d got %d",code,error_code);
repeat(4)step;if(!done_valid)$fatal(1,"error not held");ack;healthy;end endtask
initial begin repeat(3)tick;rst_n=1;tick;healthy;
for(k=1;k<=6;k=k+1)begin launch;feed(k);expect_error(3);end
// Cover each active FSM state, including synchronous RAM issue/wait.
for(k=1;k<=6;k=k+1)begin
launch;if(k!=1)feed(0);
while(dut.state!=k)step;
ce=0;saved_count=output_bytes;saved_byte=m_data;
repeat(4)step;if(output_bytes!=saved_count||dut.state!=k||m_data!==saved_byte)$fatal(1,"CE freeze");
ce=1;abort=1;step;abort=0;expect_error(2);
end
// Synchronous reset must work while CE is low, in all six active states.
for(k=1;k<=6;k=k+1)begin
launch;if(k!=1)feed(0);while(dut.state!=k)step;
ce=0;rst_n=0;step;if(!start_ready||busy||done_valid)$fatal(1,"CE-off reset");
rst_n=1;ce=1;healthy;
end
// Hold last byte under backpressure: no early DONE and stable byte/markers.
launch;feed(0);while(!(m_valid&&m_last))step;m_ready=0;saved_byte=m_data;
repeat(7)step;if(done_valid||!m_last||m_data!==saved_byte)$fatal(1,"last-byte hold");
m_ready=1;step;if(!done_valid||done_error)$fatal(1,"last drain");ack;
// Abort in IDLE and DONE is ignored; acceptance is CE-gated.
abort=1;step;if(!start_ready)$fatal(1,"idle abort");abort=0;
ce=0;start_valid=1;repeat(3)step;if(!start_ready)$fatal(1,"CE start");start_valid=0;ce=1;
launch;feed(0);while(!done_valid)step;abort=1;step;
if(!done_valid||done_error)$fatal(1,"DONE abort");abort=0;ack;
$display("PASS protocol recovery=%d",good);$finish;
end
initial begin #2000000;$fatal(1,"timeout state %d",dut.state);end
endmodule'''
def main():
 frozen=hashes()
 with tempfile.TemporaryDirectory(prefix='bmp_encode_protocol_') as tmp:
  d=Path(tmp);(d/'tb.sv').write_text(TB);execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],HERE,d/'compile.log')
  out=execute(['vvp',d/'a.vvp'],HERE,d/'sim.log');assert 'PASS protocol' in out;print(out.strip())
 assert hashes()==frozen
 (HERE/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,active_abort_states=6,ce_off_resets=6,marker_errors=6,healthy_recovery_frames=19,last_byte_stall=True,abort_idle_done_ignored=True),indent=2)+'\n')
if __name__=='__main__':main()
