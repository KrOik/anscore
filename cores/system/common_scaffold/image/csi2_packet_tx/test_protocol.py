from run_tests import HERE,RTL,execute
from pathlib import Path
import hashlib,json,tempfile
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,abort=0;reg[1:0]cfg_vc=0;reg[5:0]cfg_dt=42;reg[15:0]cfg_word_count=2;
reg[7:0]s_data=81;reg s_valid=0,s_last=0,m_ready=1,done_ready=0;
wire start_ready,s_ready,m_valid,m_sof,m_last,done_valid,done_error,busy;wire[7:0]m_data,error_code;wire[31:0]output_bytes;
csi2_packet_tx dut(.*);
integer j,k,tests=0;
task launch;
begin @(negedge clk);start_valid=1;@(negedge clk);start_valid=0;end endtask
task finish_report;
input[7:0]code;
begin
if(!done_valid||done_error!==(code!=0)||error_code!==code)$fatal(1,"report expected %d state %d code %d",code,dut.state,error_code);
repeat(4)@(negedge clk);
done_ready=1;@(negedge clk);done_ready=0;tests=tests+1;
end endtask
task healthy;
begin
cfg_dt=8;cfg_word_count=65535;m_ready=1;launch;
wait(done_valid);@(negedge clk);if(output_bytes!=4)$fatal(1,"short count");finish_report(0);cfg_dt=42;cfg_word_count=2;
end endtask
task reach;
input integer target;
begin
cfg_dt=42;cfg_word_count=2;m_ready=1;s_valid=0;s_last=0;launch;
if(target==1)begin m_ready=0;end
while(dut.state!=target)begin
if(dut.state==2)begin s_valid=1;s_last=dut.remaining==1;end
@(negedge clk);
end
s_valid=0;m_ready=0;
end endtask
initial begin
repeat(3)@(negedge clk);rst_n=1;
// Every active state, reset and abort while stalled. CE-off reset priority.
for(j=1;j<=5;j=j+1)begin
reach(j);ce=0;abort=1;
repeat(4)begin @(negedge clk);if(dut.state!=j)$fatal(1,"CE changed state");end
ce=1;@(negedge clk);abort=0;finish_report(3);healthy;
reach(j);ce=0;rst_n=0;@(negedge clk);
if(!start_ready||busy||m_valid||done_valid||output_bytes!=0)$fatal(1,"reset failed");
rst_n=1;ce=1;healthy;
end
// Early marker rejects first payload before output.
cfg_dt=42;cfg_word_count=2;m_ready=1;launch;wait(s_ready);@(negedge clk);s_valid=1;s_last=1;@(negedge clk);s_valid=0;
if(output_bytes!=4)$fatal(1,"early marker output");finish_report(2);healthy;
// Missing final marker rejects final payload; no padding or CRC.
cfg_dt=42;cfg_word_count=1;launch;wait(s_ready);@(negedge clk);s_valid=1;s_last=0;@(negedge clk);s_valid=0;finish_report(2);healthy;
// Missing input remains waiting, no invented bytes or timeout.
cfg_dt=42;cfg_word_count=1;launch;wait(s_ready);@(negedge clk);
repeat(100)begin @(negedge clk);if(!s_ready||m_valid||done_valid||output_bytes!=4)$fatal(1,"input starvation");end
abort=1;@(negedge clk);abort=0;finish_report(3);healthy;
// Idle abort harmless, held DONE ignores abort, reset at DONE CE-off.
abort=1;@(negedge clk);abort=0;if(!start_ready)$fatal(1,"idle abort");
cfg_dt=4;launch;finish_report(1);healthy;
cfg_dt=0;launch;wait(done_valid);@(negedge clk);abort=1;repeat(3)@(negedge clk);if(done_error)$fatal(1,"DONE abort changed");abort=0;ce=0;rst_n=0;@(negedge clk);if(!start_ready)$fatal(1,"DONE reset");rst_n=1;ce=1;healthy;
$display("PASS CSI2 TX protocol reports=%0d",tests);$finish;
end
initial begin #1000000;$fatal(1,"timeout state %d",dut.state);end
endmodule'''
def main():
 with tempfile.TemporaryDirectory(prefix='csi2_tx_protocol_') as t:
  d=Path(t);(d/'tb.sv').write_text(TB)
  execute(['iverilog','-g2012','-s','tb','-o',d/'sim',RTL,d/'tb.sv'],d,HERE/'protocol_compile.log')
  out=execute(['vvp',d/'sim'],d,HERE/'protocol_simulation.log');assert 'PASS' in out;print(out)
 (HERE/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',source_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),scope='Abort and CE-off reset all five active states, DONE reset/abort, missing-input wait, early/missing s_last, recovery'),indent=2)+'\n')
if __name__=='__main__':main()
