from run_tests import *
TB=r"""module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0,abort=0,s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=0,done_ready=0;reg[1:0]cfg_order=0;reg[SW-1:0]s_data=0;
wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,done_valid,done_error,busy;wire[7:0]error_code;wire[MW-1:0]m_data;
NAME #(.WIDTH(2),.HEIGHT(1))dut(.*);
integer i,j,errors=0;
task tick;begin @(negedge clk);#1;end endtask
task launch;begin start_valid=1;tick;start_valid=0;if(!busy)$fatal(1,"start");end endtask
task ack;begin if(!done_valid||!done_error)$fatal(1,"missing error");repeat(3)tick;if(!done_valid)$fatal(1,"hold done");done_ready=1;tick;done_ready=0;if(!start_ready)$fatal(1,"recover");errors=errors+1;end endtask
task send;input integer n;input integer bad;begin
s_valid=1;s_sof=n==0;s_eol=n==NI-1;s_last=n==NI-1;
case(bad)1:s_sof=!s_sof;2:s_eol=!s_eol;3:s_last=!s_last;endcase
tick;s_valid=0;end endtask
initial begin repeat(2)tick;rst_n=1;tick;
// Abort every input-byte phase, plus output held state; then verify ready recovery.
for(i=0;i<=NI;i=i+1)begin launch;for(j=0;j<i;j=j+1)send(j,0);abort=1;tick;abort=0;if(error_code!=2)$fatal(1,"abort code");ack;end
for(i=0;i<NI;i=i+1)for(j=1;j<=3;j=j+1)begin launch;begin : feeds integer k;for(k=0;k<i;k=k+1)send(k,0);end send(i,j);if(error_code!=3)$fatal(1,"marker code");ack;end
// Reset must work with CE low, including held output and active partial words.
for(i=0;i<=NI;i=i+1)begin launch;for(j=0;j<i;j=j+1)send(j,0);ce=0;rst_n=0;tick;if(busy||done_valid||m_valid)$fatal(1,"CE reset");rst_n=1;ce=1;tick;end
// Healthy full frames after every failure family; CE freezes ready handshakes.
launch;ce=0;repeat(3)tick;if(!busy)$fatal(1,"ce");ce=1;for(i=0;i<NI;i=i+1)send(i,0);
if(!m_valid)$fatal(1,"output");repeat(3)tick;m_ready=1;
repeat(NO)tick;m_ready=0;if(!done_valid||done_error)$fatal(1,"healthy");$display("PASS PROTOCOL %d",errors);$finish;end endmodule"""
def main():
 before=hashes();rows=[]
 for pack in [True,False]:
  name='yuv422_byte_'+('packer' if pack else 'unpacker')
  with tempfile.TemporaryDirectory(prefix='yuv422_protocol_') as tmp:
   d=Path(tmp);tb=TB
   for k,v in dict(NAME=name,SW=32 if pack else 8,MW=8 if pack else 32,NI=1 if pack else 4,NO=4 if pack else 1).items():tb=tb.replace(k,str(v))
   (d/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',d/'a',*RTLS,d/'tb.sv'],HERE,d/'compile');out=execute(['vvp',d/'a'],HERE,d/'sim');assert 'PASS PROTOCOL' in out;rows.append(dict(module=name,result=out.strip()))
 assert hashes()==before;(HERE/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',sources=before,cases=rows),indent=2)+'\n');print('PASS YUV protocol')
if __name__=='__main__':main()
