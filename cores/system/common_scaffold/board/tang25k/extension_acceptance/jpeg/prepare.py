from pathlib import Path
import sys,tempfile,json,hashlib,io
from PIL import Image
H=Path(__file__).resolve().parent;PACKAGE=H.parents[3];ROOT=PACKAGE.parents[1]
sys.path.insert(0,str(PACKAGE/'integration'))
from tooling import execute
from test_jpeg_gray_top_independent import RELATIVE,TB
SOURCES=[PACKAGE/x for x in RELATIVE]
UART=ROOT/'cores/crypto/hybrid_lattice_ntt/src/uart_tx.v'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
SIM=r"""`timescale 1ns/1ps
module tb;
reg clk=0;always #5 clk=~clk;
wire tx,done;jpeg_uart_25k #(.CLK_HZ(1000000),.BAUD(100000),.BOOT_CYCLES(32)) dut(.clk(clk),.uart_rx_pin(1'b1),.uart_tx(tx),.dbg_uart(done));
integer f,count=0;reg[7:0]b;
initial begin f=$fopen("uart.hex","w");forever begin
@(negedge tx);repeat(15)@(posedge clk);
for(integer i=0;i<8;i=i+1)begin b[i]=tx;repeat(10)@(posedge clk);end
if(tx!==1)$fatal(1,"bad UART stop");$fdisplay(f,"%02x",b);count=count+1;
end end
initial begin wait(done);repeat(30)@(posedge clk);if(count!=999)$fatal(1,"count %d",count);$fclose(f);$display("UART JPEG PASS");$finish;end
initial begin #50000000;$fatal(1,"timeout state%d",dut.state);end
endmodule
"""
def main():
 sources={str(x.relative_to(ROOT)):sha(x) for x in [*SOURCES,UART,H/'jpeg_uart_25k.sv']}
 with tempfile.TemporaryDirectory(prefix='jpeg_board_sim_') as tmp:
  p=Path(tmp);(p/'pixels.hex').write_bytes((H/'pixels.hex').read_bytes());(p/'tb.sv').write_text(TB.replace('@W@','13').replace('@H@','9'))
  execute(['iverilog','-g2012','-s','tb','-o',p/'ref',*SOURCES,p/'tb.sv'],p,H/'reference_compile.log')
  execute(['vvp',p/'ref'],p,H/'reference_simulation.log')
  frames=[]
  for i in range(2):
   data=bytes.fromhex((p/f'frame{i}.hex').read_text());(H/f'frame{i}.hex').write_text(data.hex()+'\n');(H/f'frame{i}.jpg').write_bytes(data);frames.append(data)
  expected=b''.join(frames);assert len(expected)==999
  (H/'expected_uart.hex').write_text(expected.hex()+'\n');(H/'expected_uart.bin').write_bytes(expected)
  (p/'board_tb.sv').write_text(SIM)
  execute(['iverilog','-g2012','-s','tb','-o',p/'board',*SOURCES,UART,H/'jpeg_uart_25k.sv',p/'board_tb.sv'],p,H/'uart_compile.log')
  execute(['vvp',p/'board'],p,H/'uart_simulation.log')
  actual=bytes(int(x,16) for x in (p/'uart.hex').read_text().split());assert actual==expected
  pixels=bytes(int(x,16) for x in (H/'pixels.hex').read_text().split());profiles=[]
  for i,data in enumerate(frames):
   image=Image.open(io.BytesIO(data));image.load();assert image.size==(13,9) and image.mode=='L'
   errors=[abs(a-b) for a,b in zip(pixels[i*117:(i+1)*117],image.tobytes())];assert max(errors)<=6 and sum(errors)/117<=2
   profiles.append(dict(frame=i,bytes=len(data),sha256=hashlib.sha256(data).hexdigest(),max_error=max(errors),mean_error=sum(errors)/117))
 assert all(sha(ROOT/k)==v for k,v in sources.items())
 result=dict(status='SIMULATION_PASS_NOT_BOARD',sources=sources,frames=profiles,uart_bytes=len(expected),uart_sha256=hashlib.sha256(expected).hexdigest(),physical_uart_bit_decode=True,board_tested=False)
 (H/'simulation_gate.json').write_text(json.dumps(result,indent=2)+'\n');print(result)
if __name__=='__main__':main()
