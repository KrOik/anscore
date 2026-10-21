from pathlib import Path
import sys,tempfile,json,hashlib
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import execute
BASE=H.parent/'dvp_rx/dvp_rx.sv'
TB=r'''module tb;
localparam N=@N@,W=(N<8?N+8:N<4096?N+2:N),HEIGHT=4;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,start_valid=0,abort=0,cfg_mode=0,cfg_big_endian=1,cfg_vsync_active_high=1,cfg_href_active_high=1;
reg[15:0]cfg_width=W,cfg_height=HEIGHT;reg sample_valid=0,vsync=0,href=0;reg[7:0]data=0;
wire start_ready;wire[23:0]m_pixel;wire m_valid,m_sof,m_eol,m_last,done_valid,frame_error;reg m_ready=0,done_ready=0;wire[7:0]error_code;wire[15:0]image_width,image_height;wire image_mode;
dvp_rx #(.MAX_WIDTH(W),.MAX_HEIGHT(HEIGHT),.FIFO_DEPTH(N))dut(.*);
integer sent=0,got=0,simultaneous=0,wraps=0;reg laststall=0;reg[26:0]held;
always @(posedge clk)if(rst_n)begin
 if(dut.count>N||dut.wp>N||dut.rp>N)$fatal(1,"range");
 if((dut.wp+N+1-dut.rp)%(N+1)!=dut.count)$fatal(1,"ring invariant");
 if(dut.push&&dut.read_en&&dut.wp==dut.rp)$fatal(1,"RAM same-address collision");
 if(dut.push&&dut.read_en&&dut.full)simultaneous=simultaneous+1;
 if(dut.push&&dut.wp==N)wraps=wraps+1;
 if(laststall&&(!m_valid||{m_sof,m_eol,m_last,m_pixel}!==held))$fatal(1,"stall hold");
 if(ce&&m_ready&&m_valid)begin
 if(m_pixel!=={16'b0,8'(got)}||m_sof!==(got==0)||m_eol!==(got%W==W-1)||m_last!==(got==W*HEIGHT-1))$fatal(1,"sequence %d %h",got,m_pixel);
 got=got+1;end
 laststall=m_valid&&!(ce&&m_ready);held={m_sof,m_eol,m_last,m_pixel};
end
 task tick;begin @(negedge clk);#1;end endtask
 task pix;begin
 if(sent!=0&&sent%W==0)begin sample_valid=1;href=0;tick;end
 sample_valid=1;href=1;data=sent;tick;sent=sent+1;end endtask
integer i;
initial begin repeat(3)tick;rst_n=1;start_valid=1;tick;start_valid=0;sample_valid=1;vsync=1;tick;vsync=0;tick;
pix;sample_valid=0;tick; // prefetch first byte to holding slot
ce=0;for(i=0;i<N;i=i+1)pix;
if(!m_valid||dut.count!=N||got!=0||frame_error)$fatal(1,"capacity N+holding");
sample_valid=0;repeat(9)tick;
ce=1;m_ready=1;pix; // logically full read+push must accept at distinct physical addresses
if(frame_error||simultaneous!=1||dut.count!=N)$fatal(1,"full acceptance");
while(sent<W*HEIGHT)begin
 if(sent%17==0)begin ce=0;sample_valid=0;repeat(3)tick;ce=1;end
 pix;end
href=0;sample_valid=1;tick;vsync=1;tick;sample_valid=0;
while(!done_valid)tick;
if(frame_error||got!=W*HEIGHT||wraps<2)$fatal(1,"drain/wrap %d %d",got,wraps);
$display("PASS RX RING depth=%0d bytes=%0d full_read_push=%0d wraps=%0d",N,got,simultaneous,wraps);$finish;end
initial begin #5000000;$fatal(1,"watchdog");end
endmodule'''
def main():
 baseline=hashlib.sha256(BASE.read_bytes()).hexdigest();assert baseline==json.loads((H/'baseline.json').read_text())['rtl_sha256']
 s=BASE.read_text();n=s.replace('$clog2(FIFO_DEPTH);','$clog2(FIFO_DEPTH+1);').replace('mem[0:FIFO_DEPTH-1]','mem[0:FIFO_DEPTH]').replace('wp==FIFO_DEPTH-1','wp==FIFO_DEPTH').replace('rp==FIFO_DEPTH-1','rp==FIFO_DEPTH')
 rows=[]
 with tempfile.TemporaryDirectory(prefix='dvp_rx_ring_') as d:
  p=Path(d);rtl=p/'dvp_rx.sv';rtl.write_text(n)
  for depth in (2,3,7,1024,4096):
   (p/'tb.sv').write_text(TB.replace('@N@',str(depth)))
   execute(['iverilog','-g2012','-s','tb','-o',p/'sim',rtl,p/'tb.sv'],H,H/f'compile_{depth}.log')
   out=execute(['vvp',p/'sim'],H,H/f'simulation_{depth}.log');assert 'PASS RX RING' in out;print(out);rows.append(dict(depth=depth,status='PASS',output=out))
 assert hashlib.sha256(BASE.read_bytes()).hexdigest()==baseline
 (H/'staging_evidence.json').write_text(json.dumps(dict(status='PASS',original_unchanged=True,baseline_sha256=baseline,proposed_rtl_sha256=hashlib.sha256(n.encode()).hexdigest(),profiles=rows,scope='Staged temporary RTL only; not integrated and not an additional IP'),indent=2)+'\n')
if __name__=='__main__':main()

