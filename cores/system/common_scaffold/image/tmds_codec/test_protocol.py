from run_tests import HERE,SOURCES,execute,CONTROLS
from pathlib import Path
import hashlib,json,tempfile
TB=r"""module tb;
reg clk=0;always #5 clk=~clk;reg rst_n=0,ce=1,s_valid=0,m_ready=0;
reg[7:0]s_data=0;reg s_de=0;reg[1:0]s_control=0;reg[9:0]s_symbol=0;
wire er,dr,ev,dv;wire[9:0]encoded;wire[7:0]decoded;wire dde,derr,lock_;wire[1:0]dc;wire signed[5:0]erd,drd;
tmds_encoder enc(.clk(clk),.rst_n(rst_n),.ce(ce),.s_valid(s_valid),.s_ready(er),.s_data(s_data),.s_de(s_de),.s_control(s_control),.m_symbol(encoded),.m_valid(ev),.m_ready(m_ready),.running_disparity(erd));
tmds_decoder dec(.clk(clk),.rst_n(rst_n),.ce(ce),.s_valid(s_valid),.s_ready(dr),.s_symbol(s_symbol),.m_data(decoded),.m_de(dde),.m_control(dc),.m_error(derr),.m_valid(dv),.m_ready(m_ready),.synchronized(lock_),.running_disparity(drd));
integer j;reg[9:0]held;reg[11:0]dheld;
task tick;begin @(negedge clk);#1;end endtask
task reset_low;begin rst_n=0;ce=0;tick;if(ev||dv||erd||drd||lock_)$fatal(1,"CEoff reset");rst_n=1;ce=1;end endtask
initial begin repeat(3)tick;reset_low;
for(j=0;j<4;j=j+1)begin
s_de=0;s_control=j;
case(j)0:s_symbol=10'b1101010100;1:s_symbol=10'b0010101011;2:s_symbol=10'b0101010100;3:s_symbol=10'b1010101011;endcase
s_valid=1;tick;s_valid=0;
if(!ev||!dv||encoded!==s_symbol||dc!=j||decoded||dde||derr||!lock_||erd||drd)$fatal(1,"control");
held=encoded;dheld={derr,dde,dc,decoded};ce=0;m_ready=1;
repeat(5)begin tick;if(!ev||!dv||encoded!==held||{derr,dde,dc,decoded}!==dheld)$fatal(1,"CEoff stalled");end
ce=1;m_ready=0;repeat(4)tick;if(er||dr)$fatal(1,"full accepted");
reset_low;
end
// No CE input acceptance even when elastic holding register empty.
ce=0;s_valid=1;s_de=1;s_data=255;s_symbol=0;repeat(5)tick;
if(ev||dv||erd||lock_)$fatal(1,"accepted input CEoff");s_valid=0;reset_low;
// Decoder error token remains held, then a real control resynchronizes.
s_symbol=0;s_valid=1;tick;s_valid=0;if(!dv||!derr||lock_)$fatal(1,"unsynced error");
repeat(5)tick;if(!dv||!derr)$fatal(1,"error hold");m_ready=1;tick;m_ready=0;
s_de=0;s_control=0;s_symbol=10'b1101010100;s_valid=1;tick;s_valid=0;if(derr||!lock_||drd)$fatal(1,"resync");
$display("PASS TMDS protocol reset/stall/CE/input gate/error token/resync");$finish;
end endmodule"""
def main():
 hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
 with tempfile.TemporaryDirectory(prefix='tmds_protocol_') as tmp:
  d=Path(tmp);(d/'tb.sv').write_text(TB);execute(['iverilog','-g2012','-s','tb','-o',d/'sim',*SOURCES,d/'tb.sv'],d,HERE/'protocol_compile.log');out=execute(['vvp',d/'sim'],d,HERE/'protocol_simulation.log');assert 'PASS TMDS' in out;print(out)
 assert hashes=={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in SOURCES}
 (HERE/'protocol_evidence.json').write_text(json.dumps(dict(status='PASS',sources=hashes,scope='CEoff synchronous reset with held output for all4controls, CEoff input no acceptance, full register rejects additional input, decoder error token hold and control resync.'),indent=2)+'\n')
if __name__=='__main__':main()
