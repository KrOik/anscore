from run_tests import *
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,cfg_big_endian=0,abort=0;reg[1:0]cfg_mode=0;reg[31:0]s_pixel=32'hfedcba98;
reg s_valid=0,s_sof=0,s_eol=0,s_last=0,m_ready=1,done_ready=0;
wire start_ready,s_ready,m_valid,m_sof,m_last,done_valid,frame_error;wire[7:0]m_data,error_code;wire[31:0]output_bytes;
tiff_encoder #(.WIDTH(3),.HEIGHT(2),.ROWS_PER_STRIP(1))dut(.*);
integer i,j,good=0,bad=0,cycles=0;
always @(posedge clk)begin cycles=cycles+1;if(cycles>100000)$fatal(1,"timeout");end
task tick;begin @(negedge clk);#1;end endtask
task launch;input[1:0]mode;begin tick;cfg_mode=mode;start_valid=1;tick;start_valid=0;end endtask
task ack;input[7:0]err;begin wait(done_valid);tick;if(error_code!==err||frame_error!==(err!=0))$fatal(1,"error %d wanted %d",error_code,err);repeat(3)tick;if(!done_valid)$fatal(1,"done held");done_ready=1;tick;done_ready=0;if(!start_ready)$fatal(1,"ack");end endtask
task healthy;begin launch(2);for(i=0;i<6;i=i+1)begin wait(s_ready);tick;s_valid=1;s_sof=i==0;s_eol=i%3==2;s_last=i==5;tick;s_valid=0;end ack(0);if(output_bytes!=186)$fatal(1,"bytecount");good=good+1;end endtask
initial begin repeat(3)tick;rst_n=1;healthy;
launch(3);ack(2);bad=bad+1;healthy;
for(j=0;j<6;j=j+1)begin launch(0);wait(s_ready);tick;s_valid=1;s_sof=j!=0;s_eol=j==1;s_last=j==2;
if(j>=3)begin s_sof=1;s_eol=0;s_last=0;end
tick;s_valid=0;
if(j>=3)begin for(i=1;i<6;i=i+1)begin wait(s_ready);tick;s_valid=1;s_sof=0;s_eol=i%3==2;s_last=i==5;if(j==3&&i==1)s_sof=1;if(j==4&&i==2)s_eol=0;if(j==5&&i==5)s_last=0;tick;s_valid=0;if(done_valid)i=6;end end
ack(4);bad=bad+1;healthy;end
for(j=0;j<7;j=j+1)begin launch(2);
if(j==0)begin repeat(5)tick;end else begin wait(s_ready);tick;if(j>=2)begin m_ready=0;s_valid=1;s_sof=1;s_eol=0;s_last=0;tick;s_valid=0;if(j>=3)begin m_ready=1;repeat(j==3?1:2)tick;m_ready=0;end end end
abort=1;tick;abort=0;m_ready=1;ack(3);bad=bad+1;healthy;end
for(j=0;j<3;j=j+1)begin launch(2);if(j>0)wait(s_ready);tick;if(j==2)begin s_valid=1;s_sof=1;s_eol=0;s_last=0;m_ready=0;tick;s_valid=0;end ce=0;rst_n=0;tick;if(!start_ready||done_valid||m_valid)$fatal(1,"reset");rst_n=1;ce=1;m_ready=1;healthy;end
$display("PASS recovery=%d errors=%d",good,bad);$finish;end endmodule'''
def main():
 frozen=hashes()
 with tempfile.TemporaryDirectory(prefix='tiff_protocol_') as tmp:
  d=Path(tmp);(d/'tb.sv').write_text(TB);execute(['iverilog','-g2012','-s','tb','-o',d/'sim',RTL,d/'tb.sv'],d,d/'compile.log');out=execute(['vvp',d/'sim'],d,d/'run.log');print(out)
 assert hashes()==frozen
 (HERE/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,output=out),indent=2)+'\n')
if __name__=='__main__':main()
