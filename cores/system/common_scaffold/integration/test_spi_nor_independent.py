"""Independent pin slave and host scoreboard for SPI NOR read / abort boundaries."""
import hashlib
import tempfile
from pathlib import Path
from tooling import PACKAGE, evidence_dir, execute, write_json

TB = r'''
`timescale 1ns/1ps
module tb;
localparam MODE=@MODE@,DIV=@DIV@;
reg clk=0;always #5 clk=~clk;
reg rst_n=0,ce=1,abort=0,cv=0,wv=0,rr=0,ready=0;
reg[3:0]op=0;reg[23:0]addr=0;reg[8:0]len=0;
wire cr,wr,rv,resp,busy,cs,sck,mosi;wire[7:0]rd,status;wire[3:0]err;wire[8:0]count;
reg miso=0;
spi_nor_flash #(.SPI_MODE(MODE),.CLOCK_DIV(DIV),.CS_HIGH_CYCLES(3),.HOST_TIMEOUT(1000),.POLL_LIMIT(3))
d(clk,rst_n,ce,abort,cv,cr,op,addr,len,wv,wr,8'h00,rv,rr,rd,resp,ready,err,count,status,busy,cs,sck,mosi,miso);
function[7:0]mem;input[23:0]a;begin mem=(a*13)^(a>>8)^8'h5a;end endfunction
reg[7:0]rxbyte=0,txbyte=0,opcode=0;reg[23:0]slave_addr=0;
integer bitpos=0,nb=0,transactions=0;
// Mode 0 and 3 both sample on rising SCLK; their launch edge is falling.
always @(negedge cs)begin
 bitpos=0;nb=0;rxbyte=0;txbyte=0;opcode=0;slave_addr=0;miso=0;transactions=transactions+1;
end
always @(posedge sck)if(!cs)begin
 rxbyte={rxbyte[6:0],mosi};
 if(bitpos==7)begin
  if(nb==0)opcode=rxbyte;
  else if((opcode==3||opcode==11)&&nb<=3)slave_addr={slave_addr[15:0],rxbyte};
  nb=nb+1;bitpos=0;rxbyte=0;
  case(opcode)
   8'h05:txbyte=0;
   8'h9f:case(nb)1:txbyte=8'hef;2:txbyte=8'h40;3:txbyte=8'h18;default:txbyte=0;endcase
   8'h03:begin if(nb==4)txbyte=mem(slave_addr);else if(nb>4)begin slave_addr=slave_addr+1;txbyte=mem(slave_addr);end end
   8'h0b:begin if(nb==5)txbyte=mem(slave_addr);else if(nb>5)begin slave_addr=slave_addr+1;txbyte=mem(slave_addr);end end
   default:txbyte=0;
  endcase
 end else bitpos=bitpos+1;
end
always @(negedge sck)if(!cs)miso=txbyte[7-bitpos];
task command;input[3:0]o;input[23:0]a;input[8:0]n;begin
 @(negedge clk);ce=1;op=o;addr=a;len=n;cv=1;
 begin:accept_cmd while(1)begin @(posedge clk);if(cr)disable accept_cmd;end end
 @(negedge clk);cv=0;ce=0;
end endtask
task take_byte;input[7:0]wanted;reg[7:0]held;integer j;begin
 wait(rv);#1;held=rd;
 for(j=0;j<5;j=j+1)begin @(posedge clk);#1;if(!rv||rd!==held)$fatal(1,"read hold");end
 if(held!==wanted)$fatal(1,"byte got%h wanted%h",held,wanted);
 @(negedge clk);rr=1;@(posedge clk);@(negedge clk);rr=0;
end endtask
task response;input[3:0]e;input[8:0]n;integer j;begin
 wait(resp);#1;
 for(j=0;j<5;j=j+1)begin
  if(err!==e||count!==n||!resp||!cs||sck!==(MODE==3))$fatal(1,"response err%0d count%0d wanted%0d/%0d",err,count,e,n);
  @(posedge clk);#1;
 end
 @(negedge clk);ready=1;@(posedge clk);@(negedge clk);ready=0;
end endtask
integer k;reg[23:0]base;
initial begin
 repeat(4)@(posedge clk);@(negedge clk);rst_n=1;
 command(0,0,3);take_byte(8'hef);take_byte(8'h40);take_byte(8'h18);response(0,3);
 base=24'h12fffd;command(1,base,7);for(k=0;k<7;k=k+1)take_byte(mem(base+k));response(0,7);
 base=24'hfffffb;command(2,base,5);for(k=0;k<5;k=k+1)take_byte(mem(base+k));response(0,5);
 // The output handshake is effective even with CE=0. An abort on that
 // same clock must report the byte actually accepted by the host.
 command(1,24'habcd01,3);wait(rv);#1;if(rd!==mem(24'habcd01))$fatal(1,"abort fixture");
 @(negedge clk);rr=1;abort=1;@(posedge clk);@(negedge clk);rr=0;abort=0;response(6,1);
 command(1,24'habcd02,3);wait(rv);@(negedge clk);abort=1;@(posedge clk);@(negedge clk);abort=0;response(6,0);
 // Invalid descriptors must never touch the physical slave.
 k=transactions;command(1,24'hffffff,2);response(1,0);if(transactions!=k)$fatal(1,"invalid descriptor issued SPI");
 $display("PASS NOR_INDEPENDENT MODE=%0d DIV=%0d transactions=%0d",MODE,DIV,transactions);$finish;
end
initial begin #10000000;$fatal(1,"watchdog");end
endmodule
'''


def main():
    rtl = PACKAGE/'peripherals/spi_nor_flash/spi_nor_flash.sv'
    digest = hashlib.sha256(rtl.read_bytes()).hexdigest()
    folder = evidence_dir('spi_nor_independent')
    profiles = []
    for mode, div in ((0, 1), (0, 3), (3, 1), (3, 4)):
        with tempfile.TemporaryDirectory(prefix='nor_root_peer_') as tmp:
            p = Path(tmp)
            (p/'tb.sv').write_text(TB.replace('@MODE@', str(mode)).replace('@DIV@', str(div)), encoding='utf-8')
            label = f'{mode}_{div}'
            execute(['iverilog', '-g2012', '-s', 'tb', '-o', p/'sim', rtl, p/'tb.sv'], p, folder/f'compile_{label}.log')
            out = execute(['vvp', p/'sim'], p, folder/f'simulation_{label}.log')
            assert 'PASS NOR_INDEPENDENT' in out
            profiles.append(dict(mode=mode, divider=div, status='PASS'))
    assert hashlib.sha256(rtl.read_bytes()).hexdigest() == digest, 'RTL changed during test'
    write_json(folder/'results.json', dict(status='PASS', rtl_sha256=digest, profiles=profiles,
        reviewer_script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        scope='Independent edge slave: JEDEC, read/fastread across page and 24-bit end, CE0 continued service, stalled payload/response, abort+handshake accounting and invalid-no-SPI; no write/device electrical/board claim'))
    print(folder)


if __name__ == '__main__':
    main()
