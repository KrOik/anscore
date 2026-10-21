from run_tests import *
COMMON=r'''module tb;
localparam DIR=@DIR@;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,abort=0;reg[15:0]cfg_width=3,cfg_height=2;
reg[23:0]ip=24'h123456;reg iv=0,isof=0,ieol=0,ilast=0,orr=1,done_ready=0;
wire start_ready,ir,ov,os,oe,ol,done_valid,frame_error;wire[7:0]error_code;wire[23:0]op;
@DUT@
integer i,j,cyc=0,good=0,errors=0,outcount=0;
always @(posedge clk)begin cyc=cyc+1;if(cyc>100000)$fatal(1,"timeout");if(ov&&orr&&(DIR==0||ce))outcount=outcount+1;end
task tick;begin @(negedge clk);#1;end endtask
task launch;begin tick;cfg_width=3;cfg_height=2;start_valid=1;tick;start_valid=0;end endtask
task send;input integer n;input integer fault;reg take;begin
ip=24'h123400+n;iv=1;isof=n==0;ieol=n%3==2;ilast=n==5;
if(fault==1)isof=!isof;if(fault==2)ieol=!ieol;if(fault==3)ilast=!ilast;
do begin @(posedge clk);take=ir&&(DIR==1||ce);tick;end while(!take);iv=0;end endtask
task ack;input[7:0]error_;begin while(!done_valid)tick;if(frame_error!==(error_!=0)||error_code!==error_)$fatal(1,"error %d wanted %d",error_code,error_);
ce=0;done_ready=1;repeat(3)tick;if(!done_valid)$fatal(1,"done CEhold");ce=1;tick;done_ready=0;if(!start_ready)$fatal(1,"doneack");end endtask
task healthy;begin launch;outcount=0;for(i=0;i<6;i=i+1)send(i,0);ack(0);if(outcount!=6)$fatal(1,"healthy count %d",outcount);good=good+1;end endtask
initial begin repeat(3)tick;rst_n=1;healthy;
// Both early and missing SOF/EOL; encoder additionally checks frame-LAST.
for(j=0;j<(DIR==0?6:4);j=j+1)begin launch;
if(j==0)send(0,1);
if(j==1)begin send(0,0);send(1,1);end
if(j==2)send(0,2);
if(j==3)begin send(0,0);send(1,0);send(2,2);end
if(j==4)send(0,3);
if(j==5)begin for(i=0;i<5;i=i+1)send(i,0);send(5,3);end
ack(2);errors=errors+1;healthy;end
// Invalid runtime dimensions, no silent synchronization or dropped error.
for(j=0;j<4;j=j+1)begin tick;cfg_width=j==0?0:j==1?4:3;cfg_height=j==2?0:j==3?3:2;start_valid=1;tick;start_valid=0;ack(1);errors=errors+1;healthy;end
// Abort in RUN without data, then abort while an output is already exposed.
launch;abort=1;tick;abort=0;ack(3);errors=errors+1;healthy;
launch;orr=0;send(0,0);while(!ov)tick;abort=1;tick;abort=0;
if(!ov||op!=24'h123400||done_valid)$fatal(1,"abort dropped exposed item");
ce=0;orr=1;repeat(3)tick;
if(DIR==0&&ov)$fatal(1,"AXI CEoff did not drain");if(DIR==1&&!ov)$fatal(1,"pixel CEoff drained");
if(done_valid)$fatal(1,"status CEoff advanced");ce=1;ack(3);errors=errors+1;healthy;
// CE-off input capture is real for AXI, blocked for internal pixel.
launch;ce=0;ip=24'habcd01;iv=1;isof=1;ieol=0;ilast=0;tick;iv=0;
if(DIR==1&&ir)$fatal(1,"AXI did not buffer CEoff transfer");if(DIR==0&&ov)$fatal(1,"pixel accepted CEoff transfer");
abort=1;ce=1;tick;abort=0;ack(3);healthy;
// Reset must recover even ce=0, with output stalled.
launch;orr=0;send(0,0);while(!ov)tick;ce=0;rst_n=0;tick;if(!start_ready||ov||done_valid)$fatal(1,"reset");rst_n=1;ce=1;orr=1;healthy;
$display("PASS dir=%d healthy=%d errors=%d",DIR,good,errors);$finish;end endmodule'''
E='''video_stream_to_axis #(.WIDTH(3),.HEIGHT(2)) dut(.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start_valid),.start_ready(start_ready),.cfg_width(cfg_width),.cfg_height(cfg_height),.abort(abort),.s_pixel(ip),.s_valid(iv),.s_ready(ir),.s_sof(isof),.s_eol(ieol),.s_last(ilast),.m_axis_tdata(op),.m_axis_tvalid(ov),.m_axis_tready(orr),.m_axis_tuser(os),.m_axis_tlast(oe),.done_valid(done_valid),.done_ready(done_ready),.frame_error(frame_error),.error_code(error_code));assign ol=0;'''
D='''axis_to_video_stream #(.WIDTH(3),.HEIGHT(2)) dut(.clk(clk),.rst_n(rst_n),.ce(ce),.start_valid(start_valid),.start_ready(start_ready),.cfg_width(cfg_width),.cfg_height(cfg_height),.abort(abort),.s_axis_tdata(ip),.s_axis_tvalid(iv),.s_axis_tready(ir),.s_axis_tuser(isof),.s_axis_tlast(ieol),.m_pixel(op),.m_valid(ov),.m_ready(orr),.m_sof(os),.m_eol(oe),.m_last(ol),.done_valid(done_valid),.done_ready(done_ready),.frame_error(frame_error),.error_code(error_code));'''
def main():
 frozen=hashes();rows=[]
 for direction,dut in enumerate([E,D]):
  with tempfile.TemporaryDirectory(prefix='axi_video_protocol_') as tmp:
   p=Path(tmp);(p/'tb.sv').write_text(COMMON.replace('@DIR@',str(direction)).replace('@DUT@',dut));execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,p/'tb.sv'],p,p/'compile.log');out=execute(['vvp',p/'sim'],p,p/'run.log');print(out);rows.append(dict(direction=direction,output=out))
 assert hashes()==frozen
 (HERE/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,cases=rows),indent=2)+'\n')
def run_isolated(direction):
 frozen=hashes();dut=[E,D][direction]
 tb=COMMON[:COMMON.index('initial begin repeat')]+r'''
integer seen=0;
always @(posedge clk)if(rst_n&&ov&&orr&&(DIR==0||ce))begin
if(op!==24'h123400+(seen%6)||os!==(seen%6==0)||oe!==(seen%3==2))$fatal(1,"isolated oracle");
if(DIR==1&&ol!==(seen%6==5))$fatal(1,"isolated LAST");seen=seen+1;end
initial begin repeat(3)tick;rst_n=1;healthy;healthy;if(seen!=12)$fatal(1,"isolated count");$display("PASS isolated dir=%d pixels=%d",DIR,seen);$finish;end endmodule'''
 with tempfile.TemporaryDirectory(prefix='axi_video_isolated_') as tmp:
  p=Path(tmp);(p/'tb.sv').write_text(tb.replace('@DIR@',str(direction)).replace('@DUT@',dut));execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,p/'tb.sv'],p,p/'compile.log');out=execute(['vvp',p/'sim'],p,p/'run.log');print(out)
 assert hashes()==frozen
 (HERE/('to_axis_evidence.json' if direction==0 else 'from_axis_evidence.json')).write_text(json.dumps(dict(status='PASS',sources=frozen,direction=direction,pixels=12,output=out),indent=2)+'\n')
if __name__=='__main__':main()
