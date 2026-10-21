from run_tests import HERE,RTL,execute
from pathlib import Path
import tempfile,hashlib,json
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,abort=0;wire start_ready;
reg[15:0]cfg_width=2,cfg_field_lines=1,cfg_total_lines=4,cfg_field1_start=2,cfg_active0_start=1,cfg_active1_start=3;
reg[16:0]cfg_line_bytes=16;reg[7:0]s_data=0;reg s_valid=0,s_sof=0,s_eol=0,s_last=0,s_field=0;wire s_ready;
wire[7:0]m_data,error_code;wire m_valid,m_sof,m_eol,m_last,done_valid,frame_error;reg m_ready=1,done_ready=0;wire[63:0]output_bytes;
bt656_tx dut(.*);
integer j,k,t,tests=0,i;
task config_good;
begin cfg_width=2;cfg_field_lines=1;cfg_total_lines=4;cfg_field1_start=2;cfg_active0_start=1;cfg_active1_start=3;cfg_line_bytes=16;end endtask
task launch;begin @(negedge clk);start_valid=1;@(negedge clk);start_valid=0;end endtask
task report;
input[7:0]code;
begin if(!done_valid||error_code!==code||frame_error!==(code!=0))$fatal(1,"report expected %d got %d",code,error_code);
repeat(3)@(negedge clk);done_ready=1;@(negedge clk);done_ready=0;tests=tests+1;end endtask
task healthy;
begin config_good;m_ready=1;launch;i=0;
while(!done_valid)begin
s_valid=i<8;s_sof=i==0;s_eol=i%4==3;s_last=i==7;s_field=i>=4;s_data=i*19;
@(posedge clk);if(ce&&s_ready&&s_valid)i=i+1;@(negedge clk);
end
s_valid=0;if(output_bytes!=64||i!=8)$fatal(1,"healthy count");report(0);
end endtask
task reach;
input integer target;
begin config_good;launch;s_valid=0;m_ready=1;
while(dut.state!=target)begin
if(dut.state==2)begin s_valid=1;s_sof=1;s_eol=0;s_last=0;s_field=0;end
@(negedge clk);
end
s_valid=0;m_ready=0;end endtask
initial begin
repeat(3)@(negedge clk);rst_n=1;
for(j=1;j<=3;j=j+1)begin
reach(j);ce=0;abort=1;repeat(3)begin @(negedge clk);if(dut.state!=j)$fatal(1,"CE freeze");end
ce=1;@(negedge clk);abort=0;report(3);healthy;
reach(j);ce=0;rst_n=0;@(negedge clk);if(!start_ready||done_valid||m_valid||output_bytes)$fatal(1,"reset");rst_n=1;ce=1;healthy;
end
// Invalid descriptor classes, each followed by an exact healthy transfer.
for(k=0;k<12;k=k+1)begin
config_good;
case(k)
0:cfg_width=0;1:cfg_width=3;2:cfg_width=722;
3:cfg_field_lines=0;4:cfg_field_lines=289;
5:cfg_line_bytes=10;6:cfg_line_bytes=17;
7:cfg_total_lines=1;8:cfg_field1_start=0;9:cfg_field1_start=4;
10:cfg_active0_start=2;11:cfg_active1_start=2;
endcase
// case11 overlaps own field range? 2+1<=4 is valid, use end overflow instead.
if(k==11)cfg_active1_start=4;
launch;report(1);healthy;
end
// All four input marker errors at first payload, no offending byte output.
for(k=0;k<4;k=k+1)begin
config_good;launch;m_ready=1;wait(s_ready);@(negedge clk);
s_valid=1;s_sof=k!=0;s_eol=k==1;s_last=k==2;s_field=k==3;
@(negedge clk);s_valid=0;report(2);healthy;
end
// Last-byte missing last marker.
config_good;launch;i=0;
while(!done_valid)begin
s_valid=i<8;s_sof=i==0;s_eol=i%4==3;s_last=0;s_field=i>=4;
@(posedge clk);if(s_valid&&s_ready)i=i+1;@(negedge clk);
end
s_valid=0;report(2);healthy;
// No input: remain waiting with no padding or deadline.
config_good;launch;wait(s_ready);@(negedge clk);
repeat(99)begin @(negedge clk);if(done_valid||!s_ready||m_valid)$fatal(1,"starvation");end
abort=1;@(negedge clk);abort=0;report(3);healthy;
// Terminal ignores abort; synchronous reset priority to CE at DONE.
config_good;cfg_width=0;launch;abort=1;repeat(3)@(negedge clk);if(error_code!=1)$fatal(1,"DONE changed");abort=0;ce=0;rst_n=0;@(negedge clk);if(!start_ready)$fatal(1,"DONE reset");rst_n=1;ce=1;healthy;
$display("PASS BT656 TX protocol reports=%0d",tests);$finish;
end
initial begin #1000000;$fatal(1,"timeout state %d",dut.state);end
endmodule'''
def main():
 with tempfile.TemporaryDirectory(prefix='bt656_tx_protocol_') as t:
  d=Path(t);(d/'tb.sv').write_text(TB)
  execute(['iverilog','-g2012','-s','tb','-o',d/'sim',RTL,d/'tb.sv'],d,HERE/'protocol_compile.log')
  out=execute(['vvp',d/'sim'],d,HERE/'protocol_simulation.log');assert 'PASS' in out;print(out)
 (HERE/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',source_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),scope='3 active states abort/CEoffreset; 12 invalid cfg; 5 marker faults; starvation; DONE reset/abort; healthy recovery'),indent=2)+'\n')
if __name__=='__main__':main()
