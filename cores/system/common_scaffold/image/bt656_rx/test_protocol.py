from run_tests import *
PRO=r'''module tb;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,abort=0,s_valid=0,s_last=0,m_ready=1,done_ready=0;reg[15:0]cfg_width=4,cfg_field_lines=3;reg[7:0]s_data=0;
wire start_ready,s_ready,m_valid,m_sof,m_eol,m_last,m_field,m_field_sof,done_valid,frame_error;wire[7:0]m_data,error_code;
bt656_rx dut(.*);reg[7:0]src[0:NB-1],exp[0:47];integer i,j,k,got=0,cycles=0;
reg checking=0;
always @(posedge clk)begin cycles=cycles+1;if(cycles>100000)$fatal(1,"timeout");if(rst_n&&ce&&m_valid&&m_ready)begin if(checking)begin if(m_data!==exp[got])$fatal(1,"recovery byte");end got=got+1;end end
task tick;begin @(negedge clk);#1;end endtask
task start;begin start_valid=1;@(posedge clk);tick;start_valid=0;end endtask
task put;input[7:0]x;begin s_data=x;s_valid=1;begin:waiter reg ok;ok=0;while(!ok&&!done_valid)begin @(posedge clk);ok=ce&&s_ready;end end tick;s_valid=0;end endtask
task ack;begin done_ready=1;@(posedge clk);tick;done_ready=0;if(done_valid||!start_ready)$fatal(1,"ack");end endtask
task healthy;begin got=0;checking=1;start;cfg_width=2;cfg_field_lines=1;for(i=0;i<NB;i=i+1)begin s_last=i==NB-1;put(src[i]);end s_last=0;while(!done_valid)tick;if(error_code||got!=48)$fatal(1,"recovery");checking=0;ack;cfg_width=4;cfg_field_lines=3;end endtask
initial begin $readmemh("SRC",src);$readmemh("EXP",exp);repeat(3)tick;rst_n=1;tick;
for(j=0;j<16;j=j+1)begin start;for(k=0;k<108+j;k=k+1)put(src[k]);ce=0;abort=1;repeat(3)tick;if(done_valid)$fatal(1,"abort CE");ce=1;@(posedge clk);tick;abort=0;if(!done_valid||error_code!=7)$fatal(1,"abort");ack;healthy;end
// Reset works even with CE low, releasing all pending output/session state.
start;for(k=0;k<115;k=k+1)put(src[k]);ce=0;rst_n=0;@(posedge clk);tick;if(done_valid||m_valid||!start_ready)$fatal(1,"reset");rst_n=1;ce=1;healthy;
// Explicit malformed EAV, field order and truncation with healthy recovery.
start;for(k=0;k<120;k=k+1)put(src[k]);put(0);if(!done_valid||error_code!=5)$fatal(1,"EAV");ack;healthy;
start;for(k=0;k<111;k=k+1)put(src[k]);put(8'hc7);if(!done_valid||error_code!=3)$fatal(1,"field");ack;healthy;
start;for(k=0;k<114;k=k+1)put(src[k]);s_last=1;put(src[114]);s_last=0;if(!done_valid||error_code!=4)$fatal(1,"truncation");ack;healthy;
// Parity error followed by new healthy session.
start;put(255);put(0);put(0);put(8'h81);if(!done_valid||error_code!=2)$fatal(1,"parity error");ack;healthy;
$display("PASS BT656 protocol 21 recoveries 16 aborts CEoff reset");$finish;end
endmodule'''
def main():
 data,pix=fixture(4,3)
 with tempfile.TemporaryDirectory(prefix='bt656_protocol_') as td:
  d=Path(td);tb=PRO.replace('NB',str(len(data)))
  for key,seq in [('SRC',data),('EXP',pix)]:
   p=d/(key+'.hex');p.write_text('\n'.join(f'{x:x}' for x in seq)+'\n');tb=tb.replace('"'+key+'"','"'+p.as_posix()+'"')
  (d/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],ROOT,H/'protocol_compile.log');out=execute(['vvp',d/'a.vvp'],ROOT,H/'protocol_simulation.log');assert 'PASS BT656' in out
 (H/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),recoveries=21,aborts=16,ce_off_reset=1),indent=2)+'\n');print(out)
if __name__=='__main__':main()

