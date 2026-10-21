from run_tests import *
TBP=r'''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,start_valid=0,abort=0;reg[15:0]cfg_width=4,cfg_height=2;reg cfg_mode=0,cfg_big_endian=0,cfg_vsync_active_high=1,cfg_href_active_high=1;
reg sample_valid=0,vsync=0,href=0;reg[7:0]data=0;wire start_ready,done_valid,frame_error;wire[7:0]error_code;wire[15:0]image_width,image_height;wire image_mode;wire[23:0]m_pixel;wire m_valid,m_sof,m_eol,m_last;reg m_ready=1,done_ready=0;
dvp_rx #(.FIFO_DEPTH(3))dut(.*);integer i,j,k,tests=0,cycles=0,good=0;reg[26:0]token;reg dense_check=0;integer dense_got=0;
always @(posedge clk)begin
 if(dense_check&&rst_n&&ce&&m_valid&&m_ready)begin if(m_pixel!==dense_got||m_sof!==(dense_got==0)||m_eol!==(dense_got==15)||m_last!==(dense_got==15))$fatal(1,"full FIFO read/write %d %h",dense_got,m_pixel);dense_got=dense_got+1;end
 cycles=cycles+1;if(cycles>200000)$fatal(1,"timeout %d",dut.state);end
 task tick;begin @(negedge clk);#1;end endtask
 task sample;input v,h;input[7:0]d;begin sample_valid=1;vsync=v;href=h;data=d;tick;end endtask
 task idle_sample;begin sample_valid=0;tick;end endtask
 task launch;input mode;begin ce=1;m_ready=1;cfg_mode=mode;start_valid=1;tick;start_valid=0;sample(0,0,0);sample(1,0,0);sample(0,0,0);end endtask
 task report;input[7:0]code;begin sample_valid=0;ce=1;m_ready=1;while(!done_valid)tick;if(error_code!==code||frame_error!==(code!=0))$fatal(1,"error %d expected %d",error_code,code);repeat(3)tick;done_ready=1;tick;done_ready=0;if(!start_ready)$fatal(1,"ack");tests=tests+1;end endtask
 task healthy;integer a,b;begin launch(0);for(a=0;a<2;a=a+1)begin for(b=0;b<4;b=b+1)sample(0,1,a*4+b);sample(0,0,0);end sample(1,0,0);report(0);good=good+1;end endtask
 task errorhold;input[7:0]code;begin
 if(!frame_error||error_code!=code||done_valid||!m_valid)$fatal(1,"pending error %d actual %d state %d",code,error_code,dut.state);
 token={m_pixel,m_sof,m_eol,m_last};sample_valid=0;
 for(k=0;k<7;k=k+1)begin tick;if(!m_valid||{m_pixel,m_sof,m_eol,m_last}!==token||done_valid)$fatal(1,"error retracted token");end
 ce=1;tick;if(done_valid||!m_valid)$fatal(1,"ready0 didn't hold");m_ready=1;tick;
 if(!done_valid||m_valid)$fatal(1,"error drain did not finish");report(code);healthy;
 end endtask
 initial begin repeat(3)tick;rst_n=1;healthy;
 // Overflow while CE0 must keep already exposed token until explicit drain.
 launch(0);sample(0,1,10);sample(0,1,11);sample(0,1,12);m_ready=0;ce=0;
 sample(0,1,13);sample(0,0,0);sample(0,1,14);sample(0,1,15);sample(0,1,16);errorhold(2);
 // Long/short/partial lines and short/long frames, all with a stalled exposed token.
 launch(0);sample(0,1,1);sample(0,1,2);m_ready=0;ce=0;sample(0,0,0);errorhold(4);
 launch(1);sample(0,1,1);sample(0,1,2);sample(0,1,3);m_ready=0;ce=0;sample(0,0,0);errorhold(5);
 // Long line FIFO depth3 can hold four pixels including exposed register.
 launch(0);sample(0,1,1);sample(0,1,2);m_ready=0;sample(0,1,3);sample(0,1,4);ce=0;sample(0,1,5);errorhold(3);
 launch(0);sample(0,1,1);sample(0,1,2);m_ready=0;ce=0;sample(1,1,3);errorhold(8);
 launch(0);for(i=0;i<4;i=i+1)sample(0,1,i);m_ready=0;ce=0;sample(0,0,0);sample(1,0,0);errorhold(6);
 launch(0);for(j=0;j<2;j=j+1)begin for(i=0;i<4;i=i+1)sample(0,1,i);sample(0,0,0);end
 // No pending pixels can remain after input pacing, create no-stall long-frame error.
 sample(0,1,9);report(7);healthy;
 // Abort in LOCK/FRAME/DRAIN, and reset at CE0 in all three.
 for(j=1;j<=3;j=j+1)begin
 start_valid=1;ce=1;tick;start_valid=0;sample_valid=0;
 if(j>=2)begin sample(1,0,0);sample(0,0,0);end
 if(j==3)begin for(i=0;i<2;i=i+1)begin sample(0,1,1);sample(0,1,2);sample(0,1,3);sample(0,1,4);sample(0,0,0);end sample(1,0,0);end
 sample_valid=0;abort=1;tick;abort=0;report(9);healthy;
 start_valid=1;tick;start_valid=0;
 if(j>=2)begin sample(1,0,0);sample(0,0,0);end
 if(j==3)begin for(i=0;i<2;i=i+1)begin sample(0,1,1);sample(0,1,2);sample(0,1,3);sample(0,1,4);sample(0,0,0);end sample(1,0,0);end
 sample_valid=0;ce=0;rst_n=0;tick;if(!start_ready||done_valid||m_valid)$fatal(1,"CE0reset");rst_n=1;ce=1;healthy;
 end
 // An already latched error is immutable while the exposed token drains; reset cancels it at CE0.
 launch(0);sample(0,1,1);sample(0,1,2);m_ready=0;ce=0;sample(0,0,0);sample_valid=0;token={m_pixel,m_sof,m_eol,m_last};ce=1;abort=1;repeat(3)tick;
 if(error_code!=4||!m_valid||{m_pixel,m_sof,m_eol,m_last}!==token||done_valid)$fatal(1,"pending error abort");abort=0;ce=0;rst_n=0;tick;if(!start_ready||done_valid||m_valid)$fatal(1,"ERROR_DRAIN reset");rst_n=1;ce=1;m_ready=1;healthy;
 // Fill all three RAM slots plus output register, then full simultaneous pop/read/write on wrapped same address.
 cfg_width=16;cfg_height=1;launch(0);m_ready=0;dense_check=1;dense_got=0;
 for(i=0;i<4;i=i+1)sample(0,1,i);if(dut.count!=3||!m_valid)$fatal(1,"FIFO not full");m_ready=1;
 for(i=4;i<16;i=i+1)begin sample(0,1,i);if(dut.count!=3)$fatal(1,"full simultaneous flow");end
 sample(0,0,0);sample(1,0,0);report(0);if(dense_got!=16)$fatal(1,"dense count");dense_check=0;good=good+1;cfg_width=4;cfg_height=2;
 $display("PASS DVP PROTOCOL reports=%d healthy=%d",tests,good);$finish;end
endmodule'''
def main():
 with tempfile.TemporaryDirectory(prefix='dvp_rx_protocol_') as td:
  d=Path(td);(d/'tb.sv').write_text(TBP);execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],ROOT,H/'protocol_compile.log');out=execute(['vvp',d/'a.vvp'],ROOT,H/'protocol_simulation.log');assert 'PASS DVP PROTOCOL' in out
 (H/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),scope='CE-off overflow/longline/shortline/partialpixel/syncoverlap/shortframe retain stalled output until drain; longframe; LOCK FRAME DRAIN abort and CE-off reset; every error followed by healthy frame',output=out),indent=2)+'\n');print(out)
if __name__=='__main__':main()
