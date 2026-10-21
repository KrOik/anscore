"""Directed same-tick terminal-fault regression found by independent peer review."""
from test_timing import *
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,pixel_tick=1,start_valid=0,stop=0,abort=0,done_ready=0;
reg[15:0]cfg_h_active=1,cfg_h_front=0,cfg_h_sync=1,cfg_h_back=0,cfg_v_active=1,cfg_v_front=0,cfg_v_sync=1,cfg_v_back=0;
reg cfg_hsync_positive=0,cfg_vsync_positive=1;reg[23:0]s_pixel=24'h123456;reg s_valid=0,s_sof=1,s_eol=1,s_last=1;
wire start_ready,s_ready,running,done_valid,frame_error,hsync,vsync,de,sof,eol,eof,frame_end;wire[7:0]error_code;wire[15:0]h_count,v_count;wire[23:0]rgb;
video_rgb_scanout #(.FIFO_DEPTH(2),.PREBUFFER(1))dut(.*);
integer c,ticks=0,frames=0,checks=0,cyc=0;reg take;
always @(posedge clk)begin cyc=cyc+1;if(cyc>10000)$fatal(1,"timeout");
if(rst_n&&running&&pixel_tick)begin ticks=ticks+1;if(frame_end)frames=frames+1;
// Positive sync lengths put the final physical frame tick in blanking.
if(frame_end&&de)$fatal(1,"underflow at frame_end must be unreachable");
if(frame_error&&de&&rgb!==0)$fatal(1,"fault output black");end end
task tick;begin @(negedge clk);#1;end endtask
task launch;begin tick;ticks=0;frames=0;ce=1;stop=0;abort=0;s_valid=0;s_sof=1;start_valid=1;tick;start_valid=0;
s_valid=1;do begin @(posedge clk);take=ce&&s_ready;tick;end while(!take);s_valid=0;while(!running)tick;end endtask
task report;input[7:0]err;input integer n;begin while(!done_valid)tick;
if(error_code!==err||frame_error!==(err!=0)||ticks!=n*4||frames!=n||running)$fatal(1,"case%0d goterr%0d ticks%0d frames%0d wantederr%0d frames%0d",c,error_code,ticks,frames,err,n);
ce=1;done_ready=1;tick;done_ready=0;if(!start_ready)$fatal(1,"ready");checks=checks+1;end endtask
initial begin repeat(3)tick;rst_n=1;
for(c=0;c<5;c=c+1)begin launch;while(!frame_end)tick;
// Signals are driven before the edge sampling the final timing tick.
if(c<3)begin if(!s_ready)$fatal(1,"bad future pixel not accepted");s_valid=1;s_sof=0;end
stop=c==1||c==3;abort=c==2||c==4;tick;s_valid=0;stop=0;abort=0;
report(c==2||c==4?3:c==3?0:2,1);end
for(c=5;c<9;c=c+1)begin launch;while(!(frames==1&&de))tick;
if(c==6)begin s_valid=1;s_sof=0;end
if(c==7)abort=1;if(c==8)stop=1;
tick;s_valid=0;abort=0;stop=0;report(c==7?3:4,2);end
// CE=0 rejects internal marker/stop/abort inputs but cannot pause timing.
c=9;launch;while(!frame_end)tick;ce=0;s_valid=1;s_sof=0;stop=1;abort=1;tick;s_valid=0;stop=0;abort=0;report(4,2);
$display("PASS FAULT_BOUNDARIES checks=%0d marker-finaltick stops1frame; underflow at frame_end unreachable; priority abort>underflow>marker>stop; CEoff tick live",checks);$finish;end endmodule'''
def main():
 frozen=hashes()
 with tempfile.TemporaryDirectory(prefix='scanout_fault_boundary_') as tmp:
  p=Path(tmp);(p/'tb.sv').write_text(TB);execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,p/'tb.sv'],p,p/'compile.log');out=execute(['vvp',p/'sim'],p,p/'run.log');print(out)
 assert hashes()==frozen
 (HERE/'fault_boundary_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,checks=10,output=out),indent=2)+'\n')
if __name__=='__main__':main()
