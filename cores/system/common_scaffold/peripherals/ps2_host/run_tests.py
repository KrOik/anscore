from pathlib import Path
import sys,tempfile,json,hashlib,re
H=Path(__file__).resolve().parent
sys.path.insert(0,str(H.parents[1]))
from integration.tooling import ROOT,execute
RTL=H/'ps2_host.sv'
TB=r'''module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,abort=0,dev_clk_low=0,dev_data_low=0;
wire ps2_clk_drive_low,ps2_data_drive_low;
wire ps2_clk_in=!ps2_clk_drive_low&&!dev_clk_low,ps2_data_in=!ps2_data_drive_low&&!dev_data_low;
reg[7:0]tx_data=0;reg tx_valid=0,tx_done_ready=0;wire tx_ready,tx_done_valid;wire[7:0]tx_error_code,rx_data,rx_error_code;wire rx_valid,rx_error_valid,busy;reg rx_ready=1,rx_error_ready=0;wire[31:0]rx_error_count,rx_overflow_count;
ps2_host #(.CLK_HZ(1000000),.FILTER_CYCLES(3),.RX_FIFO_DEPTH(4),.EDGE_TIMEOUT_CYCLES(2000))dut(.*);
integer cycles=0,rxgot=0,txgot=0,i,j,k;reg heldvalid=0;reg[7:0]held;reg[7:0]expect_rx[0:NR-1];reg[7:0]cmds[0:NT-1];
always @(negedge clk)begin cycles=cycles+1;ce=cycles%17>2;rx_ready=cycles%13>3;if(cycles>2000000)$fatal(1,"timeout %d",dut.ts);end
always @(posedge clk)if(rst_n)begin
 if(heldvalid&&(!rx_valid||rx_data!==held))$fatal(1,"RX stall");heldvalid=rx_valid&&!(ce&&rx_ready);held=rx_data;
 if(ce&&rx_valid&&rx_ready)begin if(rxgot>=NR||rx_data!==expect_rx[rxgot])$fatal(1,"RX byte %d %h exp %h",rxgot,rx_data,expect_rx[rxgot]);rxgot=rxgot+1;end
 if(rx_error_valid)$fatal(1,"unexpected RXerror %d",rx_error_code);
 if(dut.push&&dut.fetch&&dut.wp==dut.rp)$fatal(1,"RAM address collision");
end
 task tick;begin @(negedge clk);#1;end endtask
 task waitn;input integer n;integer z;begin for(z=0;z<n;z=z+1)tick;end endtask
 task devbit;input b;begin dev_data_low=!b;dev_clk_low=0;waitn(40);dev_clk_low=1;waitn(40);dev_clk_low=0;end endtask
 task devsend;input[7:0]v;integer z;begin devbit(0);for(z=0;z<8;z=z+1)devbit(v[z]);devbit(~^v);devbit(1);dev_data_low=0;dev_clk_low=0;waitn(80);end endtask
 task hostsend;input[7:0]v;integer z,n;reg[7:0]seen;begin
  tx_data=v;tx_valid=1;@(posedge clk);while(!(ce&&tx_ready))@(posedge clk);tick;tx_valid=0;tx_data=~v;n=0;
  while(ps2_clk_drive_low)begin n=n+1;tick;end if(n<100||!ps2_data_drive_low)$fatal(1,"inhibit/request %d",n);waitn(40);
  for(z=0;z<10;z=z+1)begin
   dev_clk_low=1;waitn(40);dev_clk_low=0;
   if(z<8)seen[z]=ps2_data_in;else if(z==8&&ps2_data_in!==(~^v))$fatal(1,"TX parity");else if(z==9&&!ps2_data_in)$fatal(1,"TX stop");
   waitn(40);
  end
  if(seen!==v)$fatal(1,"TX byte %h expected %h",seen,v);
  dev_data_low=1;dev_clk_low=1;waitn(40);dev_clk_low=0;waitn(40);dev_data_low=0;
  while(!tx_done_valid)tick;if(tx_error_code||ps2_clk_drive_low||ps2_data_drive_low)$fatal(1,"TXerror %d",tx_error_code);
  waitn(9);if(!tx_done_valid)$fatal(1,"DONE hold");tx_done_ready=1;@(posedge clk);while(!ce)@(posedge clk);tick;tx_done_ready=0;txgot=txgot+1;waitn(80);
 end endtask
 initial begin $readmemh("RX",expect_rx);$readmemh("TX",cmds);repeat(4)tick;rst_n=1;waitn(100);
 for(i=0;i<NR;i=i+1)devsend(expect_rx[i]);while(rxgot<NR)tick;
 for(i=0;i<NT;i=i+1)hostsend(cmds[i]);
 if(rx_error_count||rx_overflow_count||rxgot!=NR||txgot!=NT)$fatal(1,"counts");$display("PASS PS2 RX=%d TX=%d cycles=%d",rxgot,txgot,cycles);$finish;end
endmodule'''
def execute_tb(name,tb,extra=None):
 with tempfile.TemporaryDirectory(prefix='ps2_host_'+name+'_') as td:
  d=Path(td)
  if extra:
   for token,seq in extra.items():
    p=d/(token+'.hex');p.write_text('\n'.join(f'{v:x}' for v in seq));tb=tb.replace('"'+token+'"','"'+p.as_posix()+'"')
  (d/'tb.sv').write_text(tb);execute(['iverilog','-g2012','-s','tb','-o',d/'a.vvp',RTL,d/'tb.sv'],ROOT,H/(name+'_compile.log'));out=execute(['vvp',d/'a.vvp'],ROOT,H/(name+'_simulation.log'),timeout=180);assert 'PASS' in out;return out

def main():
 rx=list(range(256))+[0xaa,0xfa,0xe0,0x1c,0xf0,0x1c,0x08,0x01,0xff,0x38,0xfe,0x02];tx=[0xff,0xf4,0xed,0x07,0xf3,200,100,80]+list(range(256));tb=TB.replace('NR',str(len(rx))).replace('NT',str(len(tx)));out=execute_tb('main',tb,dict(RX=rx,TX=tx));print(out)
 (H/'evidence.json').write_text(json.dumps(dict(status='PASS',rtl_sha256=hashlib.sha256(RTL.read_bytes()).hexdigest(),rx_bytes=len(rx),tx_bytes=len(tx),scope='All256 RX and TX byte values, keyboard scan code/break sequences, mouse packets/commands, independent wired-AND device waveform/rising-edge TX oracle, odd parity/stop, CE pauses, held RX and TX DONE'),indent=2)+'\n')
if __name__=='__main__':main()
