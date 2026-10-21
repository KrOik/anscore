from test_timing import *
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,pixel_tick=0,start_valid=0,stop=0,abort=0,done_ready=0;
reg[15:0]cfg_h_active=4,cfg_h_front=2,cfg_h_sync=1,cfg_h_back=1,cfg_v_active=2,cfg_v_front=1,cfg_v_sync=1,cfg_v_back=1;
reg cfg_hsync_positive=0,cfg_vsync_positive=1;reg[23:0]s_pixel;reg s_valid=0,s_sof=0,s_eol=0,s_last=0;
wire start_ready,s_ready,running,done_valid,frame_error,hsync,vsync,de,sof,eol,eof,frame_end;wire[7:0]error_code;wire[15:0]h_count,v_count;wire[23:0]rgb;
video_rgb_scanout #(.FIFO_DEPTH(3),.PREBUFFER(2))dut(.*);
integer cyc=0,i,j,frames=0,active=0,ticks=0,good=0,bad=0;reg checkblack=0,healthycheck=0;
always @(negedge clk)begin cyc=cyc+1;pixel_tick=cyc%4==0;if(cyc>100000)$fatal(1,"timeout state%d",dut.state);end
always @(posedge clk)if(rst_n&&running&&pixel_tick)begin
ticks=ticks+1;if(frame_end)frames=frames+1;
if(de)begin if(checkblack&&frame_error&&rgb!==0)$fatal(1,"error output not black");if(healthycheck&&rgb!==24'h010000+active)$fatal(1,"healthy pixel %d got%h",active,rgb);active=active+1;end end
task tick;begin @(negedge clk);#1;end endtask
task launch;begin tick;cfg_h_active=4;cfg_v_active=2;start_valid=1;ce=1;frames=0;active=0;ticks=0;tick;start_valid=0;end endtask
task send;input integer n;input fault;reg take;begin s_valid=1;s_pixel=24'h010000+n;s_sof=n==0;s_eol=n%4==3;s_last=n==7;if(fault)s_sof=!s_sof;
do begin @(posedge clk);take=ce&&s_ready;tick;end while(!take);s_valid=0;end endtask
task ack;input[7:0]err;begin while(!done_valid)tick;$display("report actual %d wanted %d",error_code,err);if(frame_error!==(err!=0)||error_code!==err)$fatal(1,"error %d wanted %d",error_code,err);
ce=0;done_ready=1;repeat(4)tick;if(!done_valid)$fatal(1,"donehold");ce=1;tick;done_ready=0;if(!start_ready)$fatal(1,"ready");end endtask
task healthy;begin healthycheck=1;checkblack=0;launch;for(i=0;i<8;i=i+1)send(i,0);stop=1;tick;stop=0;ack(0);if(frames!=1||active!=8||ticks!=40)$fatal(1,"healthy frame");good=good+1;healthycheck=0;end endtask
initial begin repeat(3)tick;rst_n=1;healthy;
// Prebuffer waits; internal CE-off transfers must never be accepted.
launch;ce=0;s_valid=1;s_sof=1;s_eol=0;s_last=0;s_pixel=1;repeat(6)tick;s_valid=0;if(dut.count||dut.qvalid||running)$fatal(1,"CEoff input");ce=1;
send(0,0);repeat(6)tick;if(running)$fatal(1,"prebuffer threshold");stop=1;tick;stop=0;ack(0);healthy;
// Wrong SOF before launch is an explicit immediate error with no timing emitted.
launch;send(0,1);ack(2);if(ticks!=0)$fatal(1,"bad prefill started timing");bad=bad+1;healthy;
// Threshold and malformed third input coincide: no orphan timing may launch.
launch;send(0,0);send(1,0);send(2,1);ack(2);repeat(8)tick;if(running||ticks!=0)$fatal(1,"fault raced launch");bad=bad+1;healthy;
// Underflow: physical timing continues and outputs black until frame boundary.
launch;checkblack=1;send(0,0);send(1,0);wait(running);while(!frame_error)tick;ce=0;ack(4);if(frames!=1||ticks!=40||active!=8)$fatal(1,"underflow timing shortened");bad=bad+1;healthy;
// Malformed input while running. Error remains sticky through later abort.
launch;checkblack=1;send(0,0);send(1,0);wait(running);send(2,1);abort=1;tick;abort=0;ack(2);bad=bad+1;healthy;
// Abort in prefill discards pending entries; active abort stops only at frame end.
launch;send(0,0);abort=1;tick;abort=0;ack(3);bad=bad+1;healthy;
launch;checkblack=1;send(0,0);send(1,0);wait(running);tick;abort=1;tick;abort=0;ce=0;ack(3);if(frames!=1||ticks!=40)$fatal(1,"abort frame boundary");bad=bad+1;healthy;
// Physical timing and sync must not freeze while CE=0; reset does override CE.
for(j=0;j<2;j=j+1)begin launch;send(0,0);if(j==1)begin send(1,0);wait(running);end tick;ce=0;rst_n=0;tick;if(!start_ready||running||done_valid||de)$fatal(1,"reset");rst_n=1;ce=1;healthy;end
// Runtime dimensions / timing arithmetic rejects zeros and overflow.
for(j=0;j<4;j=j+1)begin tick;cfg_h_active=j==0?0:4;cfg_v_active=2;cfg_h_sync=j==1?0:1;cfg_h_front=j==2?65535:2;cfg_v_back=j==3?65535:1;start_valid=1;tick;start_valid=0;ack(1);cfg_h_sync=1;cfg_h_front=2;cfg_v_back=1;bad=bad+1;healthy;end
$display("PASS SCANOUT_PROTOCOL healthy=%d errors=%d",good,bad);$finish;end endmodule'''
def main():
 frozen=hashes()
 with tempfile.TemporaryDirectory(prefix='scanout_protocol_') as tmp:
  p=Path(tmp);(p/'tb.sv').write_text(TB);execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,p/'tb.sv'],p,p/'compile.log');out=execute(['vvp',p/'sim'],p,p/'run.log');print(out)
 from test_scanout import TB as chain_tb
 boundary=chain_tb.replace('@W@','4').replace('@H@','2').replace('for(i=0;i<2*N;i=i+1)','for(i=0;i<N;i=i+1)').replace('if(got>N&&!requested)','if(got==N&&frame_end&&pixel_tick&&!requested)').replace('got!=2*N','got!=N').replace('ticks!=2*HT*VT','ticks!=HT*VT').replace('PASS SCANOUT frames=2','PASS SCANOUT BOUNDARY frames=1')
 with tempfile.TemporaryDirectory(prefix='scanout_stop_boundary_') as tmp:
  p=Path(tmp);(p/'tb.sv').write_text(boundary);execute(['iverilog','-g2012','-s','tb','-o',p/'sim',*SOURCES,p/'tb.sv'],p,p/'compile.log');boundary_out=execute(['vvp',p/'sim'],p,p/'run.log');print(boundary_out)
 assert hashes()==frozen
 (HERE/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',sources=frozen,output=out,stop_on_final_tick=boundary_out),indent=2)+'\n')
if __name__=='__main__':main()
