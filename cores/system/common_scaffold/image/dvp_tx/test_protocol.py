from run_tests import *
TBP=r'''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0,abort=0;reg[15:0]cfg_width=8,cfg_height=2;reg cfg_mode=0,cfg_big_endian=0,cfg_vsync_active_high=1,cfg_href_active_high=1;reg[15:0]cfg_hblank=2,cfg_vblank_lines=1,cfg_byte_period=2;
reg[23:0]s_pixel=0;reg s_valid=0,s_sof=0,s_eol=0,s_last=0;wire s_ready,start_ready,done_valid,frame_error;wire[7:0]error_code,data;wire vsync,href,sample_valid;reg done_ready=0;wire[15:0]image_width,image_height;wire image_mode;
dvp_tx #(.FIFO_DEPTH(3))dut(.*);integer cycles=0,ticks=0,last_tick=-1,i,j,good=0,bad=0;reg timing=0;integer matched=0;
always @(posedge clk)begin
 if(rst_n&&dut.push&&dut.read_en&&dut.wp==dut.rp)$fatal(1,"cross-port address collision");
 if(rst_n&&dut.push&&dut.count==3)$fatal(1,"write full ring");
 cycles=cycles+1;if(cycles>300000)$fatal(1,"timeout state %d",dut.state);
 if(rst_n&&sample_valid)begin
  if(last_tick>=0&&cycles-last_tick!=2)$fatal(1,"tick CE changed");last_tick=cycles;ticks=ticks+1;
  if(frame_error&&({vsync,href,data}!==10'h200))$fatal(1,"error not blank");
  if(!frame_error&&href)begin if(data!==matched)$fatal(1,"healthy pixels %d %h",matched,data);matched=matched+1;end
 end
end
 task tick;begin @(negedge clk);#1;end endtask
 task launch;begin ce=1;ticks=0;last_tick=-1;matched=0;start_valid=1;tick;start_valid=0;end endtask
 task send;input integer index;input integer marker;begin
  s_pixel=index;s_sof=index==0;s_eol=index%8==7;s_last=index==15;
  if(marker==1)s_sof=!s_sof;if(marker==2)s_eol=!s_eol;if(marker==3)s_last=!s_last;
  s_valid=1;@(posedge clk);while(!(ce&&s_ready))@(posedge clk);tick;s_valid=0;
 end endtask
 task report;input[7:0]err;input integer nt;begin
  s_valid=0;while(!done_valid)tick;tick;
  if(error_code!=err||frame_error!=(err!=0)||ticks!=nt)$fatal(1,"report %d expected %d ticks %d expected %d",error_code,err,ticks,nt);
  if(err==0&&matched!=16)$fatal(1,"healthy count");repeat(5)tick;if(sample_valid||!done_valid||href||!vsync)$fatal(1,"DONE blank");
  ce=1;done_ready=1;tick;done_ready=0;if(!start_ready)$fatal(1,"ACK");if(err==0)good=good+1;else bad=bad+1;
 end endtask
 task healthy;begin launch;for(i=0;i<16;i=i+1)send(i,0);report(0,40);end endtask
 initial begin repeat(3)tick;rst_n=1;healthy;
 // Complete-buffer prefill required; waiting for host input never emits a partial frame.
 launch;send(0,0);send(1,0);repeat(15)tick;if(sample_valid||dut.state!=1)$fatal(1,"prefill early start");abort=1;tick;abort=0;report(9,0);healthy;
 // Underflow continues exact cadence through tail boundary even while host CE is off.
 launch;for(i=0;i<3;i=i+1)send(i,0);while(dut.state!=2)tick;ce=0;report(2,40);healthy;
 for(j=1;j<=3;j=j+1)begin
  launch;send(0,j);report(4,0);healthy;
  launch;for(i=0;i<3;i=i+1)send(i,0);while(dut.state!=2)tick;send(3,j);ce=0;report(4,40);healthy;
 end
 // Missing line/frame marker on their true final positions.
 launch;for(i=0;i<7;i=i+1)send(i,0);send(7,2);report(4,40);healthy;
 launch;for(i=0;i<15;i=i+1)send(i,0);send(15,3);report(4,40);healthy;
 // Mid-frame abort cannot freeze sample cadence or terminate before safe timing boundary.
 launch;for(i=0;i<3;i=i+1)send(i,0);while(!href)tick;abort=1;tick;abort=0;ce=0;report(9,40);healthy;
 // Reset in PREFILL and RUN works independently of host CE.
 for(j=1;j<=2;j=j+1)begin launch;send(0,0);if(j==2)begin send(1,0);send(2,0);while(dut.state!=2)tick;end
 ce=0;rst_n=0;tick;if(!start_ready||sample_valid||done_valid||href||!vsync)$fatal(1,"CE0 reset");rst_n=1;ce=1;healthy;end
 // Fill RAM3 plus lookahead, prove full-ring source backpressure, then drain/refill without altering physical ticks.
 launch;for(i=0;i<4;i=i+1)send(i,0);if(dut.count!=3||!dut.pixel_valid||s_ready)$fatal(1,"full ring not blocked");
 s_valid=1;s_pixel=4;s_sof=0;s_eol=0;s_last=0;tick;if(dut.push||s_ready||dut.count!=3)$fatal(1,"full write admitted");s_valid=0;
 for(i=4;i<16;i=i+1)send(i,0);report(0,40);
 $display("PASS DVP TX PROTOCOL good=%d bad=%d",good,bad);$finish;end
endmodule'''
def main():
 with tempfile.TemporaryDirectory(prefix='dvp_tx_protocol_') as td:
  d=Path(td);(d/'tb.sv').write_text(TBP);execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],ROOT,H/'protocol_compile.log');out=execute(['vvp',d/'a.vvp'],ROOT,H/'protocol_simulation.log');assert 'PASS DVP TX PROTOCOL' in out
 (H/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),scope='Full prefill wait; underflow/marker/abort fixed-cadence safe tail with CE0; early/missing SOF/EOL/LAST and healthy recovery; PREFILL/RUN CEoff reset',output=out),indent=2)+'\n');print(out)
if __name__=='__main__':main()
